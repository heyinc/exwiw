# frozen_string_literal: true

module Exwiw
  class QueryAstBuilder
    def self.run(table_name, table_by_name, dump_target, logger, allow_reverse: true)
      new(table_name, table_by_name, dump_target, logger, allow_reverse: allow_reverse).run
    end

    # Scope-column mode classification for a single table. One of
    # :exempt / :direct / :via_path / :referenced_by / :unscopable.
    def self.scope_category(table_name, table_by_name, dump_target, logger)
      new(table_name, table_by_name, dump_target, logger).scope_category
    end

    # Strict pre-flight for scope-column mode: abort if any extractable table
    # cannot be scoped, so an unscoped (potentially sensitive) table is never
    # silently dumped in full. No-op outside scope mode. `tables` is the set of
    # dumpable configs (ignore:true tables are skipped — they are not extracted).
    def self.validate_scope!(tables, table_by_name, dump_target, logger)
      return if dump_target.scope_column.nil?

      unscopable =
        tables.reject(&:ignore).select do |table|
          scope_category(table.name, table_by_name, dump_target, logger) == :unscopable
        end
      return if unscopable.empty?

      names = unscopable.map(&:name).sort.join(", ")
      raise ArgumentError,
            "scope-column mode: #{unscopable.size} table(s) cannot be scoped by " \
            "'#{dump_target.scope_column}': #{names}. For each, add `scope_exempt: true` " \
            "to export it in full, set `ignore: true` to skip it, or add a belongs_to path " \
            "to a table that carries the scope column (use a per-table `scope_column` if the " \
            "column name differs on that table)."
    end

    attr_reader :table_name, :table_by_name, :dump_target

    def initialize(table_name, table_by_name, dump_target, logger, allow_reverse: true)
      @table_name = table_name
      @table_by_name = table_by_name
      @dump_target = dump_target
      @logger = logger
      @allow_reverse = allow_reverse
    end

    def run
      table = table_by_name.fetch(table_name)

      return build_scoped(table) if scope_mode?

      where_clauses = build_where_clauses(table, dump_target)
      join_clauses = build_join_clauses(table, table_by_name, dump_target)

      # Reverse / "referenced_by" extraction. A table with no belongs_to path to
      # the dump target produces no where/join clauses and would otherwise dump
      # every row (see the "no relation -> dump all" case). If an extractable
      # child table references it via a foreign key (e.g. active_storage_blobs is
      # referenced by active_storage_attachments.blob_id), constrain it to just
      # the referenced ids instead. Disabled (@allow_reverse=false) while building
      # a child's subquery, so this never recurses.
      if @allow_reverse && table.name != dump_target.table_name &&
         where_clauses.empty? && join_clauses.empty?
        reverse_clause = build_referenced_by_clause(table)
        where_clauses.push(reverse_clause) if reverse_clause
      end

      QueryAst::Select.new.tap do |ast|
        ast.from(table.name)
        if table.rails_managed?
          ast.select_all!
        else
          ast.select(table.columns)
        end
        join_clauses.each { |join_clause| ast.join(join_clause) }
        where_clauses.each { |where_clause| ast.where(where_clause) }
      end
    end

    private def build_join_clauses(table, table_by_name, dump_target)
      path_tables = find_path_to_dump_target(table, table_by_name, dump_target)
      @logger.debug("  Join path from the table to dump target: #{path_tables}")

      # the path is empty, it means that the table is not related to the dump target
      # the path is 1, it's impossible case
      return [] if path_tables.size < 2

      join_clauses = []

      path_tables.each_cons(2) do |from_table_name, to_table_name|
        from_table = table_by_name[from_table_name]
        to_table = table_by_name[to_table_name]

        relation = from_table.belongs_to(to_table_name)

        join_clause = QueryAst::JoinClause.new(
          base_table_name: from_table.name,
          foreign_key: relation.foreign_key,
          join_table_name: to_table.name,
          primary_key: to_table.primary_key,
          where_clauses: [],
          base_where_clauses: []
        )

        # When this hop itself is a polymorphic belongs_to (e.g. comments
        # polymorphically belongs_to posts as commentable), the type column
        # (foreign_type) lives on the source table (from_table = base_table_name).
        # The foreign key alone is not enough — a value like reviewable_id=1 can
        # collide with rows of another model — so add the type condition to
        # base_where_clauses to narrow down the source table.
        if relation.polymorphic?
          join_clause.base_where_clauses.push QueryAst::WhereClause.new(
            column_name: relation.foreign_type,
            operator: :eq,
            value: [relation.type_value]
          )
        end
        relation_to_dump_target = to_table.belongs_to(dump_target.table_name)
        if relation_to_dump_target
          join_clause.where_clauses.push dump_target_fk_clause(relation_to_dump_target.foreign_key)

          # When the intermediate table polymorphically belongs_to the dump
          # target, also add the type column (foreign_type) to the join
          # condition. The type column lives on to_table (= join_table_name), so
          # it rides on the existing mechanism where a JoinClause's where_clauses
          # are compiled against join_table_name.
          if relation_to_dump_target.polymorphic?
            join_clause.where_clauses.push QueryAst::WhereClause.new(
              column_name: relation_to_dump_target.foreign_type,
              operator: :eq,
              value: [relation_to_dump_target.type_value]
            )
          end
        end

        # Add filter from intermediate table to join clause
        if to_table.filter
          join_clause.where_clauses.push to_table.filter
        end

        join_clauses.push(join_clause)
      end

      join_clauses
    end

    # Builds a `pk IN (SELECT child.fk FROM <child extraction query>)` clause
    # for a table that is referenced by an extractable child table but has no
    # belongs_to of its own toward the dump target. Returns nil when there is no
    # such (single, unambiguous) referencer, leaving the caller to fall back to
    # the dump-all behavior.
    private def build_referenced_by_clause(table)
      candidates = table_by_name.each_value.filter_map do |other|
        next if other.name == table.name

        relation = other.belongs_to(table.name)
        # A polymorphic foreign key stores ids of several models in one column,
        # so projecting it would pull in unrelated parents. Skip it here; the
        # non-polymorphic blob_id on active_storage_attachments is what we want.
        next if relation.nil? || relation.polymorphic?

        # Build the child's own extraction query. allow_reverse:false stops a
        # chain of FK-less tables from recursing back into each other.
        child_query = self.class.run(other.name, table_by_name, dump_target, @logger, allow_reverse: false)

        # Only an *already constrained* child narrows anything; an unconstrained
        # child would select every fk value (i.e. dump all) and not help.
        next unless child_query.where_clauses.any? || child_query.join_clauses.any?

        [relation, child_query]
      end

      # Scope: only the unambiguous single-referencer case. Multiple referencers
      # would need their subqueries OR'd together (not yet supported); falling
      # back to dump-all preserves today's behavior for those.
      if candidates.size != 1
        if candidates.size > 1
          @logger.debug("  #{table.name} has multiple referencing tables; skipping reverse extraction (dump all).")
        end
        return nil
      end

      relation, child_query = candidates.first

      # Project the child's extraction query down to just the foreign key that
      # points at `table`. Force a plain column so any masking/raw_sql configured
      # on that column does not corrupt the id comparison.
      fk_column = TableColumn.from_symbol_keys(name: relation.foreign_key)
      projected = QueryAst::Select.new
      projected.from(child_query.from_table_name)
      projected.select([fk_column])
      child_query.join_clauses.each { |j| projected.join(j) }
      child_query.where_clauses.each { |w| projected.where(w) }

      QueryAst::WhereClause.new(
        column_name: table.primary_key,
        operator: :in_subquery,
        value: QueryAst::SelectSubquery.new(query: projected)
      )
    end

    private def build_where_clauses(table, dump_target)
      clauses = []

      if table.name == dump_target.table_name
        # `--ids-column` (folded into dump_target.ids_field by the CLI) lets
        # `--ids` match a non primary-key column on the target table; otherwise
        # fall back to the primary key. Only the target table's filter changes —
        # downstream foreign-key propagation still keys off the primary key.
        clauses.push Exwiw::QueryAst::WhereClause.new(
          column_name: dump_target.ids_field || table.primary_key,
          operator: :eq,
          value: dump_target.ids
        )

        return clauses
      end

      belongs_to = table.belongs_to(dump_target.table_name)
      return clauses if belongs_to.nil?

      clauses.push dump_target_fk_clause(belongs_to.foreign_key)

      # For a polymorphic belongs_to the foreign key alone cannot distinguish the
      # type (e.g. reviewable_id=1 could be a Product or another model), so add a
      # condition filtering the type column (foreign_type) by type_value.
      if belongs_to.polymorphic?
        clauses.push Exwiw::QueryAst::WhereClause.new(
          column_name: belongs_to.foreign_type,
          operator: :eq,
          value: [belongs_to.type_value]
        )
      end

      if table.filter
        clauses.push table.filter
      end

      clauses
    end

    # Builds the WHERE clause that constrains a `foreign_key` pointing at the
    # dump target. Normally `--ids` are the target's primary keys, so a plain
    # `foreign_key IN (ids)` suffices. When `--ids-column`/`--ids-field` is set
    # (dump_target.ids_field), `--ids` match a non primary-key column instead,
    # so the foreign key must be resolved through the target table:
    # `foreign_key IN (SELECT pk FROM target WHERE ids_field IN (ids))`.
    # This keeps related-table extraction correct regardless of whether the
    # relation is direct, indirect, or polymorphic.
    private def dump_target_fk_clause(foreign_key)
      unless dump_target.ids_field
        return Exwiw::QueryAst::WhereClause.new(
          column_name: foreign_key,
          operator: :eq,
          value: dump_target.ids
        )
      end

      target = table_by_name.fetch(dump_target.table_name)
      Exwiw::QueryAst::WhereClause.new(
        column_name: foreign_key,
        operator: :in_subquery,
        value: Exwiw::QueryAst::Subquery.new(
          table_name: target.name,
          select_column: target.primary_key,
          where_column: dump_target.ids_field,
          where_values: dump_target.ids
        )
      )
    end

    private def find_path_to_dump_target(table, table_by_name, dump_target)
      return [] if table.name == dump_target.table_name

      visited = {}
      queue = [[table.name, []]]

      until queue.empty?
        current_table_name, path = queue.shift
        current_table = table_by_name[current_table_name]

        next if visited[current_table_name]
        visited[current_table_name] = true

        current_table.belongs_tos.each do |relation|
          next_table_name = relation.table_name
          next_path = path + [current_table_name]

          return next_path if next_table_name == dump_target.table_name

          queue.push([next_table_name, next_path])
        end
      end

      queue
    end

    # ------------------------------------------------------------------
    # Scope-column mode (Exwiw::DumpTarget#scope_column).
    #
    # The single-target machinery above anchors everything on one named table.
    # Scope mode instead filters every table by a shared column. The relationship
    # walk is the same idea — the *terminus* is just "any table carrying the
    # scope column" rather than "the one named target".
    # ------------------------------------------------------------------

    private def scope_mode?
      !dump_target.scope_column.nil?
    end

    # Classifier used by validate_scope! and mirrored by build_scoped below.
    def scope_category
      table = table_by_name.fetch(table_name)
      return :exempt if scope_exempt?(table)
      return :direct if directly_scoped?(table)
      return :via_path if build_join_clauses_scoped(table).any?
      return :referenced_by if @allow_reverse && build_referenced_by_clause(table)

      :unscopable
    end

    private def build_scoped(table)
      ast = QueryAst::Select.new
      ast.from(table.name)
      if table.rails_managed?
        ast.select_all!
      else
        ast.select(table.columns)
      end

      # Reference/master (or rails-managed) table: export every row.
      return ast if scope_exempt?(table)

      # Carries the scope column itself: filter on it directly.
      if directly_scoped?(table)
        ast.where(scope_where_clause(table))
        ast.where(table.filter) if table.filter
        return ast
      end

      # Reachable via belongs_to: join up to the scoped ancestor (the scope
      # filter is applied at the terminal join inside build_join_clauses_scoped).
      join_clauses = build_join_clauses_scoped(table)
      unless join_clauses.empty?
        join_clauses.each { |join_clause| ast.join(join_clause) }
        ast.where(table.filter) if table.filter
        return ast
      end

      if @allow_reverse
        # Referenced by an extractable (scoped) child: constrain via subquery.
        reverse_clause = build_referenced_by_clause(table)
        if reverse_clause
          ast.where(reverse_clause)
          return ast
        end

        # Unscopable. The Runner/ExplainRunner pre-flight (validate_scope!) rejects
        # these before extraction, so a top-level build never legitimately lands
        # here; if it does, raise rather than emit an unfiltered (potential full
        # PII) dump.
        raise ArgumentError, scope_unscopable_message(table)
      end

      # Unscopable during referenced_by recursion (@allow_reverse == false): return
      # the unconstrained AST so the caller's "constrained child only" check
      # filters this candidate out (it never becomes a real dump query).
      ast
    end

    # The shared column this table is filtered on: a per-table `scope_column`
    # override when present, otherwise the global `--scope-column`.
    private def resolved_scope_column(table)
      table.scope_column || dump_target.scope_column
    end

    private def scope_exempt?(table)
      table.scope_exempt || table.rails_managed?
    end

    private def directly_scoped?(table)
      column = resolved_scope_column(table)
      table.columns.any? { |c| c.name == column }
    end

    private def scope_where_clause(table)
      Exwiw::QueryAst::WhereClause.new(
        column_name: resolved_scope_column(table),
        operator: :eq,
        value: dump_target.ids
      )
    end

    # BFS over belongs_tos to the nearest *directly scoped* ancestor. Unlike the
    # target-mode walk, the returned path INCLUDES that ancestor: the scope column
    # lives on the ancestor itself (not on a foreign key of the child), so the
    # ancestor must be joined and then filtered.
    private def find_path_to_scoped(table)
      visited = {}
      queue = [[table.name, [table.name]]]

      until queue.empty?
        current_table_name, path = queue.shift
        next if visited[current_table_name]
        visited[current_table_name] = true

        current_table = table_by_name[current_table_name]
        next if current_table.nil?

        current_table.belongs_tos.each do |relation|
          next_table_name = relation.table_name
          next_table = table_by_name[next_table_name]
          next if next_table.nil?

          next_path = path + [next_table_name]
          return next_path if directly_scoped?(next_table)

          queue.push([next_table_name, next_path])
        end
      end

      []
    end

    private def build_join_clauses_scoped(table)
      path_tables = find_path_to_scoped(table)
      @logger.debug("  Join path from #{table.name} to a scoped table: #{path_tables}")

      return [] if path_tables.size < 2

      path_tables.each_cons(2).map do |from_table_name, to_table_name|
        from_table = table_by_name[from_table_name]
        to_table = table_by_name[to_table_name]

        join_clause = build_scoped_join_clause(from_table, to_table)

        # Only the final hop's to_table is directly scoped (the BFS stops there),
        # so the scope filter rides on that join's where_clauses, compiled against
        # join_table_name = the scoped ancestor.
        if directly_scoped?(to_table)
          join_clause.where_clauses.push scope_where_clause(to_table)
        end

        if to_table.filter
          join_clause.where_clauses.push to_table.filter
        end

        join_clause
      end
    end

    # One belongs_to hop as a JoinClause, with the polymorphic type condition
    # placed on the source table (base_where_clauses) when the hop is polymorphic
    # — mirroring the target-mode loop in build_join_clauses.
    private def build_scoped_join_clause(from_table, to_table)
      relation = from_table.belongs_to(to_table.name)

      join_clause = QueryAst::JoinClause.new(
        base_table_name: from_table.name,
        foreign_key: relation.foreign_key,
        join_table_name: to_table.name,
        primary_key: to_table.primary_key,
        where_clauses: [],
        base_where_clauses: []
      )

      if relation.polymorphic?
        join_clause.base_where_clauses.push QueryAst::WhereClause.new(
          column_name: relation.foreign_type,
          operator: :eq,
          value: [relation.type_value]
        )
      end

      join_clause
    end

    private def scope_unscopable_message(table)
      "Table '#{table.name}' cannot be scoped in scope-column mode: it has no " \
        "'#{dump_target.scope_column}' column (nor a per-table scope_column override) and no " \
        "belongs_to path to a table that does. Add `scope_exempt: true` to export it in full, " \
        "set `ignore: true` to skip it, or add the missing belongs_to."
    end
  end
end

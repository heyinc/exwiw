# frozen_string_literal: true

module Exwiw
  class QueryAstBuilder
    def self.run(table_name, table_by_name, dump_target, logger, allow_reverse: true, forward_path: [])
      new(table_name, table_by_name, dump_target, logger, allow_reverse: allow_reverse, forward_path: forward_path).run
    end

    # Scope-column mode classification for a single table. One of
    # :exempt / :direct / :via_path / :referenced_by / :via_scoped_parent / :unscopable.
    def self.scope_category(table_name, table_by_name, dump_target, logger)
      new(table_name, table_by_name, dump_target, logger).scope_category
    end

    # Scope-column mode is active when EITHER the named `--target-table` declares a
    # per-table `scope_column` (the preferred trigger: the target is then scoped
    # like any other table — its `--ids` are scope-column values, not primary
    # keys), OR the deprecated `--scope-column` flag is set (a global column with no
    # target). In both cases every table is filtered by a shared column instead of
    # being anchored on one named target's primary key.
    def self.scope_mode?(table_by_name, dump_target)
      return true unless dump_target.scope_column.nil?
      return false if dump_target.table_name.nil?

      target = table_by_name[dump_target.table_name]
      !!(target && target.respond_to?(:scope_column) && target.scope_column)
    end

    # Strict pre-flight for scope-column mode: abort if any extractable table
    # cannot be scoped, so an unscoped (potentially sensitive) table is never
    # silently dumped in full. No-op outside scope mode. `tables` is the set of
    # dumpable configs (ignore:true tables are skipped — they are not extracted).
    def self.validate_scope!(tables, table_by_name, dump_target, logger)
      return unless scope_mode?(table_by_name, dump_target)

      unscopable =
        tables.reject(&:ignore).select do |table|
          scope_category(table.name, table_by_name, dump_target, logger) == :unscopable
        end
      return if unscopable.empty?

      names = unscopable.map(&:name).sort.join(", ")
      raise ArgumentError,
            "scope-column mode: #{unscopable.size} table(s) cannot be scoped: #{names}. " \
            "For each, declare `scope_column: <column>` on the table to filter it directly, " \
            "add a belongs_to path to a table that carries the scope column, mark it " \
            "`scope_exempt: true` to export it in full, or set `ignore: true` to skip it."
    end

    attr_reader :table_name, :table_by_name, :dump_target

    def initialize(table_name, table_by_name, dump_target, logger, allow_reverse: true, forward_path: [])
      @table_name = table_name
      @table_by_name = table_by_name
      @dump_target = dump_target
      @logger = logger
      @allow_reverse = allow_reverse
      # @forward_path is the chain of tables currently being forward-resolved by
      # the "scope via an indirectly-scoped belongs_to parent" rescue
      # (build_belongs_to_scoped_clause). Each forward hop appends the table it is
      # descending from, so the rescue recurses N levels (users -> end_users ->
      # end_user_profiles -> ...) and stops only on a real belongs_to cycle: a
      # table already on the path is not re-resolved, falling through to
      # :unscopable instead of looping forever.
      @forward_path = forward_path
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
      # Opt-in multi-referencer reverse scope (TableConfig#reverse_scope): when
      # the schema author has enumerated the referencers explicitly, constrain
      # the table to the UNION of those referencers' scoped queries instead of
      # the single-referencer auto-detection below (which bails to a full dump
      # once two or more tables reference the table).
      if table.reverse_scope && table.reverse_scope.via.any?
        return build_reverse_scope_via_clause(table)
      end

      candidates = table_by_name.each_value.filter_map do |other|
        next if other.name == table.name

        relation = other.belongs_to(table.name)
        # A polymorphic foreign key stores ids of several models in one column,
        # so projecting it would pull in unrelated parents. Skip it here; the
        # non-polymorphic blob_id on active_storage_attachments is what we want.
        next if relation.nil? || relation.polymorphic?

        # Build the child's own extraction query. allow_reverse:false stops a
        # chain of FK-less tables from recursing back into each other; adding this
        # table to forward_path stops the child from forward-scoping back through
        # it (which would loop) while still letting the child forward-scope
        # through other tables.
        child_query = self.class.run(other.name, table_by_name, dump_target, @logger, allow_reverse: false, forward_path: @forward_path + [table.name])

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

    # Multi-referencer reverse scope (TableConfig#reverse_scope). Builds a
    # `pk IN (SELECT ref1.col1 FROM ref1 <scope> UNION SELECT ref2.col2 ...)`
    # clause for a global-identity table referenced by many scoped tables. Each
    # `via` arm reuses the referencer's own (already-scoped) extraction query —
    # so a per-tenant run keeps only that tenant's ids — projected down to the
    # foreign-key column that points at this table, with NULLs excluded.
    #
    # An arm whose referencer is unknown or comes out unconstrained is skipped
    # with a warning rather than included: an unconstrained arm would project
    # every row's id and union the whole table back, silently defeating the
    # prune. Returns nil when no arm survives, leaving the caller to fall back to
    # the dump-all behavior (which validate_scope! then rejects in scope mode).
    private def build_reverse_scope_via_clause(table)
      arms = table.reverse_scope.via.filter_map do |via|
        referencer = table_by_name[via.table]
        if referencer.nil?
          @logger.warn("  #{table.name}.reverse_scope references unknown table '#{via.table}'; skipping arm.")
          next
        end

        # Build the referencer's own scoped extraction query. allow_reverse is
        # disabled and this table is added to forward_path to bound recursion
        # exactly as the single-referencer path does (a referencer that could only
        # be scoped by recursing back into this table would loop); the referencer
        # may still forward-scope through other tables.
        ref_query = self.class.run(referencer.name, table_by_name, dump_target, @logger, allow_reverse: false, forward_path: @forward_path + [table.name])

        unless ref_query.where_clauses.any? || ref_query.join_clauses.any?
          @logger.warn(
            "  #{table.name}.reverse_scope arm '#{via.table}.#{via.column}' is not scoped; " \
            "skipping it (an unconstrained arm would union every row back). " \
            "Make '#{via.table}' scopable or remove it from reverse_scope.via."
          )
          next
        end

        # Project the referencer's query to the foreign-key column that points
        # at this table, excluding NULLs. Force a plain column so any masking /
        # raw_sql configured on that column does not corrupt the id comparison.
        fk_column = TableColumn.from_symbol_keys(name: via.column)
        projected = QueryAst::Select.new
        projected.from(ref_query.from_table_name)
        projected.select([fk_column])
        ref_query.join_clauses.each { |j| projected.join(j) }
        ref_query.where_clauses.each { |w| projected.where(w) }
        projected.where(QueryAst::WhereClause.new(column_name: via.column, operator: :not_null))
        projected
      end

      return nil if arms.empty?

      QueryAst::WhereClause.new(
        column_name: table.primary_key,
        operator: :in_subquery,
        value: QueryAst::UnionSubquery.new(queries: arms)
      )
    end

    # Scope-column mode. Builds a `fk IN (SELECT parent.pk FROM <parent
    # extraction query>)` clause for a table whose belongs_to parent is itself
    # scopable but carries no scope column of its own — so find_path_to_scoped
    # cannot terminate on it (via_path fails) and nothing references this table
    # (referenced_by fails). The classic shape is a hub scoped only via
    # referenced_by (e.g. CDP `customer_accounts`, scoped by the `customers` that
    # reference it) with sibling detail tables (`customer_account_details`, ...)
    # hanging off it. Constraining those siblings to the hub's in-scope ids keeps
    # them out of a full dump. Returns nil when there is no single, unambiguous
    # scopable parent, leaving the caller on the unscopable path.
    private def build_belongs_to_scoped_clause(table)
      # This table plus every ancestor currently being forward-resolved. A
      # candidate parent already on this path would close a belongs_to cycle, so
      # it is skipped; threading the grown path into the parent build lets the
      # cascade recurse N hops (users -> end_users -> end_user_profiles -> ...)
      # and terminate only when a table reappears.
      forward_path = @forward_path + [table.name]

      candidates = table.belongs_tos.filter_map do |relation|
        # A polymorphic belongs_to points at several parent tables through one
        # column, so it cannot project to a single parent id set; skip it.
        next if relation.polymorphic?

        parent = table_by_name[relation.table_name]
        next if parent.nil?

        # Cycle guard: descending into a parent already on the forward path would
        # loop (a -> b -> a). Stop, leaving this table on the :unscopable path.
        next if forward_path.include?(parent.name)

        # Build the parent's own scoped query. allow_reverse stays true so the
        # parent may be scoped via referenced_by, and forward scoping stays
        # enabled so a parent that is itself scoped via *its* parent resolves
        # too — this is what makes the cascade multi-hop.
        parent_query = self.class.run(parent.name, table_by_name, dump_target, @logger, allow_reverse: true, forward_path: forward_path)

        # Only a constrained parent narrows anything; an unconstrained parent
        # would select every pk (i.e. dump all) and not help.
        next unless parent_query.where_clauses.any? || parent_query.join_clauses.any?

        [relation, parent, parent_query]
      end

      # Only the unambiguous single-parent case. Multiple scopable parents would
      # need their subqueries combined (not supported); fall back to unscopable.
      if candidates.size != 1
        if candidates.size > 1
          @logger.debug("  #{table.name} has multiple scopable parents; skipping forward scope (unscopable).")
        end
        return nil
      end

      relation, parent, parent_query = candidates.first

      # Project the parent's extraction query down to just its primary key — the
      # column this table's foreign key points at.
      pk_column = TableColumn.from_symbol_keys(name: parent.primary_key)
      projected = QueryAst::Select.new
      projected.from(parent_query.from_table_name)
      projected.select([pk_column])
      parent_query.join_clauses.each { |j| projected.join(j) }
      parent_query.where_clauses.each { |w| projected.where(w) }

      QueryAst::WhereClause.new(
        column_name: relation.foreign_key,
        operator: :in_subquery,
        value: QueryAst::SelectSubquery.new(query: projected)
      )
    end

    private def build_where_clauses(table, dump_target)
      clauses = []

      if table.name == dump_target.table_name
        # When `dump_target.ids_field` is set, `--ids` match a non primary-key
        # column on the target table; otherwise fall back to the primary key.
        # Only the target table's filter changes — downstream foreign-key
        # propagation still keys off the primary key.
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
    # `foreign_key IN (ids)` suffices. When `dump_target.ids_field` is set, `--ids`
    # match a non primary-key column instead, so the foreign key must be resolved
    # through the target table:
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
      self.class.scope_mode?(table_by_name, dump_target)
    end

    # Classifier used by validate_scope! and mirrored by build_scoped below.
    def scope_category
      table = table_by_name.fetch(table_name)
      return :exempt if scope_exempt?(table)
      return :direct if directly_scoped?(table)
      return :via_path if build_join_clauses_scoped(table).any?
      return :referenced_by if @allow_reverse && build_referenced_by_clause(table)
      return :via_scoped_parent if forward_scope_allowed?(table) && build_belongs_to_scoped_clause(table)

      :unscopable
    end

    # True when this table may still attempt the forward "scope via a scoped
    # belongs_to parent" rescue: it is not already on the forward-resolution
    # path, so descending into its parent cannot revisit it (a belongs_to cycle).
    private def forward_scope_allowed?(table)
      !@forward_path.include?(table.name)
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
      end

      if forward_scope_allowed?(table)
        # Belongs_to a parent that is itself scoped but carries no scope column of
        # its own (so via_path cannot terminate on it) — e.g. a hub table scoped
        # only via referenced_by, or a parent that is itself scoped through *its*
        # parent. Constrain this table to that parent's in-scope ids so its rows
        # ride along instead of being dumped in full; the parent build recurses
        # the cascade further up.
        parent_clause = build_belongs_to_scoped_clause(table)
        if parent_clause
          ast.where(parent_clause)
          return ast
        end
      end

      # Only the genuine top-level build (allow_reverse on, forward_path empty —
      # i.e. no rescue subquery in progress) is allowed to fail hard. The
      # Runner/ExplainRunner pre-flight (validate_scope!) rejects unscopable
      # tables before extraction, so a top-level build never legitimately lands
      # here; if it does, raise rather than emit an unfiltered (potential full
      # PII) dump.
      if @allow_reverse && @forward_path.empty?
        raise ArgumentError, scope_unscopable_message(table)
      end

      # Unscopable during a reverse/forward subquery build (a rescue is disabled):
      # return the unconstrained AST so the caller's "constrained only" check
      # filters this candidate out (it never becomes a real dump query).
      ast
    end

    # The shared column this table is filtered on: a per-table `scope_column` when
    # declared, otherwise the deprecated global `--scope-column` flag.
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
      "Table '#{table.name}' cannot be scoped in scope-column mode: it carries no scope " \
        "column (no per-table `scope_column` is declared on it) and has no belongs_to path " \
        "to a table that does. Declare `scope_column: <column>` on it, mark it " \
        "`scope_exempt: true` to export it in full, set `ignore: true` to skip it, or add " \
        "the missing belongs_to."
    end
  end
end

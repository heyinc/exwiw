# frozen_string_literal: true

module Exwiw
  class QueryAstBuilder
    def self.run(table_name, table_by_name, dump_target, logger, allow_reverse: true, forward_path: [], batch_ids: nil)
      new(table_name, table_by_name, dump_target, logger, allow_reverse: allow_reverse, forward_path: forward_path, batch_ids: batch_ids).run
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

    # Strict pre-flight: abort if any extractable table cannot be scoped (scope
    # mode), or declares a `batch_scope` its scoping shape cannot be sliced by
    # (both modes) — before any output is written. `tables` is the set of
    # dumpable configs (ignore:true tables are skipped — they are not extracted).
    def self.validate_scope!(tables, table_by_name, dump_target, logger)
      # Unscopable is reported before a bad batch_scope shape — it is the more
      # fundamental problem.
      if scope_mode?(table_by_name, dump_target)
        unscopable =
          tables.reject(&:ignore).select do |table|
            scope_category(table.name, table_by_name, dump_target, logger) == :unscopable
          end

        if unscopable.any?
          names = unscopable.map(&:name).sort.join(", ")
          raise ArgumentError,
                "scope-column mode: #{unscopable.size} table(s) cannot be scoped: #{names}. " \
                "For each, declare `scope_column: <column>` on the table to filter it directly, " \
                "add a belongs_to path to a table that carries the scope column, mark it " \
                "`scope_exempt: true` to export it in full, or set `ignore: true` to skip it."
        end
      end

      tables.reject(&:ignore).each do |table|
        next unless table.respond_to?(:batch_scope) && table.batch_scope

        new(table.name, table_by_name, dump_target, logger).batch_scope_terminus!
      end
    end

    attr_reader :table_name, :table_by_name, :dump_target

    def initialize(table_name, table_by_name, dump_target, logger, allow_reverse: true, forward_path: [], batch_ids: nil)
      @table_name = table_name
      @table_by_name = table_by_name
      @dump_target = dump_target
      @logger = logger
      @allow_reverse = allow_reverse
      # One batch's slice of the batch table's in-scope primary keys, set only by
      # BatchedExtraction. Deliberately not threaded into the recursive builds
      # below, which compile other tables' queries.
      @batch_ids = batch_ids
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

      # Forward cascade. A satellite of a reverse_scope'd (or referenced-by-scoped)
      # hub has no belongs_to path to the dump target, so the clauses above stay
      # empty and it would dump every row. When its belongs_to parent is itself
      # scoped, constrain this table to the parent's in-scope ids — the same
      # multi-hop cascade scope-column mode performs in build_scoped.
      if table.name != dump_target.table_name &&
         where_clauses.empty? && join_clauses.empty? &&
         forward_scope_allowed?(table)
        parent_clause = build_belongs_to_scoped_clause(table)
        if parent_clause
          where_clauses.push(parent_clause)
        elsif @allow_reverse && @forward_path.empty? && !scope_exempt?(table) &&
              scopable_parent_candidates(table).size > 1
          @logger.warn(
            "  #{table.name} belongs_to multiple scopable parents; the cascade cannot " \
            "pick one unambiguously, so it is dumped in full. If this is intended, set " \
            "`scope_exempt: true`. Otherwise, scope it through a single parent (e.g. ignore one belongs_to edge), " \
            "or switch to scope-column mode to scope it directly."
          )
        end
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

    # Builds a `fk IN (SELECT parent.pk FROM <parent extraction query>)` clause
    # for a table whose belongs_to parent is itself scopable but carries no scope
    # column of its own — so find_path_to_scoped cannot terminate on it (via_path
    # fails) and nothing references this table (referenced_by fails). The classic
    # shape is a hub scoped only via referenced_by (e.g. CDP `customer_accounts`,
    # scoped by the `customers` that reference it) with sibling detail tables
    # (`customer_account_details`, ...) hanging off it. Constraining those
    # siblings to the hub's in-scope ids keeps them out of a full dump. Returns
    # nil when there is no single, unambiguous scopable parent, leaving the caller
    # on the unscopable path. Used by both scope-column and single-target mode.
    private def build_belongs_to_scoped_clause(table)
      candidates = scopable_parent_candidates(table)

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

    # The scopable belongs_to parents of `table`: each non-polymorphic parent
    # whose own extraction query comes out constrained, paired with the relation
    # and that query. Shared by build_belongs_to_scoped_clause (which requires
    # exactly one) and the single-target full-dump warning (which flags two or
    # more, since the cascade then cannot disambiguate).
    private def scopable_parent_candidates(table)
      # Memoized: #run can resolve this twice for the same table (once via
      # build_belongs_to_scoped_clause, once for the ambiguous-parent warning),
      # and each pass recursively builds every parent's query.
      (@scopable_parent_candidates ||= {})[table.name] ||= begin
        # This table plus every ancestor currently being forward-resolved; a
        # candidate parent already on this path would close a belongs_to cycle, so
        # it is skipped. Threading the grown path into the parent build lets the
        # cascade recurse N hops and terminate only when a table reappears.
        forward_path = @forward_path + [table.name]

        table.belongs_tos.filter_map do |relation|
          # A polymorphic belongs_to points at several parent tables through one
          # column, so it cannot project to a single parent id set.
          next if relation.polymorphic?

          parent = table_by_name[relation.table_name]
          next if parent.nil?
          next if forward_path.include?(parent.name)

          # allow_reverse and forward scoping stay enabled so the parent may itself
          # be scoped via referenced_by or via *its* parent — this is what makes the
          # cascade multi-hop.
          parent_query = self.class.run(parent.name, table_by_name, dump_target, @logger, allow_reverse: true, forward_path: forward_path)

          # Only a constrained parent narrows anything; an unconstrained parent
          # would select every pk (i.e. dump all) and not help.
          next unless parent_query.where_clauses.any? || parent_query.join_clauses.any?

          [relation, parent, parent_query]
        end
      end
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
      return :via_path if scoped_arms(table).any?
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
      # filter is applied at the terminal join inside build_scoped_join_clauses).
      # A polymorphic hop resolves to one arm per concrete target type, so there
      # may be several such routes; see #scoped_arms.
      arms = scoped_arms(table)
      if arms.size == 1 && arms.first.path
        arm = arms.first
        build_scoped_join_clauses(arm.path, first_relation: arm.relation).each { |join_clause| ast.join(join_clause) }
        ast.where(table.filter) if table.filter
        return ast
      elsif arms.size >= 1
        # Several polymorphic arms: INNER JOINing one of them would drop the rows
        # of every other type, so constrain this table to the UNION of the ids the
        # arms keep instead.
        ast.where(polymorphic_arms_clause(table, arms))
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
      batch_clause = batch_ids_clause(table)
      return batch_clause if batch_clause

      Exwiw::QueryAst::WhereClause.new(
        column_name: resolved_scope_column(table),
        operator: :eq,
        value: dump_target.ids
      )
    end

    # This batch's ids, in place of the batch table's scope filter. nil when the
    # build is not batched or `table` is not the batch table.
    private def batch_ids_clause(table)
      return nil if @batch_ids.nil?

      batch_scope = table_by_name.fetch(table_name).batch_scope
      return nil if batch_scope.nil? || batch_scope.table != table.name

      Exwiw::QueryAst::WhereClause.new(
        column_name: table.primary_key,
        operator: :eq,
        value: @batch_ids
      )
    end

    # The scoped table whose in-scope primary keys slice this table's extraction,
    # or nil when it declares no `batch_scope`. Shapes are accepted only when
    # every row the table keeps is selected through that table's scope filter —
    # otherwise the unconstrained route would re-emit the same rows in every
    # batch — so each rejection below explains itself to the config author.
    def batch_scope_terminus!
      table = table_by_name.fetch(table_name)
      batch_scope = table.batch_scope
      return nil if batch_scope.nil?

      prefix = "Table '#{table.name}': batch_scope"

      unless scope_mode?
        raise ArgumentError,
              "#{prefix} is supported in scope-column mode only. In single `--target-table` mode the " \
              "extraction is already anchored on a caller-supplied id list, which can be batched by " \
              "running exwiw once per slice of `--ids`."
      end

      if scope_exempt?(table)
        raise ArgumentError,
              "#{prefix} cannot apply: the table is exported in full (scope_exempt / rails-managed), " \
              "so there is no scope filter to slice."
      end

      terminus = table_by_name[batch_scope.table]
      if terminus.nil?
        raise ArgumentError, "#{prefix} names table '#{batch_scope.table}', which is not in the schema."
      end
      if terminus.primary_key.nil?
        raise ArgumentError, "#{prefix} table '#{terminus.name}' has no primary_key to slice the extraction by."
      end
      unless directly_scoped?(terminus)
        raise ArgumentError,
              "#{prefix} table '#{terminus.name}' does not carry the scope column " \
              "(#{resolved_scope_column(terminus) || 'none declared'}), so its in-scope ids cannot be " \
              "resolved. Name the scoped table this table joins up to."
      end
      # A scope_exempt terminus carries the column but its own extraction query is
      # unfiltered, so the batches would substitute every tenant's ids for the
      # scope filter the unbatched join still applies.
      if scope_exempt?(terminus)
        raise ArgumentError,
              "#{prefix} table '#{terminus.name}' is exported in full (scope_exempt / rails-managed), " \
              "so its id set is not scoped and every batch would reach outside the scope."
      end

      if directly_scoped?(table)
        return terminus if terminus.name == table.name

        raise ArgumentError,
              "#{prefix} must name '#{table.name}' itself, which carries the scope column and is " \
              "therefore filtered directly rather than through '#{terminus.name}'."
      end

      arms = scoped_arms(table)
      unless arms.size == 1 && arms.first.path
        raise ArgumentError,
              "#{prefix} needs a single belongs_to join path from '#{table.name}' to the scope, but it is " \
              "scoped another way (polymorphic arms / reverse_scope / referenced-by / the parent cascade), " \
              "or not scoped at all. Those other id sets keep rows by routes a batch of '#{terminus.name}' " \
              "ids does not constrain, so every batch would re-emit them."
      end

      path = arms.first.path
      unless path.last == terminus.name
        raise ArgumentError,
              "#{prefix} table '#{terminus.name}' is not where '#{table.name}' reaches the scope " \
              "(#{path.join(' -> ')}); name that path's scoped table, '#{path.last}'."
      end

      terminus
    end

    # BFS over belongs_tos to the nearest *directly scoped* ancestor. Unlike the
    # target-mode walk, the returned path INCLUDES that ancestor: the scope column
    # lives on the ancestor itself (not on a foreign key of the child), so the
    # ancestor must be joined and then filtered.
    #
    # `first_relation` pins the first hop to one specific belongs_to instead of
    # letting the BFS pick it. This is how a single polymorphic arm is resolved
    # (see #scoped_arms): the walk is forced out through that arm's target and
    # then continues normally. The origin is pre-marked visited so the walk can
    # never come back through it — exactly what the unseeded form's first pop
    # does — which also keeps the BFS terminating on a belongs_to cycle.
    private def find_path_to_scoped(table, first_relation: nil)
      visited = {}
      queue =
        if first_relation
          first_table = table_by_name[first_relation.table_name]
          return [] if first_table.nil?

          first_path = [table.name, first_relation.table_name]
          return first_path if directly_scoped?(first_table)

          visited[table.name] = true
          [[first_relation.table_name, first_path]]
        else
          [[table.name, [table.name]]]
        end

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

    # One resolved route from a table to the scope.
    #
    # `relation` is the belongs_to the route leaves through (nil when the plain
    # BFS picked it). Exactly one of the two other members is set:
    #   - `path`         — table names from this table up to a directly-scoped
    #                      ancestor, compiled into a chain of JOINs.
    #   - `target_query` — the arm target's own (already scoped) extraction
    #                      query, used when the target carries no scope column
    #                      and no join path reaches one, but is scoped by other
    #                      means (referenced_by / reverse_scope / the belongs_to
    #                      cascade). The arm then probes that query's ids.
    ScopedArm = Struct.new(:relation, :path, :target_query, keyword_init: true)

    # Every route this table has to the scope.
    #
    # A non-polymorphic belongs_to addresses exactly one parent table, so the
    # single shortest path `find_path_to_scoped` returns is the whole story and
    # this returns one arm — the historical behavior, byte-for-byte.
    #
    # A *polymorphic* hop is different: one (foreign_key, foreign_type) pair
    # addresses several parent tables — one per `type_value` — and each row
    # belongs to whichever arm its type column names. Following a single path
    # therefore extracts only the rows of that one arm and silently drops every
    # other type. (`active_storage_attachments` is the canonical case: the BFS
    # settles on one owner table and the query filters `record_type = '<that
    # one>'`, so attachments of the other 20-odd owner types never make it into
    # the dump.) So when the shortest path leaves through a polymorphic relation,
    # resolve every sibling arm of the same (foreign_key, foreign_type) group.
    #
    # Note the entry condition: this only ever widens a table that *already*
    # reaches the scope through a polymorphic join path. A table with no path at
    # all still returns [] and keeps its existing treatment (referenced_by, the
    # belongs_to cascade, or :unscopable).
    #
    # Arms that reach nothing are **dropped, never widened**: emitting an arm
    # with no scope predicate would pull in every tenant's rows. So the union is
    # only ever as broad as the scoped arms allow.
    private def scoped_arms(table)
      (@scoped_arms ||= {})[table.name] ||= begin
        shortest = find_path_to_scoped(table)
        @logger.debug("  Join path from #{table.name} to a scoped table: #{shortest}")

        if shortest.size < 2
          []
        else
          sibling_arms = polymorphic_sibling_arms(table, shortest[1])
          if sibling_arms.nil?
            [ScopedArm.new(relation: nil, path: shortest)]
          else
            arms = sibling_arms.filter_map { |relation| resolve_scoped_arm(table, relation) }
            @logger.debug(
              "  #{table.name} reaches the scope through #{arms.size} of " \
              "#{sibling_arms.size} polymorphic '#{sibling_arms.first.foreign_type}' arm(s)."
            )
            arms
          end
        end
      end
    end

    # Resolve one polymorphic arm, or nil when its target cannot be scoped.
    #
    # The cheap case is a join path from this table up to a directly-scoped
    # ancestor. When there is none, the target may still be scoped by one of the
    # other mechanisms — most commonly a `reverse_scope`d owner table (one
    # narrowed by the rows that reference it, rather than by a path of its own),
    # whose children therefore have no path of their own. Rather than dropping
    # such an arm, reuse the target's own extraction query as the id set; that
    # query is built by the same recursion every other rescue uses, so it picks
    # up referenced_by / reverse_scope / the multi-hop cascade for free.
    private def resolve_scoped_arm(table, relation)
      path = find_path_to_scoped(table, first_relation: relation)
      return ScopedArm.new(relation: relation, path: path) if path.size >= 2

      target = table_by_name[relation.table_name]
      return nil if target.nil? || target.primary_key.nil?
      # Descending into a table already being resolved would close a cycle.
      return nil if target.name == table.name || @forward_path.include?(target.name)

      target_query = self.class.run(
        target.name, table_by_name, dump_target, @logger,
        allow_reverse: true, forward_path: @forward_path + [table.name]
      )
      # An unconstrained target selects every id, i.e. does not scope the arm at
      # all; dropping the arm is the safe outcome.
      return nil unless target_query.where_clauses.any? || target_query.join_clauses.any?

      # The target is scoped *through this very table* (the classic shape is
      # active_storage_blobs, narrowed by referenced_by from
      # active_storage_attachments, appearing as an `ActiveStorage::Blob` arm of
      # those same attachments). Adopting the arm would make the two tables
      # scope each other: this table's query would widen to rows whose ids the
      # target's query — built without the new arm — never saw, so the target
      # would no longer cover every row this table keeps (a dangling foreign key
      # on import). Drop the arm and leave the pair consistent.
      if QueryAst.reads_table?(target_query, table.name)
        @logger.debug(
          "  Skipping #{table.name} polymorphic arm '#{relation.type_value}': " \
          "#{target.name} is itself scoped through #{table.name}."
        )
        return nil
      end

      ScopedArm.new(relation: relation, target_query: target_query)
    end

    # The polymorphic belongs_to arms sharing the (foreign_key, foreign_type) of
    # the relation this table uses to reach `first_hop_table_name`, or nil when
    # the caller should stay on the single-path behavior: the hop is not
    # polymorphic, or its group has only one arm, or this table has no usable
    # primary key to union the arms on.
    #
    # The relation is looked up with `belongs_to(table_name)` — the same lookup
    # #build_scoped_join_clause performs — so the decision is made about exactly
    # the relation that would be compiled.
    private def polymorphic_sibling_arms(table, first_hop_table_name)
      return nil if table.primary_key.nil?

      relation = table.belongs_to(first_hop_table_name)
      return nil if relation.nil? || !relation.polymorphic?

      arms = table.belongs_tos.select do |other|
        other.polymorphic? &&
          other.foreign_key == relation.foreign_key &&
          other.foreign_type == relation.foreign_type
      end
      arms.size > 1 ? arms : nil
    end

    # Constrain `table` to the UNION of the ids each polymorphic arm's join path
    # keeps:
    #
    #   <table>.<pk> IN (
    #     SELECT <table>.<pk> FROM <table> <arm 1 joins + scope filter>
    #     UNION
    #     SELECT <table>.<pk> FROM <table> <arm 2 joins + scope filter>
    #     ...
    #   )
    #
    # UNION rather than OR because the arms join *different* tables: OR-ing them
    # in one WHERE would need the joins to be outer joins, whereas each arm is a
    # self-contained INNER-JOIN query of exactly the shape a single-arm table
    # already produces. It also lands on the existing scope id-set machinery —
    # the adapters lift a `pk IN (UnionSubquery)` clause into a materialized
    # `SELECT DISTINCT` derived-table JOIN (and the mysql adapter into a session
    # TEMPORARY TABLE), so the arms are evaluated once instead of per outer row,
    # and the DISTINCT keeps the row set identical to the IN form.
    #
    # The projected primary key is forced to a plain column so any masking
    # (`replace_with` / `raw_sql`) configured on it cannot corrupt the id
    # comparison — the same guard the reverse-scope projections use.
    private def polymorphic_arms_clause(table, arms)
      pk_column = TableColumn.from_symbol_keys(name: table.primary_key)

      queries = arms.map do |arm|
        query = QueryAst::Select.new
        query.from(table.name)
        query.select([pk_column])

        if arm.path
          build_scoped_join_clauses(arm.path, first_relation: arm.relation).each { |jc| query.join(jc) }
        else
          # The arm's target is scoped without a join path of its own, so probe
          # its id set instead of joining up to a scoped ancestor. The type
          # column still has to be constrained: the foreign key alone cannot tell
          # this arm's rows from another arm's (record_id=1 may be any type).
          target = table_by_name.fetch(arm.relation.table_name)
          query.where QueryAst::WhereClause.new(
            column_name: arm.relation.foreign_key,
            operator: :in_subquery,
            value: QueryAst::SelectSubquery.new(
              query: project_query_to(arm.target_query, target.primary_key)
            )
          )
          query.where QueryAst::WhereClause.new(
            column_name: arm.relation.foreign_type,
            operator: :eq,
            value: [arm.relation.type_value]
          )
        end

        query
      end

      QueryAst::WhereClause.new(
        column_name: table.primary_key,
        operator: :in_subquery,
        value: QueryAst::UnionSubquery.new(queries: queries)
      )
    end

    # Reduce an extraction query to a single-column id projection, keeping its
    # joins and filters. The column is forced to a plain TableColumn so any
    # masking (`replace_with` / `raw_sql`) configured on it cannot corrupt the id
    # comparison.
    private def project_query_to(query, column_name)
      projected = QueryAst::Select.new
      projected.from(query.from_table_name)
      projected.select([TableColumn.from_symbol_keys(name: column_name)])
      query.join_clauses.each { |join_clause| projected.join(join_clause) }
      query.where_clauses.each { |where_clause| projected.where(where_clause) }
      projected
    end

    # Compile one route (a table-name path from this table up to a directly
    # scoped ancestor) into JoinClauses. `first_relation` pins the first hop's
    # belongs_to when the caller resolved it explicitly (a polymorphic arm);
    # otherwise every hop is looked up by target table name, as before.
    private def build_scoped_join_clauses(path_tables, first_relation: nil)
      return [] if path_tables.size < 2

      path_tables.each_cons(2).with_index.map do |(from_table_name, to_table_name), idx|
        from_table = table_by_name[from_table_name]
        to_table = table_by_name[to_table_name]

        hop_relation = idx.zero? ? first_relation : nil
        join_clause = build_scoped_join_clause(from_table, to_table, hop_relation)

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
    #
    # `relation` may be supplied to pin the hop to one specific belongs_to. The
    # name-based lookup cannot express "this arm": a table can declare several
    # relations to the same target (e.g. active_storage_attachments has both the
    # plain `blob_id` and the polymorphic `record_id`/`ActiveStorage::Blob` edge
    # to active_storage_blobs) and #belongs_to returns whichever comes first, so
    # a polymorphic arm resolved by #scoped_arms passes itself in.
    private def build_scoped_join_clause(from_table, to_table, relation = nil)
      relation ||= from_table.belongs_to(to_table.name)

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

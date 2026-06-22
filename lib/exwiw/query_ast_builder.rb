# frozen_string_literal: true

module Exwiw
  class QueryAstBuilder
    def self.run(table_name, table_by_name, dump_target, logger, allow_reverse: true, allow_forward: true, mode: nil)
      new(table_name, table_by_name, dump_target, logger, allow_reverse: allow_reverse, allow_forward: allow_forward, mode: mode).run
    end

    # Scope-column mode classification for a single table. One of
    # :exempt / :direct / :via_path / :referenced_by / :via_scoped_parent / :unscopable.
    # Always evaluated with scope-column semantics (mode: :scope) so it is correct
    # even in hybrid mode, where the instance's own mode would be :hybrid.
    def self.scope_category(table_name, table_by_name, dump_target, logger)
      new(table_name, table_by_name, dump_target, logger, mode: :scope).scope_category
    end

    # Strict pre-flight for scope-column mode: abort if any extractable table
    # cannot be scoped, so an unscoped (potentially sensitive) table is never
    # silently dumped in full. No-op outside scope mode. `tables` is the set of
    # dumpable configs (ignore:true tables are skipped — they are not extracted).
    def self.validate_scope!(tables, table_by_name, dump_target, logger)
      return if dump_target.scope_column.nil?
      # Hybrid mode (target + scope-column) has its own, looser pre-flight: a
      # table only target-reachable is fine there, so the all-tables-scopable
      # check below must not run. See validate_hybrid!.
      return unless dump_target.table_name.nil?

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

    # Strict pre-flight for hybrid mode (both --target-table and --scope-column
    # set). No-op otherwise. Enforces the two invariants that make the OR-union of
    # the target and scope-column extractions well-formed:
    #
    #   1. The target table must carry the scope column, since the scope values
    #      are *derived* from it (`scope_column IN (SELECT target.scope_column
    #      FROM target WHERE <target ids>)`); without it there is nothing to
    #      derive from.
    #   2. Every extractable table must be resolvable by the target anchor OR by
    #      the scope column — otherwise it would be dumped in full (the same PII
    #      risk validate_scope! guards in pure scope mode).
    #
    # Note: this does NOT statically guarantee referential closure of the union.
    # The union of the (individually closed) target and scope extractions is
    # closed in the common case — including when the scope column is a foreign key
    # to a hub the target also reaches — but an exotic shape (a scope-broadened
    # table whose belongs_to parent has several scoped referencers, so it is only
    # narrowly reached by the target) can leave a dangling foreign key at import.
    # A correct check needs value-level reasoning; instead hybrid runs are
    # insert-only (see CLI) and the caveat is documented. Add a belongs_to path or
    # `scope_exempt: true` on such a parent if it surfaces.
    def self.validate_hybrid!(tables, table_by_name, dump_target, logger)
      return if dump_target.table_name.nil? || dump_target.scope_column.nil?

      target = table_by_name[dump_target.table_name]
      if target && !target.columns.any? { |c| c.name == dump_target.scope_column }
        raise ArgumentError,
              "hybrid mode (--target-table + --scope-column): target table " \
              "'#{dump_target.table_name}' does not carry the scope column " \
              "'#{dump_target.scope_column}', so scope values cannot be derived from it. " \
              "Use a target table that carries the scope column, or drop --scope-column."
      end

      unresolvable = tables.reject(&:ignore).reject do |table|
        target_reachable?(table, table_by_name, dump_target, logger) ||
          scope_reachable?(table, table_by_name, dump_target, logger)
      end
      return if unresolvable.empty?

      names = unresolvable.map(&:name).sort.join(", ")
      raise ArgumentError,
            "hybrid mode: #{unresolvable.size} table(s) are reachable neither from " \
            "--target-table '#{dump_target.table_name}' nor by --scope-column " \
            "'#{dump_target.scope_column}': #{names}. For each, add a belongs_to path, " \
            "set `scope_exempt: true` to export it in full, or `ignore: true` to skip it."
    end

    def self.target_reachable?(table, table_by_name, dump_target, logger)
      return true if table.name == dump_target.table_name

      query = new(table.name, table_by_name, dump_target, logger, mode: :target).run
      query.where_clauses.any? || query.join_clauses.any?
    end

    def self.scope_reachable?(table, table_by_name, dump_target, logger)
      scope_category(table.name, table_by_name, dump_target, logger) != :unscopable
    end

    attr_reader :table_name, :table_by_name, :dump_target

    def initialize(table_name, table_by_name, dump_target, logger, allow_reverse: true, allow_forward: true, mode: nil)
      @table_name = table_name
      @table_by_name = table_by_name
      @dump_target = dump_target
      @logger = logger
      @allow_reverse = allow_reverse
      # @allow_forward gates the "scope via an indirectly-scoped belongs_to
      # parent" rescue (build_belongs_to_scoped_clause). Disabled while building a
      # parent/child subquery so a single forward hop never recurses into another
      # (which could loop on a belongs_to cycle).
      @allow_forward = allow_forward
      # :target / :scope / :hybrid. Inferred from the dump target when not forced.
      # build_hybrid forces :target and :scope on its sub-builds so each branch is
      # internally consistent; recursive subquery builds inherit this instance's
      # mode (see the `mode: @mode` recursive run calls) instead of re-inferring
      # :hybrid from the dump target.
      @mode = mode || infer_mode
    end

    private def infer_mode
      has_scope = !dump_target.scope_column.nil?
      has_target = !dump_target.table_name.nil?
      return :hybrid if has_scope && has_target
      return :scope if has_scope

      :target
    end

    def run
      table = table_by_name.fetch(table_name)

      case @mode
      when :hybrid
        build_hybrid(table)
      when :scope
        build_scoped(table)
      else
        build_target(table)
      end
    end

    private def build_target(table)
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

    # Hybrid mode: a table is the UNION (`OR`) of however it is reachable from the
    # single `--target-table` anchor AND however it is reachable by the shared
    # `--scope-column` (whose values are derived from the target — see
    # scope_where_clause). A table matched by both branches broadens to cover both
    # row sets; one query per table is still emitted, and because each branch is an
    # `pk IN (<branch projected to pk>)` subquery there is no row fan-out (no
    # duplicate rows). validate_hybrid! has already rejected tables reachable by
    # neither branch, so this only ever composes genuinely reachable branches.
    private def build_hybrid(table)
      # Reference/master/rails-managed: exported in full regardless of anchor.
      return build_full_dump(table) if scope_exempt?(table)

      branches = []

      target_branch = self.class.run(
        table.name, table_by_name, dump_target, @logger,
        allow_reverse: @allow_reverse, allow_forward: @allow_forward, mode: :target
      )
      branches << target_branch if constrained?(target_branch)

      if scope_category_for(table) != :unscopable
        scope_branch = self.class.run(
          table.name, table_by_name, dump_target, @logger,
          allow_reverse: @allow_reverse, allow_forward: @allow_forward, mode: :scope
        )
        branches << scope_branch if constrained?(scope_branch)
      end

      return compose_or(table, branches) if branches.size > 1
      return branches.first if branches.size == 1

      # Neither branch constrained: would be a full dump. validate_hybrid! rejects
      # such tables before extraction, so this is defensive — return the
      # (unconstrained) target build rather than inventing a filter.
      target_branch
    end

    private def constrained?(query)
      query.where_clauses.any? || query.join_clauses.any?
    end

    private def scope_category_for(table)
      self.class.new(
        table.name, table_by_name, dump_target, @logger,
        allow_reverse: @allow_reverse, allow_forward: @allow_forward, mode: :scope
      ).scope_category
    end

    private def build_full_dump(table)
      ast = QueryAst::Select.new
      ast.from(table.name)
      if table.rails_managed?
        ast.select_all!
      else
        ast.select(table.columns)
      end
      ast
    end

    # Compose several independent per-table resolutions into one query that
    # selects the table's (masked) columns where its primary key is in ANY branch.
    # Each branch is projected down to the table's primary key and OR'd, so the
    # outer query has no join fan-out and emits each row at most once.
    private def compose_or(table, branches)
      ast = QueryAst::Select.new
      ast.from(table.name)
      if table.rails_managed?
        ast.select_all!
      else
        ast.select(table.columns)
      end

      or_conditions = branches.map { |branch| pk_in_subquery(table, branch) }
      ast.where(QueryAst::WhereClause.new(column_name: nil, operator: :or, value: or_conditions))
      ast
    end

    private def pk_in_subquery(table, branch_query)
      pk_column = TableColumn.from_symbol_keys(name: table.primary_key)
      projected = QueryAst::Select.new
      projected.from(branch_query.from_table_name)
      projected.select([pk_column])
      branch_query.join_clauses.each { |j| projected.join(j) }
      branch_query.where_clauses.each { |w| projected.where(w) }

      QueryAst::WhereClause.new(
        column_name: table.primary_key,
        operator: :in_subquery,
        value: QueryAst::SelectSubquery.new(query: projected)
      )
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
        # chain of FK-less tables from recursing back into each other;
        # allow_forward:false stops the child from forward-scoping back through
        # this very table (which would loop).
        child_query = self.class.run(other.name, table_by_name, dump_target, @logger, allow_reverse: false, allow_forward: false, mode: @mode)

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
      candidates = table.belongs_tos.filter_map do |relation|
        # A polymorphic belongs_to points at several parent tables through one
        # column, so it cannot project to a single parent id set; skip it.
        next if relation.polymorphic?

        parent = table_by_name[relation.table_name]
        next if parent.nil?

        # Build the parent's own scoped query. allow_reverse stays true so the
        # parent may be scoped via referenced_by; allow_forward:false bounds this
        # to a single forward hop so a belongs_to cycle cannot loop.
        parent_query = self.class.run(parent.name, table_by_name, dump_target, @logger, allow_reverse: true, allow_forward: false, mode: @mode)

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

    # Classifier used by validate_scope! and mirrored by build_scoped below.
    def scope_category
      table = table_by_name.fetch(table_name)
      return :exempt if scope_exempt?(table)
      return :direct if directly_scoped?(table)
      return :via_path if build_join_clauses_scoped(table).any?
      return :referenced_by if @allow_reverse && build_referenced_by_clause(table)
      return :via_scoped_parent if @allow_forward && build_belongs_to_scoped_clause(table)

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
      end

      if @allow_forward
        # Belongs_to a parent that is itself scoped but carries no scope column of
        # its own (so via_path cannot terminate on it) — e.g. a hub table scoped
        # only via referenced_by. Constrain this table to that parent's in-scope
        # ids so its rows ride along instead of being dumped in full.
        parent_clause = build_belongs_to_scoped_clause(table)
        if parent_clause
          ast.where(parent_clause)
          return ast
        end
      end

      # Only the genuine top-level build (no rescue disabled) is allowed to fail
      # hard. The Runner/ExplainRunner pre-flight (validate_scope!) rejects
      # unscopable tables before extraction, so a top-level build never
      # legitimately lands here; if it does, raise rather than emit an unfiltered
      # (potential full PII) dump.
      if @allow_reverse && @allow_forward
        raise ArgumentError, scope_unscopable_message(table)
      end

      # Unscopable during a reverse/forward subquery build (a rescue is disabled):
      # return the unconstrained AST so the caller's "constrained only" check
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

    # In pure scope-column mode the scope values are the literal `--ids`. In
    # hybrid mode (a target table is also set) the `--ids` belong to the target's
    # id-space, not the scope column's, so the scope values are *derived* from the
    # target instead: `scope_column IN (SELECT target.scope_column FROM target
    # WHERE <target ids>)`. The outer column may be a per-table `scope_column`
    # override while the derived values always come from the target's
    # `--scope-column` (the same shared value-space).
    private def scope_where_clause(table)
      column = resolved_scope_column(table)

      if dump_target.table_name
        target = table_by_name.fetch(dump_target.table_name)
        return Exwiw::QueryAst::WhereClause.new(
          column_name: column,
          operator: :in_subquery,
          value: Exwiw::QueryAst::Subquery.new(
            table_name: target.name,
            select_column: dump_target.scope_column,
            where_column: dump_target.ids_field || target.primary_key,
            where_values: dump_target.ids
          )
        )
      end

      Exwiw::QueryAst::WhereClause.new(
        column_name: column,
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

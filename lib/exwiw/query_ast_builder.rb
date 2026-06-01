# frozen_string_literal: true

module Exwiw
  class QueryAstBuilder
    def self.run(table_name, table_by_name, dump_target, logger, allow_reverse: true)
      new(table_name, table_by_name, dump_target, logger, allow_reverse: allow_reverse).run
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
  end
end

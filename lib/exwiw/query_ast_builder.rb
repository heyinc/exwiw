# frozen_string_literal: true

module Exwiw
  class QueryAstBuilder
    def self.run(table_name, table_by_name, dump_target, logger)
      new(table_name, table_by_name, dump_target, logger).run
    end

    attr_reader :table_name, :table_by_name, :dump_target

    def initialize(table_name, table_by_name, dump_target, logger)
      @table_name = table_name
      @table_by_name = table_by_name
      @dump_target = dump_target
      @logger = logger
    end

    def run
      table = table_by_name.fetch(table_name)

      where_clauses = build_where_clauses(table, dump_target)
      join_clauses = build_join_clauses(table, table_by_name, dump_target)

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

        # この hop 自体が polymorphic belongs_to の場合 (例: comments が
        # commentable として posts へ polymorphic belongs_to)、型カラム
        # (foreign_type) は結合元テーブル (from_table = base_table_name) 側に
        # 存在する。外部キーだけでは reviewable_id=1 のような値が別モデルの
        # 行と衝突しうるため、base_where_clauses に型条件を追加して結合元
        # テーブルを絞り込む。
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

          # 中間テーブルが dump target へ polymorphic belongs_to している場合は、
          # 型カラム (foreign_type) も join 条件に追加する。型カラムは to_table
          # (= join_table_name) 上に存在するため、JoinClause の where_clauses が
          # join_table_name に対してコンパイルされる仕組みにそのまま乗せられる。
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

      # polymorphic belongs_to の場合は外部キーだけでは型を区別できないため
      # (例: reviewable_id=1 が Product なのか別モデルなのか判別できない)、
      # 型カラム (foreign_type) を type_value で絞り込む条件を追加する。
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

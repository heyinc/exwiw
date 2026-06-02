# frozen_string_literal: true

module Exwiw
  module QueryAst
    class JoinClause
      # `where_clauses` is compiled against this join's join_table_name (the
      # joined-to table). `base_where_clauses`, on the other hand, is compiled
      # against base_table_name (the joined-from table). The latter is used for
      # the case where the source table polymorphically belongs_to the joined-to
      # table and the type column (foreign_type) lives on the source table.
      attr_reader :base_table_name, :foreign_key, :join_table_name, :primary_key, :where_clauses, :base_where_clauses

      def initialize(base_table_name:, foreign_key:, join_table_name:, primary_key:, where_clauses: [], base_where_clauses: [])
        @base_table_name = base_table_name
        @foreign_key = foreign_key
        @join_table_name = join_table_name
        @primary_key = primary_key
        @where_clauses = where_clauses
        @base_where_clauses = base_where_clauses
      end

      def to_h
        hash = {
          base_table_name: base_table_name,
          foreign_key: foreign_key,
          join_table_name: join_table_name,
          primary_key: primary_key,
        }
        if where_clauses.size.positive?
          hash[:where_clauses] = where_clauses.map { |wc| wc.is_a?(String) ? wc : wc.to_h }
        end
        if base_where_clauses.size.positive?
          hash[:base_where_clauses] = base_where_clauses.map { |wc| wc.is_a?(String) ? wc : wc.to_h }
        end
        hash
      end
    end

    WhereClause = Struct.new(:column_name, :operator, :value, keyword_init: true) do
      def to_h
        {
          column_name: column_name,
          operator: operator,
          value: value.is_a?(Subquery) || value.is_a?(SelectSubquery) ? value.to_h : value,
        }
      end
    end

    # Resolves a set of values on `where_column` to the rows' `select_column`
    # via a nested SELECT. Used as the `value` of a WhereClause whose operator
    # is `:in_subquery`, so `--ids-column`/`--ids-field` can filter related
    # tables through the target table's primary key:
    #
    #   <table>.<fk> IN (SELECT <table_name>.<select_column>
    #                    FROM <table_name>
    #                    WHERE <table_name>.<where_column> IN (<where_values>))
    Subquery = Struct.new(:table_name, :select_column, :where_column, :where_values, keyword_init: true) do
      def to_h
        {
          table_name: table_name,
          select_column: select_column,
          where_column: where_column,
          where_values: where_values,
        }
      end
    end

    # A subquery whose body is a full `Select`, projected down to a single
    # column. Unlike the flat `Subquery` above (one column = one IN-list), this
    # carries the referencing table's complete extraction query — joins,
    # multiple where conditions, polymorphic type filters and all. Used by the
    # reverse / "referenced_by" extraction so a parent table with no belongs_to
    # path to the dump target (e.g. active_storage_blobs) is constrained to only
    # the rows referenced by an extractable child table:
    #
    #   <parent>.<pk> IN (SELECT <child>.<fk> FROM <child> WHERE <child filters>)
    #
    # `query` is the child's `Select` already projected to the foreign-key
    # column that points at the parent.
    SelectSubquery = Struct.new(:query, keyword_init: true) do
      def to_h
        { query: query.to_h }
      end
    end

    module ColumnValue
      Base = Struct.new(:name, :value, keyword_init: true)
      Plain = Class.new(Base)
      ReplaceWith = Class.new(Base)
      RawSql = Class.new(Base)
    end

    class Select
      attr_reader :from_table_name, :columns, :where_clauses, :join_clauses, :select_all

      def initialize
        @from_table_name = nil
        @columns = []
        @where_clauses = []
        @join_clauses = []
        @select_all = false
      end

      def from(table)
        @from_table_name = table
      end

      def select(columns)
        @columns = map_column_value(columns)
      end

      def select_all!
        @select_all = true
      end

      def where(where_clause)
        @where_clauses << where_clause
      end

      def join(join_clause)
        @join_clauses << join_clause
      end

      def to_h
        {
          from: from_table_name,
          columns: select_all ? "*" : columns.map { |c| { name: c.name, value: c.value } },
          joins: join_clauses.map(&:to_h),
          where: where_clauses.map { |w| w.is_a?(String) ? w : w.to_h },
        }
      end

      private def map_column_value(columns)
        columns.map do |c|
          if c.raw_sql
            QueryAst::ColumnValue::RawSql.new(name: c.name, value: c.raw_sql)
          elsif c.replace_with
            QueryAst::ColumnValue::ReplaceWith.new(name: c.name, value: c.replace_with)
          else
            QueryAst::ColumnValue::Plain.new(name: c.name, value: c.name)
          end
        end
      end
    end
  end
end

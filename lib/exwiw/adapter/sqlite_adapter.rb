# frozen_string_literal: true

module Exwiw
  module Adapter
    class SqliteAdapter < Base
      include SqlBulkInsert

      # A lazy, streaming stand-in for the materialized rows #execute used to
      # return (`connection.execute(sql)`). It walks the result one row at a time
      # via SQLite's statement cursor (Statement#each -> sqlite3_step) instead of
      # buffering the whole result set, so the dump's dominant memory cost — a
      # Ruby array as large as the table — never materializes. The Runner drives
      # it exactly like the old Array: #size to skip empty tables and log the
      # count, then a single streaming pass (SqlBulkInsert#write_inserts ->
      # each_slice) to write the INSERT.
      #
      # Mirrors Mysql/PostgresqlAdapter::StreamingResult, with two SQLite
      # specifics:
      #   - #size runs a separate `SELECT COUNT(*)` of the same query with the
      #     projection replaced by COUNT(*) (compile_ast(count_only: true)) —
      #     exact because exwiw's extraction queries have no DISTINCT/GROUP
      #     BY/LIMIT, so the row count is independent of the projection. (Unlike
      #     MySQL, SQLite tolerates a duplicate-column subquery wrap too, but the
      #     count_only form is shared with MySQL and avoids the extra subquery.)
      #   - SQLite is an embedded, single-connection engine that allows several
      #     active prepared statements at once, so the #size COUNT and the data
      #     cursor do not contend. The statement is closed in an ensure block so
      #     an abandoned mid-stream iteration still releases the cursor.
      class StreamingResult
        include Enumerable

        def initialize(connection:, data_sql:, count_sql:)
          @connection = connection
          @data_sql = data_sql
          @count_sql = count_sql
        end

        def size
          @size ||= @connection.execute(@count_sql).dig(0, 0).to_i
        end
        alias length size

        # Stream the result set row by row. Each row is an Array of values in
        # SQLite's native type mapping — byte-identical to what
        # `connection.execute(sql)` produced, so the generated INSERT is unchanged.
        def each
          return enum_for(:each) { size } unless block_given?

          statement = @connection.prepare(@data_sql)
          begin
            statement.each { |row| yield row }
          ensure
            statement.close
          end
          self
        end
      end

      def build_query(table, dump_target, table_by_name)
        Exwiw::QueryAstBuilder.run(table.name, table_by_name, dump_target, @logger)
      end

      def execute(query_ast)
        data_sql = commented_sql(query_ast)
        # Count via the same FROM/JOIN/WHERE (projection replaced by COUNT(*)) so
        # the Runner can skip empty tables and log the row count without draining
        # the cursor. See StreamingResult for why this is exact.
        count_sql = "#{sql_query_comment(query_ast)} #{compile_ast(query_ast, count_only: true)}"

        @logger.debug("  Executing SQL (cursor stream): \n#{data_sql}")
        StreamingResult.new(connection: connection, data_sql: data_sql, count_sql: count_sql)
      end

      def explain(query_ast, verbosity: nil)
        sql = commented_sql(query_ast)

        @logger.debug("  Executing EXPLAIN QUERY PLAN: \n#{sql}")
        rows = connection.execute("EXPLAIN QUERY PLAN #{sql}")
        rows.map { |row| row[3] }.join("\n")
      end

      def dump_schema(ordered_tables, output_path)
        @logger.debug("  Reading schema from sqlite_master...")
        # Full-database schema dump: emit DDL for every table in the database,
        # not just the config-scoped tables. A table absent from the config gets
        # its schema here but no data (empty INSERT), which is the intended
        # result — the restore target then has every relation even when exwiw was
        # configured to extract only a subset. `ordered_tables` no longer selects
        # which tables are emitted; it is kept only for the log line.
        #
        # `sqlite_master` row order preserves creation order, which is also the
        # dependency order produced by ActiveRecord-style migrations (and lists a
        # table before its owned indexes/triggers), so emitting rows in that
        # order keeps each table's DDL ahead of its dependents.
        all = connection.execute(<<~SQL)
          SELECT type, name, tbl_name, sql FROM sqlite_master
          WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
        SQL

        indexes_by_owner = all.select { |type, _, _, _| type == 'index'   }.group_by { |_, _, tbl, _| tbl }
        triggers_by_owner = all.select { |type, _, _, _| type == 'trigger' }.group_by { |_, _, tbl, _| tbl }

        statements = []
        all.select { |type, _, _, _| type == 'table' }.each do |_, name, _, table_sql|
          statements << finalize_stmt(DdlPostprocessor.add_if_not_exists_to_create_table(table_sql.strip))
          (indexes_by_owner[name] || []).each do |_, _, _, idx_sql|
            statements << finalize_stmt(DdlPostprocessor.add_if_not_exists_to_create_index(idx_sql.strip))
          end
          (triggers_by_owner[name] || []).each do |_, _, _, trg_sql|
            statements << finalize_stmt(trg_sql.strip)
          end
        end

        File.open(output_path, 'w') do |file|
          file.puts("-- Auto-generated by exwiw. Idempotent CREATE statements for SQLite.")
          file.puts(statements.join("\n"))
        end
        @logger.info("  Wrote #{statements.size} schema statement(s) to #{output_path} (#{ordered_tables.size} table(s) in scope for data).")
      end

      private def finalize_stmt(stmt)
        stmt.end_with?(';') ? stmt : "#{stmt};"
      end

      # The INSERT header for this adapter. SQLite uses bare identifiers.
      # #to_bulk_insert / #write_inserts (SqlBulkInsert) append the value tuples
      # and the trailing `;`.
      private def insert_header(table)
        table_name = table.name
        if table.rails_managed?
          "INSERT INTO #{table_name} VALUES\n"
        else
          column_names = table.columns.map(&:name).join(', ')
          "INSERT INTO #{table_name} (#{column_names}) VALUES\n"
        end
      end

      def to_bulk_delete(select_query_ast, table)
        raise NotImplementedError unless select_query_ast.is_a?(Exwiw::QueryAst::Select)

        sql = "DELETE FROM #{select_query_ast.from_table_name}"

        if select_query_ast.join_clauses.empty?
          # Ignore filter option, because bulk delete is for cleaning before import,
          # so it should delete all records to avoid foreign key violation & data consistancy.
          compiled_where_conditions = select_query_ast.
            where_clauses.
            select { |where| where.is_a?(Exwiw::QueryAst::WhereClause) }.
            map do |where|
            compile_where_condition(where, select_query_ast.from_table_name)
          end

          if compiled_where_conditions.size > 0
            sql += "\nWHERE "
            sql += compiled_where_conditions.join(' AND ')
          end
          sql += ";"

          return sql
        end

        subquery_ast = Exwiw::QueryAst::Select.new
        first_join = select_query_ast.join_clauses.first.clone

        subquery_ast.from(first_join.join_table_name)
        primay_key_col = table.columns.find { |col| col.name == table.primary_key }
        subquery_ast.select([primay_key_col])
        select_query_ast.join_clauses[1..].each do |join|
          subquery_ast.join(join)
        end
        first_join.where_clauses.each do |where|
          # Ignore filter option, because bulk delete is for cleaning before import,
          # so it should delete all records to avoid foreign key violation & data consistancy.
          subquery_ast.where(where) if where.is_a?(Exwiw::QueryAst::WhereClause)
        end

        foreign_key = first_join.foreign_key
        subquery_sql = compile_ast(subquery_ast)
        sql += "\nWHERE #{select_query_ast.from_table_name}.#{foreign_key} IN (#{subquery_sql})"

        # first_join.base_where_clauses holds conditions on the outer
        # delete-target table (from_table_name), such as a polymorphic type
        # column. They are not part of the subquery, so add them to the outer
        # WHERE. This prevents deleting rows that belong to a different
        # polymorphic type.
        first_join.base_where_clauses.each do |where|
          next unless where.is_a?(Exwiw::QueryAst::WhereClause)

          sql += " AND #{compile_where_condition(where, select_query_ast.from_table_name)}"
        end
        sql += ";"

        sql
      end

      # @param count_only [Boolean] emit `SELECT COUNT(*)` instead of the
      #   projected columns (used by StreamingResult#size). Safe because exwiw's
      #   extraction queries have no DISTINCT/GROUP BY/LIMIT, so the count does
      #   not depend on the projection.
      def compile_ast(query_ast, count_only: false)
        raise NotImplementedError unless query_ast.is_a?(Exwiw::QueryAst::Select)

        # Lift scope id-set clauses (reverse_scope UNION / forward cascade /
        # single referenced_by) out of `WHERE <col> IN (subquery)` and into a
        # JOIN against a materialized derived table. See #compile_scope_join.
        scope_clauses, plain_where_clauses = partition_scope_clauses(query_ast.where_clauses)

        sql = "SELECT "
        sql += if count_only
                 "COUNT(*)"
               elsif query_ast.select_all
                 # A lifted scope JOIN brings a derived table into FROM, so a bare
                 # `*` would also project its column. Qualify to this table's own.
                 scope_clauses.any? ? "#{query_ast.from_table_name}.*" : "*"
               else
                 query_ast.columns.map { |col| compile_column_name(query_ast, col) }.join(', ')
               end
        sql += " FROM #{query_ast.from_table_name}"

        query_ast.join_clauses.each do |join|
          sql += " JOIN #{join.join_table_name} ON #{join.base_table_name}.#{join.foreign_key} = #{join.join_table_name}.#{join.primary_key}"

          join.where_clauses.each do |where|
            compiled_where_condition = compile_where_condition(where, join.join_table_name)
            sql += " AND #{compiled_where_condition}"
          end

          # base_where_clauses is compiled against the joined-from table
          # (base_table_name), e.g. the type-column filter on a polymorphic
          # source table.
          join.base_where_clauses.each do |where|
            compiled_where_condition = compile_where_condition(where, join.base_table_name)
            sql += " AND #{compiled_where_condition}"
          end
        end

        scope_clauses.each_with_index do |where_clause, idx|
          sql += " #{compile_scope_join(query_ast.from_table_name, where_clause, idx)}"
        end

        if plain_where_clauses.any?
          sql += " WHERE "
          sql += plain_where_clauses.map { |where| compile_where_condition(where, query_ast.from_table_name) }.join(' AND ')
        end

        sql
      end

      # Render a scope id-set clause as a JOIN to a materialized derived table
      # (see MysqlAdapter#compile_scope_join for the full rationale). The DISTINCT
      # forces the engine to materialize the id-set once and probe this table by
      # it, instead of full-scanning and re-evaluating a correlated subquery per
      # row; it also dedups, so the join is row-for-row identical to
      # `<col> IN (subquery)`.
      private def compile_scope_join(from_table_name, where_clause, idx)
        subquery = where_clause.value
        projection = subquery_projection_name(subquery)
        src_alias = "exwiw_scope_src_#{idx}"
        ids_alias = "exwiw_scope_ids_#{idx}"
        outer_key = "#{from_table_name}.#{where_clause.column_name}"

        "JOIN (SELECT DISTINCT #{src_alias}.#{projection} AS exwiw_scope_id " \
          "FROM (#{compile_subquery(subquery)}) AS #{src_alias}) AS #{ids_alias} " \
          "ON #{outer_key} = #{ids_alias}.exwiw_scope_id"
      end

      private def compile_where_condition(where_clause, table_name)
        # Use as it is if it's a raw query
        return where_clause if where_clause.is_a?(String)

        key = "#{table_name}.#{where_clause.column_name}"

        if where_clause.operator == :eq
          values = where_clause.value.map { |v| escape_value(v) }

          if values.size == 1
            "#{key} = #{values.first}"
          else
            "#{key} IN (#{values.join(', ')})"
          end
        elsif where_clause.operator == :in_subquery
          "#{key} IN (#{compile_subquery(where_clause.value)})"
        elsif where_clause.operator == :not_null
          "#{key} IS NOT NULL"
        else
          raise "Unsupported operator: #{where_clause.operator}"
        end
      end

      private def compile_subquery(subquery)
        # A SelectSubquery wraps a full Select (the referencing table's
        # extraction query, projected to a foreign key); compile it as-is.
        return compile_ast(subquery.query) if subquery.is_a?(Exwiw::QueryAst::SelectSubquery)

        # A UnionSubquery wraps several such Selects; UNION their compiled forms
        # into a single id set.
        if subquery.is_a?(Exwiw::QueryAst::UnionSubquery)
          return subquery.queries.map { |q| compile_ast(q) }.join(' UNION ')
        end

        inner_values = subquery.where_values.map { |v| escape_value(v) }
        "SELECT #{subquery.table_name}.#{subquery.select_column} " \
          "FROM #{subquery.table_name} " \
          "WHERE #{subquery.table_name}.#{subquery.where_column} IN (#{inner_values.join(', ')})"
      end

      private def escape_value(value)
        case value
        when nil
          "NULL"
        when String
          qv = escape_single_quote(value)
          "'#{qv}'"
        else
          value
        end
      end

      private def escape_single_quote(value)
        value.gsub("'", "''")
      end

      private def compile_column_name(ast, column)
        case column
        when Exwiw::QueryAst::ColumnValue::Plain
          "#{ast.from_table_name}.#{column.name}"
        when Exwiw::QueryAst::ColumnValue::RawSql
          column.value
        when Exwiw::QueryAst::ColumnValue::ReplaceWith
          parts = column.value.scan(/[^{}]+|\{[^{}]*\}/).map do |part|
            if part.start_with?('{')
              name = part[1..-2]
              "#{ast.from_table_name}.#{name}"
            else
              "'#{part}'"
            end
          end

          replaced = parts.join(" || ")
          null_preserving(ast, column, "(#{replaced})")
        else
          raise "Unreachable case: #{column.inspect}"
        end
      end

      private def connection
        @connection ||=
          begin
            require 'sqlite3'
            SQLite3::Database.new(File.expand_path(@connection_config.database_name))
          end
      end
    end
  end
end

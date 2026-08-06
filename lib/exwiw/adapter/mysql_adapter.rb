# frozen_string_literal: true

require 'open3'

module Exwiw
  module Adapter
    class MysqlAdapter < Base
      include IdentifierQuoting::Mysql
      include SqlBulkInsert

      # A lazy, streaming stand-in for the materialized rows #execute used to
      # return (`connection.query(sql).rows`). It pulls rows off the wire one at
      # a time (mysql2 single-row stream) instead of buffering the whole result
      # set, so the dump's dominant memory cost — a Ruby array as large as the
      # table — never materializes. The Runner drives it exactly like the old
      # Array: #size to skip empty tables and log the count, then a single
      # streaming pass (SqlBulkInsert#write_inserts -> each_slice).
      #
      # Mirrors PostgresqlAdapter::StreamingResult, with two MySQL specifics:
      #   - #size runs a separate `SELECT COUNT(*)` of the same query. Unlike the
      #     pg path, it does NOT wrap the SELECT in a subquery: MySQL rejects a
      #     derived table with duplicate column names, which a rails-managed
      #     `SELECT *` joined to another table produces. Instead the projection
      #     is replaced by `COUNT(*)` (compile_ast(count_only: true)) — exact
      #     because exwiw's extraction queries have no DISTINCT/GROUP BY/LIMIT,
      #     so the row count is independent of the projected columns.
      #   - the stream ties up the connection until fully drained. The Runner
      #     always drains it (write_inserts) before any further query
      #     (post_insert_sql / DELETE), and MysqlClient#stream_rows drains the
      #     remainder if iteration is abandoned, so the connection stays usable.
      class StreamingResult
        include Enumerable

        def initialize(client:, data_sql:, count_sql:)
          @client = client
          @data_sql = data_sql
          @count_sql = count_sql
        end

        def size
          @size ||= @client.query(@count_sql).rows.dig(0, 0).to_i
        end
        alias length size

        # Stream the result set row by row. Each row is an Array of String|nil
        # (mysql2 `cast: false` / stringified) — identical to what
        # `connection.query(sql).rows` produced, so the generated INSERT is
        # unchanged.
        def each(&block)
          return enum_for(:each) { size } unless block_given?

          @client.stream_rows(@data_sql, &block)
          self
        end
      end

      def build_query(table, dump_target, table_by_name)
        Exwiw::QueryAstBuilder.run(table.name, table_by_name, dump_target, @logger)
      end

      def execute(query_ast)
        data_sql = nil
        count_sql = nil
        # Count via the same FROM/JOIN/WHERE (projection replaced by COUNT(*)) so
        # the Runner can skip empty tables and log the row count without draining
        # the stream. See StreamingResult for why this is not a subquery wrap.
        with_scope_materialization do
          data_sql = commented_sql(query_ast)
          count_sql = "#{sql_query_comment(query_ast)} #{compile_ast(query_ast, count_only: true)}"
        end

        @logger.debug("  Executing SQL (streaming): \n#{data_sql}")
        StreamingResult.new(client: connection, data_sql: data_sql, count_sql: count_sql)
      end

      def explain(query_ast, verbosity: nil)
        sql = commented_sql(query_ast)

        @logger.debug("  Executing EXPLAIN: \n#{sql}")
        result = connection.query("EXPLAIN #{sql}")
        result.rows.each_with_index.flat_map do |row, i|
          ["*************************** #{i + 1}. row ***************************"] +
            result.fields.zip(row).map { |k, v| "#{k}: #{v}" }
        end.join("\n")
      end

      def dump_schema(ordered_tables, output_path)
        # Full-database schema dump: emit DDL for every table in the database,
        # not just the config-scoped tables. A table absent from the config gets
        # its schema here but no data (empty INSERT), which is the intended
        # result — the restore target then has every relation even when exwiw was
        # configured to extract only a subset. `ordered_tables` no longer selects
        # which tables are emitted; it is kept only for the log line.

        # The mysqldump binary is invoked directly (not via the mysql2/trilogy
        # driver), so point EXWIW_MYSQLDUMP at a specific binary when the one on
        # PATH is incompatible with the server — e.g. a MySQL 9.x client whose
        # mysqldump cannot load `mysql_native_password` ("plugin ... cannot be
        # loaded", exit 2) against a server still using that auth plugin.
        mysqldump_bin = ENV['EXWIW_MYSQLDUMP']
        mysqldump_bin = 'mysqldump' if mysqldump_bin.nil? || mysqldump_bin.empty?

        # MariaDB's mysqldump does not recognise the MySQL-specific
        # --set-gtid-purged flag and exits with code 7.
        gtid_flags = mariadb_mysqldump?(mysqldump_bin) ? [] : ['--set-gtid-purged=OFF']

        cmd = [
          mysqldump_bin,
          "--host=#{@connection_config.host}",
          "--port=#{@connection_config.port}",
          "--user=#{@connection_config.user}",
          '--no-data',
          '--skip-add-drop-table',
          '--skip-comments',
          '--skip-set-charset',
          '--no-tablespaces', # skip tablespace query that requires PROCESS privilege (unavailable on managed MySQL like RDS)
          *gtid_flags,
          '--compact',
          @connection_config.database_name,
        ]
        env = { 'MYSQL_PWD' => @connection_config.password.to_s }

        @logger.debug("  Running #{mysqldump_bin} for the whole database (#{@connection_config.database_name})...")
        stdout, stderr, status =
          begin
            Open3.capture3(env, *cmd)
          rescue Errno::ENOENT
            raise "Failed to run `#{mysqldump_bin}`. Ensure the mysql client is installed and on PATH, " \
                  "or set EXWIW_MYSQLDUMP to a mysqldump binary."
          end
        unless status.success?
          if stderr.include?('command not found') || stderr.empty?
            raise "Failed to run `#{mysqldump_bin}`. Ensure the mysql client is installed and on PATH, " \
                  "or set EXWIW_MYSQLDUMP to a mysqldump binary. stderr: #{stderr}"
          end
          raise "mysqldump failed (exit #{status.exitstatus}): #{stderr}"
        end

        idempotent = DdlPostprocessor.strip_definer_clauses(stdout)
        idempotent = DdlPostprocessor.add_if_not_exists_to_create_table(idempotent)

        File.open(output_path, 'w') do |file|
          file.puts("-- Auto-generated by exwiw via mysqldump. Idempotent CREATE TABLE statements for mysql.")
          file.puts("SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;")
          file.puts
          file.puts(idempotent)
          file.puts("SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;")
        end
        @logger.info("  Wrote full-database schema to #{output_path} (#{ordered_tables.size} table(s) in scope for data).")
      end

      def pre_insert_sql(_table)
        "SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;"
      end

      def post_insert_sql(_table)
        "SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;"
      end

      # The INSERT header for this adapter. MySQL backtick-quotes the table and
      # column identifiers (always, to stay byte-identical with historical
      # output). #to_bulk_insert / #write_inserts (SqlBulkInsert) append the
      # value tuples and the trailing `;`.
      private def insert_header(table)
        table_name = force_quote_table_name(table.name)
        if table.rails_managed?
          "INSERT INTO #{table_name} VALUES\n"
        else
          column_names = table.columns.map { |c| force_quote_identifier(c.name) }.join(', ')
          "INSERT INTO #{table_name} (#{column_names}) VALUES\n"
        end
      end

      def to_bulk_delete(select_query_ast, table)
        raise NotImplementedError unless select_query_ast.is_a?(Exwiw::QueryAst::Select)

        sql = "DELETE FROM #{quote_table_name(select_query_ast.from_table_name)}"

        if select_query_ast.join_clauses.empty?
          # Ignore filter option, because bulk delete is for cleaning before import,
          # so it should delete all records to avoid foreign key violation & data consistancy.
          compiled_where_conditions = select_query_ast.
            where_clauses.
            select { |where| where.is_a?(Exwiw::QueryAst::WhereClause) }.
            map do |where|
            compile_delete_where_condition(where, select_query_ast.from_table_name)
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
        sql += "\nWHERE #{qualified_name(select_query_ast.from_table_name, foreign_key)} IN (#{subquery_sql})"

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
                 scope_clauses.any? ? "#{quote_table_name(query_ast.from_table_name)}.*" : "*"
               else
                 query_ast.columns.map { |col| compile_column_name(query_ast, col) }.join(', ')
               end
        sql += " FROM #{quote_table_name(query_ast.from_table_name)}"

        query_ast.join_clauses.each do |join|
          sql += " JOIN #{quote_table_name(join.join_table_name)} ON #{qualified_name(join.base_table_name, join.foreign_key)} = #{qualified_name(join.join_table_name, join.primary_key)}"

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

      # Render a scope id-set clause as a JOIN to a materialized derived table:
      #
      #   JOIN (SELECT DISTINCT src.<proj> AS exwiw_scope_id
      #         FROM (<subquery>) AS src) AS ids
      #     ON <table>.<col> = ids.exwiw_scope_id
      #
      # The DISTINCT makes the derived table non-mergeable, so MySQL materializes
      # the id-set once and probes this table by it (PK/index lookup) — instead
      # of full-scanning this table and re-evaluating a correlated
      # `IN (… UNION …)` per row (the DEPENDENT SUBQUERY / IN-to-EXISTS fallback,
      # which a UNION subquery cannot be turned into a materialized semi-join).
      # DISTINCT also dedups, so the join never fans out: the row set is identical
      # to `<col> IN (subquery)`.
      private def compile_scope_join(from_table_name, where_clause, idx)
        subquery = where_clause.value
        ids_alias = "exwiw_scope_ids_#{idx}"
        outer_key = qualified_name(from_table_name, where_clause.column_name)

        if (scope_table = materialized_scope_table(subquery))
          return "JOIN #{quote_table_name(scope_table)} AS #{ids_alias} " \
            "ON #{outer_key} = #{ids_alias}.exwiw_scope_id"
        end

        projection = quote_identifier(subquery_projection_name(subquery))
        src_alias = "exwiw_scope_src_#{idx}"

        "JOIN (SELECT DISTINCT #{src_alias}.#{projection} AS exwiw_scope_id " \
          "FROM (#{compile_subquery(subquery)}) AS #{src_alias}) AS #{ids_alias} " \
          "ON #{outer_key} = #{ids_alias}.exwiw_scope_id"
      end

      # The same scope subquery (e.g. the target-tenant users id-set) is embedded
      # in every descendant table's extraction query, so the source DB would
      # re-evaluate it once per table — the dominant cost on large tenants.
      # During #execute, materialize each distinct id-set once into a session
      # TEMPORARY TABLE and JOIN that instead. Keyed by the compiled SELECT, so
      # nested scopes reuse already-materialized parents. #explain and
      # #describe_query compile without the flag and stay side-effect free.
      private def with_scope_materialization
        @materialize_scopes = true
        yield
      ensure
        @materialize_scopes = false
      end

      private def materialized_scope_table(subquery)
        return nil unless @materialize_scopes
        return nil if @scope_materialization_disabled

        select_sql = "SELECT DISTINCT exwiw_scope_src.#{quote_identifier(subquery_projection_name(subquery))} " \
          "AS exwiw_scope_id FROM (#{compile_subquery(subquery)}) AS exwiw_scope_src"

        @scope_id_tables ||= {}
        begin
          prepare_scope_session
          @scope_id_tables[select_sql] ||= create_scope_id_table(select_sql)
        rescue StandardError => e
          # e.g. the DB user lacks CREATE TEMPORARY TABLES; keep extracting with
          # the inline (per-query) scope subqueries instead of failing the run.
          @scope_materialization_disabled = true
          @logger.warn("Disabling scope id-set materialization (#{e.class}: #{e.message}); " \
            "falling back to inline scope subqueries.")
          nil
        end
      end

      # Read-only replicas (e.g. Aurora MySQL 3 reader instances) cannot create
      # InnoDB temporary tables: with NO_ENGINE_SUBSTITUTION in sql_mode the
      # CREATE fails outright (ERROR 3161) instead of substituting a permitted
      # engine such as MyISAM. Strip that flag once per session — it only
      # governs DDL engine fallback, not query semantics.
      private def prepare_scope_session
        return if @scope_session_prepared

        mode = connection.query("SELECT @@SESSION.sql_mode").rows.dig(0, 0).to_s
        cleaned = mode.split(',').reject { |part| part == 'NO_ENGINE_SUBSTITUTION' }.join(',')
        connection.query("SET SESSION sql_mode = '#{cleaned}'") unless cleaned == mode
        @scope_session_prepared = true
      end

      # If a step after CREATE fails, the temp table stays in the session until
      # disconnect, but it is never referenced: the name is only cached (and thus
      # only joined) after all three statements succeed, and the caller disables
      # materialization for the rest of the run.
      private def create_scope_id_table(select_sql)
        name = "exwiw_scope_id_set_#{@scope_id_tables.size}"
        connection.query("CREATE TEMPORARY TABLE #{quote_table_name(name)} AS #{select_sql}")
        # ROW_COUNT() reads the CTAS insert count in O(1); a COUNT(*) would
        # re-scan the whole id-set just for this log line.
        count = connection.query("SELECT ROW_COUNT()").rows.dig(0, 0)
        connection.query("ALTER TABLE #{quote_table_name(name)} ADD INDEX `index_exwiw_scope_id` (exwiw_scope_id)")
        @logger.info("  Materialized scope id set #{name} (#{count} ids).")
        name
      end

      # A WHERE condition for the DELETE statement.
      #
      # MySQL refuses a subquery that reads the table being deleted from
      # ("You can't specify target table 'x' for update in FROM clause"), and a
      # polymorphic multi-arm scope produces exactly that: each arm selects the
      # join table's own primary key, so the delete's `pk IN (…)` reads the
      # delete target. Wrapping the subquery in a derived table lifts the
      # restriction — MySQL materializes the derived table before the DELETE
      # runs, so the rows deleted are the ones the SELECT matched.
      #
      # Only that self-referencing shape is wrapped; every other subquery
      # (a scope id-set projected from *another* table, the ids_field probe)
      # compiles exactly as before.
      private def compile_delete_where_condition(where_clause, table_name)
        if where_clause.operator == :in_subquery && delete_target_self_reference?(where_clause.value, table_name)
          key = qualified_name(table_name, where_clause.column_name)
          return "#{key} IN (SELECT * FROM (#{compile_subquery(where_clause.value)}) AS exwiw_delete_src)"
        end

        compile_where_condition(where_clause, table_name)
      end

      private def delete_target_self_reference?(subquery, table_name)
        case subquery
        when Exwiw::QueryAst::SelectSubquery
          Exwiw::QueryAst.reads_table?(subquery.query, table_name)
        when Exwiw::QueryAst::UnionSubquery
          subquery.queries.any? { |query| Exwiw::QueryAst.reads_table?(query, table_name) }
        else
          false
        end
      end

      private def compile_where_condition(where_clause, table_name)
        # Use as it is if it's a raw query
        return where_clause if where_clause.is_a?(String)

        key = qualified_name(table_name, where_clause.column_name)

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
        "SELECT #{qualified_name(subquery.table_name, subquery.select_column)} " \
          "FROM #{quote_table_name(subquery.table_name)} " \
          "WHERE #{qualified_name(subquery.table_name, subquery.where_column)} IN (#{inner_values.join(', ')})"
      end

      # Backslash and control-character escapes, matching mysqldump. Escaping
      # newlines keeps every VALUES tuple on a single line, so a value that
      # itself contains a newline cannot break consumers that split the dump
      # into statements on a semicolon-newline boundary.
      SPECIAL_CHARACTER_ESCAPES = {
        "\\" => "\\\\",
        "\n" => "\\n",
        "\r" => "\\r",
        "\u0000" => "\\0",
        "\u001A" => "\\Z",
      }.freeze

      private def escape_value(value)
        case value
        when nil
          "NULL"
        when String
          qv = value.gsub(/[\\\r\n\u0000\u001A]/) { |char| SPECIAL_CHARACTER_ESCAPES.fetch(char) }
          qv = escape_single_quote(qv)
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
          qualified_name(ast.from_table_name, column.name)
        when Exwiw::QueryAst::ColumnValue::RawSql
          column.value
        when Exwiw::QueryAst::ColumnValue::ReplaceWith
          if Exwiw::MaskValue.scalar?(column.value)
            return null_preserving(ast, column, scalar_literal(column.value))
          end

          parts = mask_template_parts(ast, column)

          replaced = parts.join(", ")
          null_preserving(ast, column, "CONCAT(#{replaced})")
        else
          raise "Unreachable case: #{column.inspect}"
        end
      end

      private def mariadb_mysqldump?(mysqldump_bin)
        return @mariadb_mysqldump if defined?(@mariadb_mysqldump)

        @mariadb_mysqldump =
          begin
            version_output, _, status = Open3.capture3(mysqldump_bin, '--version')
            status.success? && version_output.match?(/mariadb/i)
          rescue SystemCallError
            false
          end
      end

      private def connection
        @connection ||= MysqlClient.new(@connection_config)
      end
    end
  end
end

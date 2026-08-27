# frozen_string_literal: true

module Exwiw
  module Adapter
    class PostgresqlAdapter < Base
      include IdentifierQuoting::Postgresql
      include SqlBulkInsert

      # A lazy, streaming stand-in for the materialized rows #execute used to
      # return (`connection.exec(sql).values`). It pulls rows off the wire one
      # at a time via libpq's single-row mode instead of buffering the whole
      # result set, so the dump's dominant memory cost — a Ruby array as large
      # as the table — never materializes. The Runner drives it exactly like the
      # old Array: #size to skip empty tables and log the count, then a single
      # streaming pass (SqlBulkInsert#write_inserts -> each_slice) to write the
      # INSERT.
      #
      # Mirrors MongodbAdapter::StreamingResult; two SQL-specific differences:
      #   - #size cannot be answered cheaply from the cursor, so it runs a
      #     separate `SELECT COUNT(*)` of the same query. (MongoDB uses
      #     count_documents, an index-only walk; the SQL COUNT re-runs the query
      #     plan but transfers no row data — Postgres prunes the unused
      #     projection of the wrapped subquery.) This keeps the Runner contract
      #     unchanged, so MongoDB and the other SQL adapters are untouched.
      #   - the streaming pass ties up the connection until fully drained. The
      #     Runner always drains it (write_inserts) before issuing any further
      #     query (post_insert_sql / DELETE) on the same connection, so the
      #     ordering invariant holds.
      class StreamingResult
        include Enumerable

        def initialize(connection:, data_sql:, count_sql:)
          @connection = connection
          @data_sql = data_sql
          @count_sql = count_sql
        end

        def size
          @size ||= @connection.exec(@count_sql).getvalue(0, 0).to_i
        end
        alias length size

        # Stream the result set row by row. Each row is an Array of String|nil
        # in libpq's text format — byte-identical to what `#exec(sql).values`
        # produced, so the generated INSERT is unchanged.
        def each
          return enum_for(:each) { size } unless block_given?

          @connection.send_query(@data_sql)
          @connection.set_single_row_mode
          begin
            while (result = @connection.get_result)
              begin
                result.check
                result.each_row { |row| yield row }
              ensure
                result.clear
              end
            end
          rescue StandardError
            # If iteration is abandoned mid-stream (a SQL error surfaced by
            # #check, or the consumer raised), drain any results still queued so
            # a later query on this same connection does not fail with "another
            # command is already in progress".
            drain
            raise
          end
          self
        end

        private def drain
          while (result = @connection.get_result)
            result.clear
          end
        rescue PG::Error
          # Connection already errored/clean; nothing left to drain.
        end
      end

      def build_query(table, dump_target, table_by_name)
        Exwiw::QueryAstBuilder.run(table.name, table_by_name, dump_target, @logger)
      end

      def execute(query_ast)
        data_sql = commented_sql(query_ast)
        # Count via the same query (wrapped as a subquery) so the Runner can
        # skip empty tables and log the row count without draining the stream.
        count_sql = "#{sql_query_comment(query_ast)} SELECT COUNT(*) FROM (#{compile_ast(query_ast)}) AS exwiw_count_src"

        @logger.debug("  Executing SQL (single-row stream): \n#{data_sql}")
        StreamingResult.new(connection: connection, data_sql: data_sql, count_sql: count_sql)
      end

      def explain(query_ast, verbosity: nil)
        sql = commented_sql(query_ast)

        @logger.debug("  Executing EXPLAIN: \n#{sql}")
        connection.exec("EXPLAIN #{sql}").values.map(&:first).join("\n")
      end

      # Extensions a managed PostgreSQL platform installs to run the *source*
      # instance itself, which exwiw treats as out of target and leaves out of the
      # dump entirely. Each one here satisfies both conditions:
      #
      #   1. it ships only with the managed platform, so no restore target outside
      #      that platform can create it, and
      #   2. nothing in the application's own schema or queries references it — it
      #      is operational machinery (autovacuum tuning, the in-memory columnar
      #      cache, index advice), not a feature the app builds on.
      #
      # Condition 2 is what keeps this list short. AlloyDB's application-facing
      # extensions — `google_ml_integration`, `alloydb_scann`, `alloydb_ai_nl` —
      # meet condition 1 but are called from application SQL and can be named by
      # dumped DDL (a ScaNN index is `USING scann`), so dropping their CREATE would
      # silently strand whatever refers to them. They stay in the dump, wrapped in
      # the usual warn-and-skip DO block, like `pglogical` and like a third-party
      # extension pulled in as a dependency of one listed here (`google_db_advisor`
      # requires `hypopg`, which any plain PostgreSQL can install).
      #
      # Deliberately an explicit list of names, not a `google_`/`alloydb_` prefix
      # match (which is how the old `pg_extension` query filtered, before switching
      # to a full-database pg_dump dropped that query and the filter with it): the
      # prefixes are not reserved, so a schema an application legitimately owns —
      # `google_calendar` for a Google Calendar integration — would be matched and
      # dropped together with its tables. The vendor gains extensions faster than
      # this list does; that costs a release, which is the right trade against
      # deleting an application's own objects. Its `rds_%` / `aiven_%` arms are not
      # carried over for the same reason: naming their members takes a dump to
      # confirm, and adding one here is a one-line change.
      PLATFORM_MANAGED_EXTENSIONS = %w[
        google_columnar_engine
        google_db_advisor
        google_vacuum_mgmt
      ].freeze

      def dump_schema(ordered_tables, output_path)
        require 'open3'

        # Full-database schema dump: emit DDL for every table in the database,
        # not just the config-scoped tables. A table absent from the config
        # gets its schema here but no data (empty INSERT), which is the intended
        # result — the restore target then has every relation even when exwiw
        # was configured to extract only a subset, so a later reference to an
        # unscoped table does not fail with "relation does not exist".
        # `ordered_tables` no longer selects which tables are emitted; it is kept
        # only for the log line (how many tables are in scope for data).
        cmd = [
          'pg_dump',
          "--host=#{@connection_config.host}",
          "--port=#{@connection_config.port}",
          "--username=#{@connection_config.user}",
          '--schema-only',
          '--no-owner',
          '--no-acl',
          # An extension that needs a schema of its own puts it under its own name
          # (Cloud SQL's google_vacuum_mgmt does; the AlloyDB two install into
          # public), so excluding the same names covers the schema half — including
          # any object the platform adds inside one later. The patterns are exact
          # names: pg_dump reads them psql \d-style, where `_` is literal and only
          # `*` globs. A pattern matching nothing is not an error (that needs
          # --strict-names), so these are harmless against a self-hosted server.
          *PLATFORM_MANAGED_EXTENSIONS.map { |name| "--exclude-schema=#{name}" },
          @connection_config.database_name,
        ]
        env = { 'PGPASSWORD' => @connection_config.password.to_s }

        log_excluded_platform_managed_schemas

        @logger.debug("  Running pg_dump for the whole database (#{@connection_config.database_name})...")
        stdout, stderr, status = Open3.capture3(env, *cmd)
        unless status.success?
          if stderr.include?('command not found') || stderr.empty?
            raise "Failed to run `pg_dump`. Ensure the postgresql client is installed and on PATH. stderr: #{stderr}"
          end
          raise "pg_dump failed (exit #{status.exitstatus}): #{stderr}"
        end

        # A full-database dump emits CREATE EXTENSION and CREATE TYPE ... AS ENUM
        # itself (a `--table` dump omitted both, which is why they used to be
        # prepended by hand), but pg_dump's bare forms are neither idempotent nor
        # restore-tolerant. Wrap them in place to restore the previous
        # robustness: enums swallow duplicate_object on re-restore; extensions
        # warn-and-skip feature_not_supported / invalid_schema_name so a target
        # that cannot provide the extension (e.g. pglogical's schema absent, or a
        # managed-platform extension) does not abort the restore. The COMMENT ON
        # EXTENSION that pg_dump emits alongside is likewise wrapped to swallow
        # undefined_object, so a skipped extension's trailing comment does not
        # abort the restore either.
        # Triggers are wrapped the same way. They used to be stripped instead,
        # because a `--table` dump emitted CREATE TRIGGER without the
        # CREATE FUNCTION it referenced; a whole-database dump carries both, so a
        # target can have the source's triggers instead of silently running none
        # (mysqldump and sqlite_master always emitted theirs). They do fire while
        # the `insert-*.sql` files are applied, so a load that must not fire them
        # disables them for the session, as a mysql restore already had to.
        # Platform-managed extensions are stripped first: the wrapping passes below
        # rewrite the bare CREATE/COMMENT statements this removes.
        idempotent = strip_platform_managed_extensions(stdout)
        idempotent = DdlPostprocessor.wrap_create_type_enum_in_do_block(idempotent)
        idempotent = DdlPostprocessor.wrap_create_extension_in_do_block(idempotent)
        idempotent = DdlPostprocessor.wrap_comment_on_extension_in_do_block(idempotent)
        idempotent = DdlPostprocessor.add_if_not_exists_to_create_schema(idempotent)
        idempotent = DdlPostprocessor.add_if_not_exists_to_create_sequence(idempotent)
        idempotent = DdlPostprocessor.add_if_not_exists_to_create_table(idempotent)
        idempotent = DdlPostprocessor.add_if_not_exists_to_create_index(idempotent)
        idempotent = DdlPostprocessor.wrap_add_constraint_in_do_block(idempotent)
        idempotent = DdlPostprocessor.wrap_create_trigger_in_do_block(idempotent)

        File.open(output_path, 'w') do |file|
          file.puts("-- Auto-generated by exwiw via pg_dump. Idempotent DDL for postgresql.")
          file.write(idempotent)
        end
        @logger.info("  Wrote full-database schema to #{output_path} (#{ordered_tables.size} table(s) in scope for data).")
      end

      # Drop the platform-managed extensions from a raw pg_dump, naming the ones
      # actually removed so the run records what it left out rather than silently
      # dropping it. See PLATFORM_MANAGED_EXTENSIONS.
      private def strip_platform_managed_extensions(sql)
        removed = DdlPostprocessor.extension_names(sql) & PLATFORM_MANAGED_EXTENSIONS
        unless removed.empty?
          @logger.info("  Excluded platform-managed extension(s) from the schema dump: #{removed.join(', ')}.")
        end

        DdlPostprocessor.strip_extensions(sql, PLATFORM_MANAGED_EXTENSIONS)
      end

      # Name the --exclude-schema patterns the source instance actually has, so the
      # run records the schema half of the exclusion the way
      # #strip_platform_managed_extensions records the extension half. Only exact
      # names are excluded, but nothing stops an application from owning one of
      # them, and excluding a schema takes every object inside it along — that must
      # not happen without the log saying so. See PLATFORM_MANAGED_EXTENSIONS.
      private def log_excluded_platform_managed_schemas
        # The names are bare identifiers from the constant, so they need no quoting
        # inside the array literal ANY() takes.
        result = connection.exec_params(
          'SELECT nspname FROM pg_namespace WHERE nspname = ANY($1) ORDER BY nspname',
          ["{#{PLATFORM_MANAGED_EXTENSIONS.join(',')}}"],
        )
        excluded = result.values.map(&:first)
        return if excluded.empty?

        @logger.info("  Excluded platform-managed schema(s) from the schema dump: #{excluded.join(', ')}.")
      end

      # The INSERT header for this adapter. PostgreSQL uses bare identifiers,
      # quoted only when required (reserved word / unsafe characters).
      # #to_bulk_insert / #write_inserts (SqlBulkInsert) append the value tuples
      # and the trailing `;`.
      private def insert_header(table)
        table_name = quote_table_name(table.name)
        if table.rails_managed?
          "INSERT INTO #{table_name} VALUES\n"
        else
          column_names = table.columns.map { |c| quote_identifier(c.name) }.join(', ')
          "INSERT INTO #{table_name} (#{column_names}) VALUES\n"
        end
      end

      def to_copy_from_stdin(results, table)
        header = if table.rails_managed?
                   "COPY #{quote_table_name(table.name)} FROM stdin;"
                 else
                   column_names = table.columns.map { |c| quote_identifier(c.name) }.join(', ')
                   "COPY #{quote_table_name(table.name)} (#{column_names}) FROM stdin;"
                 end
        lines = [header]
        results.each do |row|
          lines << row.map { |v| escape_copy_value(v) }.join("\t")
        end
        lines << '\\.'
        lines.join("\n")
      end

      # Suppress trigger and foreign-key enforcement while the table's rows are
      # loaded. insert-000-schema.sql carries the source's triggers now, so an
      # unguarded load would fire every one of them per inserted row — with the
      # rows already carrying the values those triggers produced on the source,
      # and in an order that is only guaranteed to satisfy FKs once every
      # insert-*.sql has been applied. `replica` mode turns off both user and
      # system (RI) triggers, matching what MysqlAdapter does with
      # FOREIGN_KEY_CHECKS.
      #
      # Setting the parameter needs superuser (or a grant on it), which a
      # restore role may not have; the load itself is still valid without it,
      # so a failure is downgraded to a WARNING rather than aborting the file.
      #
      # Unlike MysqlAdapter — and unlike `pg_dump --disable-triggers`, which
      # pairs each table's DISABLE TRIGGER ALL with an ENABLE — no counterpart
      # reset is emitted, so the file is NOT self-contained in session state:
      # sourcing insert-*.sql into a session that goes on to do other work
      # leaves that session in replica mode. `is_local = false` still bounds it
      # to the connection, and every file re-arms the setting itself, so
      # concatenating the files works either way — the reset would only buy
      # tidiness, at the cost of emitting it unconditionally (post_insert_sql
      # returns nil for a table with no serial PK) inside a second exception
      # handler (a bare reset re-raises insufficient_privilege on the
      # unprivileged path and would abort the file).
      def pre_insert_sql(_table)
        <<~SQL.chomp
          DO $exwiw$ BEGIN
            PERFORM set_config('session_replication_role', 'replica', false);
          EXCEPTION WHEN insufficient_privilege THEN
            RAISE WARNING 'exwiw: could not disable triggers for the load (%): %', SQLSTATE, SQLERRM;
          END $exwiw$;
        SQL
      end

      # Transcribe the FROM-side sequence cursor backing `table.primary_key`
      # onto the import target. Without this, importing into a clean DB leaves
      # the sequence at 1 while the inserted rows occupy higher IDs, so the
      # next default-PK INSERT collides. We query FROM's `last_value` /
      # `is_called` directly (matching what pg_dump emits) rather than using
      # MAX(pk), so a subsetted dump still preserves the source's "next id".
      # Returns nil for non-auto-increment PKs (pg_get_serial_sequence -> NULL).
      #
      # Scope: ONLY the sequence attached to the primary key is synced. If a
      # table has additional auto-increment columns (e.g. a non-PK SERIAL),
      # those sequences are NOT transcribed and a subsequent default-value
      # INSERT on them can collide. Rails-managed schemas don't hit this
      # because only `id` is auto-increment, but bare PostgreSQL schemas may.
      def post_insert_sql(table)
        pk = table.primary_key
        return nil if pk.nil? || pk.empty?

        # pg_get_serial_sequence parses its first argument with identifier
        # rules (unquoted parts are case-folded), so pass the same
        # conditionally quoted form the extraction queries use — a bare
        # 'Order' would fold to the nonexistent relation 'order' even though
        # the quoted extraction just succeeded. The second argument is taken
        # literally (no folding), so the raw column name is correct.
        seq_name = connection
          .exec_params("SELECT pg_get_serial_sequence($1, $2)", [quote_table_name(table.name), pk])
          .values.dig(0, 0)
        return nil if seq_name.nil?

        last_value, is_called = connection
          .exec("SELECT last_value, is_called FROM #{seq_name}")
          .values.first
        is_called_sql = (is_called == 't' || is_called == true) ? 'true' : 'false'

        "SELECT pg_catalog.setval('#{escape_single_quote(seq_name)}', #{last_value}, #{is_called_sql});"
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
        outer_table = select_query_ast.from_table_name
        inner_table = first_join.join_table_name
        inner_column = first_join.primary_key
        cast_to = types_need_cast?(
          column_pg_type(outer_table, foreign_key),
          column_pg_type(inner_table, inner_column)
        ) ? 'text' : nil
        subquery_sql = compile_ast(subquery_ast, select_cast_to: cast_to)
        outer_expr = qualified_name(outer_table, foreign_key)
        outer_expr = "#{outer_expr}::text" if cast_to
        sql += "\nWHERE #{outer_expr} IN (#{subquery_sql})"

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

      def compile_ast(query_ast, select_cast_to: nil)
        raise NotImplementedError unless query_ast.is_a?(Exwiw::QueryAst::Select)

        # Lift scope id-set clauses (reverse_scope UNION / forward cascade /
        # single referenced_by) out of `WHERE <col> IN (subquery)` and into a
        # JOIN against a materialized derived table. See #compile_scope_join.
        scope_clauses, plain_where_clauses = partition_scope_clauses(query_ast.where_clauses)

        sql = "SELECT "
        sql += if query_ast.select_all
                 # A lifted scope JOIN brings a derived table into FROM, so a bare
                 # `*` would also project its column. Qualify to this table's own.
                 scope_clauses.any? ? "#{quote_table_name(query_ast.from_table_name)}.*" : "*"
               else
                 cols = query_ast.columns.map { |col| compile_column_name(query_ast, col) }
                 cols = cols.map { |c| "#{c}::#{select_cast_to}" } if select_cast_to
                 cols.join(', ')
               end
        sql += " FROM #{quote_table_name(query_ast.from_table_name)}"

        query_ast.join_clauses.each do |join|
          fk_expr = qualified_name(join.base_table_name, join.foreign_key)
          pk_expr = qualified_name(join.join_table_name, join.primary_key)
          if types_need_cast?(
            column_pg_type(join.base_table_name, join.foreign_key),
            column_pg_type(join.join_table_name, join.primary_key)
          )
            fk_expr = "#{fk_expr}::text"
            pk_expr = "#{pk_expr}::text"
          end
          sql += " JOIN #{quote_table_name(join.join_table_name)} ON #{fk_expr} = #{pk_expr}"

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
      #
      # Type reconciliation mirrors the old IN form: when the outer column and
      # the projected id clash (e.g. uuid vs varchar), #compile_subquery already
      # casts every arm to text, so the derived `exwiw_scope_id` is text and the
      # outer key is cast to match.
      private def compile_scope_join(from_table_name, where_clause, idx)
        subquery = where_clause.value
        projection = quote_identifier(subquery_projection_name(subquery))
        src_alias = "exwiw_scope_src_#{idx}"
        ids_alias = "exwiw_scope_ids_#{idx}"

        inner_sql = compile_subquery(subquery, outer_table: from_table_name, outer_column: where_clause.column_name)
        cast_to = subquery_cast_to(subquery, from_table_name, where_clause.column_name)
        outer_key = qualified_name(from_table_name, where_clause.column_name)
        outer_key = "#{outer_key}::#{cast_to}" if cast_to

        "JOIN (SELECT DISTINCT #{src_alias}.#{projection} AS exwiw_scope_id " \
          "FROM (#{inner_sql}) AS #{src_alias}) AS #{ids_alias} " \
          "ON #{outer_key} = #{ids_alias}.exwiw_scope_id"
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
          subquery_sql = compile_subquery(where_clause.value, outer_table: table_name, outer_column: where_clause.column_name)
          cast_to = subquery_cast_to(where_clause.value, table_name, where_clause.column_name)
          outer_key = cast_to ? "#{key}::#{cast_to}" : key
          "#{outer_key} IN (#{subquery_sql})"
        elsif where_clause.operator == :not_null
          "#{key} IS NOT NULL"
        else
          raise "Unsupported operator: #{where_clause.operator}"
        end
      end

      private def compile_subquery(subquery, outer_table: nil, outer_column: nil)
        cast_to = subquery_cast_to(subquery, outer_table, outer_column)

        if subquery.is_a?(Exwiw::QueryAst::SelectSubquery)
          return compile_ast(subquery.query, select_cast_to: cast_to)
        end

        # A UnionSubquery wraps several projected Selects; UNION their compiled
        # forms. cast_to is the union-wide decision (see union_cast_to): when any
        # arm's column type would clash with the outer column or another arm,
        # every arm's projected column and the outer key are cast to text so the
        # UNION and the enclosing IN comparison resolve to one type.
        if subquery.is_a?(Exwiw::QueryAst::UnionSubquery)
          return subquery.queries.map { |q| compile_ast(q, select_cast_to: cast_to) }.join(' UNION ')
        end

        inner_values = subquery.where_values.map { |v| escape_value(v) }
        select_expr = qualified_name(subquery.table_name, subquery.select_column)
        select_expr = "#{select_expr}::#{cast_to}" if cast_to
        "SELECT #{select_expr} " \
          "FROM #{quote_table_name(subquery.table_name)} " \
          "WHERE #{qualified_name(subquery.table_name, subquery.where_column)} IN (#{inner_values.join(', ')})"
      end

      private def subquery_select_target(subquery)
        case subquery
        when Exwiw::QueryAst::SelectSubquery
          q = subquery.query
          col = q.columns.first
          col ? [q.from_table_name, col.name] : [nil, nil]
        when Exwiw::QueryAst::Subquery
          [subquery.table_name, subquery.select_column]
        else
          [nil, nil]
        end
      end

      private def subquery_cast_to(subquery, outer_table, outer_column)
        return nil if outer_table.nil? || outer_column.nil?

        # A UNION's arms (and the enclosing IN comparison) must all resolve to
        # one type, so the cast decision must weigh every arm — not just one, as
        # a flat Subquery would.
        return union_cast_to(subquery, outer_table, outer_column) if subquery.is_a?(Exwiw::QueryAst::UnionSubquery)

        inner_table, inner_column = subquery_select_target(subquery)
        return nil if inner_table.nil?

        outer_type = column_pg_type(outer_table, outer_column)
        inner_type = column_pg_type(inner_table, inner_column)
        types_need_cast?(outer_type, inner_type) ? 'text' : nil
      end

      # Postgres rejects a UNION (or an `IN`) that mixes incompatible types
      # (e.g. uuid and varchar). Examining only the first arm is not enough: a
      # heterogeneous later arm would go uncast and break at execution. So
      # consider the outer column together with every arm's projected column and,
      # if ANY pair needs reconciliation, cast them all to text.
      private def union_cast_to(union, outer_table, outer_column)
        types = [column_pg_type(outer_table, outer_column)]
        union.queries.each do |q|
          col = q.columns.first
          types << column_pg_type(q.from_table_name, col.name) if col
        end
        types.compact!

        needs_cast = types.combination(2).any? { |a, b| types_need_cast?(a, b) }
        needs_cast ? 'text' : nil
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

      private def escape_copy_value(value)
        case value
        when nil
          "\\N"
        when String
          value
            .gsub('\\') { '\\\\' }
            .gsub("\t", '\t')
            .gsub("\n", '\n')
            .gsub("\r", '\r')
        else
          value.to_s
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

      private def column_pg_type(table_name, column_name)
        @column_type_cache ||= {}
        cache_key = [table_name, column_name]
        return @column_type_cache[cache_key] if @column_type_cache.key?(cache_key)

        sql = <<~SQL
          SELECT t.typname
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_type t  ON t.oid = a.atttypid
          WHERE c.relname = $1
            AND a.attname = $2
            AND a.attnum > 0
            AND NOT a.attisdropped
          LIMIT 1
        SQL

        result = connection.exec_params(sql, [table_name, column_name])
        @column_type_cache[cache_key] = result.ntuples > 0 ? result.getvalue(0, 0) : nil
      end

      private def types_need_cast?(type_a, type_b)
        return false if type_a.nil? || type_b.nil?
        return false if type_a == type_b

        string_types = %w[varchar text bpchar name].freeze
        (type_a == 'uuid' && string_types.include?(type_b)) ||
          (type_b == 'uuid' && string_types.include?(type_a))
      end

      private def connection
        @connection ||=
          begin
            require 'pg'
            PG.connect(
              host: @connection_config.host,
              port: @connection_config.port,
              user: @connection_config.user,
              password: @connection_config.password,
              dbname: @connection_config.database_name
            )
          end
      end
    end
  end
end

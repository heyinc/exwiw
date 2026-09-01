# frozen_string_literal: true

require 'tempfile'

module Exwiw
  module Adapter
    RSpec.describe PostgresqlAdapter do
      let(:adapter_name) { 'postgresql' }
      let(:connection_config) do
        ConnectionConfig.new(
          adapter: adapter_name,
          database_name: 'exwiw_test',
          host: '127.0.0.1',
          port: 5432,
          user: 'postgres',
          password: 'test_password',
        )
      end
      let(:logger) { Logger.new(nil) }
      let(:adapter) { described_class.new(connection_config, logger) }

      describe "#dump_schema" do
        let(:schema_path) { Tempfile.new(['postgresql_schema', '.sql']).path }

        it "writes CREATE TABLE IF NOT EXISTS and wraps ADD CONSTRAINT in DO block" do
          # Full-database dump: the passed tables no longer scope the output, so
          # pass a subset and assert the whole database's DDL is emitted.
          tables = [shops_table(adapter_name), users_table(adapter_name)]
          begin
            adapter.dump_schema(tables, schema_path)
          rescue RuntimeError => e
            # pg_dump enforces a strict server/client major-version match.
            # Skip rather than fail when the local pg_dump is older than the test DB.
            skip "pg_dump server/client version mismatch: #{e.message}" if e.message.include?('server version')
            raise
          end

          sql = File.read(schema_path)
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS public\.shops/i).or(match(/CREATE TABLE IF NOT EXISTS shops/i))
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS public\.users/i).or(match(/CREATE TABLE IF NOT EXISTS users/i))
          # Tables NOT in the passed subset are still emitted (whole-database dump).
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS public\.products/i).or(match(/CREATE TABLE IF NOT EXISTS products/i))
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS public\.reviews/i).or(match(/CREATE TABLE IF NOT EXISTS reviews/i))
          # If pg_dump emits any ADD CONSTRAINT lines, they must be wrapped in DO block
          if sql =~ /ALTER TABLE/i
            expect(sql).to include('DO $exwiw$')
            expect(sql).to include('EXCEPTION WHEN duplicate_object')
          end
          # A whole-database dump emits CREATE EXTENSION itself; the post-processor
          # wraps it best-effort: feature_not_supported (binaries absent),
          # invalid_schema_name (required schema absent) and internal_error (a
          # preload-required extension such as pglogical raising "not in
          # shared_preload_libraries") are skipped with a WARNING so a restore
          # target that cannot create the extension is not fatal; but a privilege
          # error must still abort, so insufficient_privilege is NOT caught.
          expect(sql).to match(/DO \$\$ BEGIN CREATE EXTENSION IF NOT EXISTS btree_gist\b/)
          expect(sql).to match(/EXCEPTION WHEN feature_not_supported OR invalid_schema_name OR internal_error THEN RAISE WARNING '[^']*btree_gist[^']*', SQLSTATE, SQLERRM; END \$\$;/)
          expect(sql).not_to include('insufficient_privilege')
          ext_pos = sql.index("DO $$ BEGIN CREATE EXTENSION")
          table_pos = sql.index("CREATE TABLE")
          expect(ext_pos).to be < table_pos
          expect(ext_pos).to be < sql.index("CREATE TYPE")
          # The enum type is wrapped in an idempotent DO block (pg_dump's bare
          # CREATE TYPE is not idempotent on re-restore).
          expect(sql).to include('CREATE TYPE')
          expect(sql).to include("AS ENUM (")
          expect(sql).to match(/DO \$exwiw\$ BEGIN\s+CREATE TYPE .*AS ENUM/m)
          expect(sql).to include("'admin'")
          expect(sql).to include("'member'")
          enum_match = sql.match(/AS ENUM \(([^)]+)\)/m)
          labels = enum_match[1].scan(/'([^']*(?:''[^']*)*)'/).flatten
          expect(labels).to eq(labels.uniq), "enum labels should not be duplicated: #{labels}"
          # The source's triggers are kept, wrapped so re-applying the schema does
          # not fail on duplicate_object; pg_dump's header is left as written.
          expect(sql).to match(
            /DO \$exwiw\$ BEGIN\s+CREATE TRIGGER suppress_redundant_user_updates\b.*?EXCEPTION WHEN duplicate_object/m,
          )
          expect(sql).to include('Type: TRIGGER')
        end

        # pg_dump is stubbed so the shape under test does not depend on the test
        # DB owning a function of its own.
        context "when the source instance carries triggers and trigger functions" do
          let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
          let(:dump_output) do
            <<~SQL
              --
              -- Name: install_trigger(text); Type: FUNCTION; Schema: public; Owner: -
              --

              CREATE FUNCTION public.install_trigger(t text) RETURNS void
                  LANGUAGE plpgsql
                  AS $$
              BEGIN
              CREATE TRIGGER never_wrap BEFORE UPDATE ON shops FOR EACH ROW EXECUTE FUNCTION set_timestamp();
              END $$;


              --
              -- Name: set_timestamp(); Type: FUNCTION; Schema: public; Owner: -
              --

              CREATE FUNCTION public.set_timestamp() RETURNS trigger
                  LANGUAGE plpgsql
                  AS $$
              BEGIN NEW.updated_at = now(); RETURN NEW; END $$;


              CREATE TABLE public.shops (
                  id bigint NOT NULL
              );


              --
              -- Name: shops set_timestamp; Type: TRIGGER; Schema: public; Owner: -
              --

              CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.shops FOR EACH ROW EXECUTE FUNCTION public.set_timestamp();
            SQL
          end

          before do
            allow(Open3).to receive(:capture3)
              .with(hash_including('PGPASSWORD'), 'pg_dump', any_args) { [dump_output, '', success_status] }
          end

          # A whole-database dump carries the functions its triggers reference, so
          # both halves restore. (A `--table` dump emitted the trigger alone, which
          # is why triggers used to be dropped.)
          it "keeps the trigger next to the function it references" do
            adapter.dump_schema([shops_table(adapter_name)], schema_path)

            sql = File.read(schema_path)
            expect(sql).to include('CREATE FUNCTION public.set_timestamp() RETURNS trigger')
            expect(sql).to match(
              /DO \$exwiw\$ BEGIN\s+CREATE TRIGGER set_timestamp BEFORE UPDATE ON public\.shops\b.*?EXCEPTION WHEN duplicate_object/m,
            )
          end

          # Wrapping a statement inside a dollar-quoted body would change what the
          # function does.
          it "leaves a CREATE TRIGGER inside a function body alone" do
            adapter.dump_schema([shops_table(adapter_name)], schema_path)

            expect(File.read(schema_path)).to include(
              "BEGIN\nCREATE TRIGGER never_wrap BEFORE UPDATE ON shops FOR EACH ROW EXECUTE FUNCTION set_timestamp();\nEND $$;",
            )
          end
        end

        # A managed platform (Cloud SQL / AlloyDB) installs extensions of its own
        # into the source instance. They are out of target: no application data,
        # and no restore target outside that platform can create them. pg_dump is
        # stubbed here so the assertions do not depend on the test server having
        # them — the shape mirrors what real Cloud SQL / AlloyDB dumps contain.
        context "when the source instance carries platform-managed extensions" do
          let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
          let(:dump_output) do
            # No `CREATE SCHEMA google_vacuum_mgmt`: the vendor schemas are dropped
            # by the --exclude-schema flags (asserted separately below), so a real
            # dump taken with them never contains one. What survives pg_dump's own
            # filtering is the extension statements, which are not schema-qualified.
            <<~SQL
              --
              -- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
              --

              CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


              --
              -- Name: google_vacuum_mgmt; Type: EXTENSION; Schema: -; Owner: -
              --

              CREATE EXTENSION IF NOT EXISTS google_vacuum_mgmt WITH SCHEMA google_vacuum_mgmt;


              --
              -- Name: EXTENSION google_vacuum_mgmt; Type: COMMENT; Schema: -; Owner: -
              --

              COMMENT ON EXTENSION google_vacuum_mgmt IS 'extension for assistive operational tooling';


              --
              -- Name: google_db_advisor; Type: EXTENSION; Schema: -; Owner: -
              --

              CREATE EXTENSION IF NOT EXISTS google_db_advisor WITH SCHEMA public;


              --
              -- Name: hypopg; Type: EXTENSION; Schema: -; Owner: -
              --

              CREATE EXTENSION IF NOT EXISTS hypopg WITH SCHEMA public;


              --
              -- Name: alloydb_scann; Type: EXTENSION; Schema: -; Owner: -
              --

              CREATE EXTENSION IF NOT EXISTS alloydb_scann WITH SCHEMA public;


              CREATE TABLE public.shops (
                  id bigint NOT NULL
              );
            SQL
          end

          before do
            allow(Open3).to receive(:capture3)
              .with(hash_including('PGPASSWORD'), 'pg_dump', any_args) do |_env, *cmd|
                @captured_cmd = cmd
                [dump_output, '', success_status]
              end
          end

          it "asks pg_dump to skip the vendor schemas, by exact name" do
            adapter.dump_schema([shops_table(adapter_name)], schema_path)

            expect(@captured_cmd).to include(
              '--exclude-schema=google_columnar_engine',
              '--exclude-schema=google_db_advisor',
              '--exclude-schema=google_vacuum_mgmt',
            )
            # A prefix pattern would take an application's own `google_*` schema
            # (and its tables) with it, so none is passed.
            expect(@captured_cmd.grep(/--exclude-schema=.*\*/)).to be_empty
          end

          it "strips the vendor extensions, keeping the application's own" do
            adapter.dump_schema([shops_table(adapter_name)], schema_path)

            sql = File.read(schema_path)
            expect(sql).not_to include('google_vacuum_mgmt')
            expect(sql).not_to include('google_db_advisor')
            expect(sql).to include('CREATE EXTENSION IF NOT EXISTS btree_gist')
            expect(sql).to include('CREATE TABLE IF NOT EXISTS public.shops')
          end

          # hypopg is a plain open-source extension that AlloyDB's google_db_advisor
          # depends on; it is installable on the restore target, so it stays (wrapped
          # in the usual warn-and-skip block) even though its dependent is stripped.
          it "keeps a third-party dependency of a stripped extension" do
            adapter.dump_schema([shops_table(adapter_name)], schema_path)

            expect(File.read(schema_path)).to include('DO $$ BEGIN CREATE EXTENSION IF NOT EXISTS hypopg')
          end

          # alloydb_scann is AlloyDB-only too, but application-facing: a dumped index
          # can be `USING scann`, so removing its CREATE would strand that DDL. It
          # keeps the warn-and-skip treatment instead of being stripped.
          it "keeps an application-facing platform extension" do
            adapter.dump_schema([shops_table(adapter_name)], schema_path)

            expect(File.read(schema_path)).to include('DO $$ BEGIN CREATE EXTENSION IF NOT EXISTS alloydb_scann')
          end

          it "reports which extensions it left out" do
            logger = instance_double(Logger, debug: nil, info: nil)
            described_class.new(connection_config, logger).dump_schema([shops_table(adapter_name)], schema_path)

            expect(logger).to have_received(:info)
              .with(/Excluded platform-managed extension\(s\).*google_vacuum_mgmt, google_db_advisor/)
          end

          # --exclude-schema takes every object inside the schema with it, and an
          # application is free to own a schema whose name collides exactly with a
          # platform one, so the run must name the schemas it actually dropped.
          it "reports which schemas it left out" do
            logger = instance_double(Logger, debug: nil, info: nil)
            connection = adapter.send(:connection)
            connection.exec_params('CREATE SCHEMA IF NOT EXISTS google_vacuum_mgmt', [])

            begin
              described_class.new(connection_config, logger).dump_schema([shops_table(adapter_name)], schema_path)
            ensure
              connection.exec_params('DROP SCHEMA IF EXISTS google_vacuum_mgmt', [])
            end

            expect(logger).to have_received(:info)
              .with(/Excluded platform-managed schema\(s\).*google_vacuum_mgmt/)
          end

          it "says nothing about schemas the source instance does not have" do
            logger = instance_double(Logger, debug: nil, info: nil)
            described_class.new(connection_config, logger).dump_schema([shops_table(adapter_name)], schema_path)

            expect(logger).not_to have_received(:info).with(/platform-managed schema/)
          end
        end
      end

      describe "#compile_ast" do
        context "simple select query" do
          let(:sql) { adapter.compile_ast(build_select_shops_ast) }

          it "builds sql" do
            expect(sql).to eq("SELECT shops.id, shops.name, shops.updated_at, shops.created_at FROM shops WHERE shops.id = 1")
          end
        end

        context "select query with masking" do
          let(:sql) { adapter.compile_ast(build_select_users_ast) }

          it "builds sql" do
            expect(sql).to eq("SELECT users.id, CONCAT('masked', users.id), CASE WHEN users.email IS NOT NULL THEN CONCAT('masked', users.id, '@example.com') ELSE NULL END, users.shop_id, users.updated_at, users.created_at, users.role FROM users WHERE users.shop_id = 1")
          end
        end

        context "select query with filter" do
          let(:sql) { adapter.compile_ast(build_select_users_ast("users.id > 1")) }

          it "builds sql" do
            expect(sql).to eq("SELECT users.id, CONCAT('masked', users.id), CASE WHEN users.email IS NOT NULL THEN CONCAT('masked', users.id, '@example.com') ELSE NULL END, users.shop_id, users.updated_at, users.created_at, users.role FROM users WHERE users.shop_id = 1 AND users.id > 1")
          end
        end

        context "masking template referencing another column" do
          let(:sql) { adapter.compile_ast(build_select_masked_reference_ast) }

          it "guards on the masked column itself, not the referenced column" do
            expect(sql).to eq("SELECT accounts.id, CASE WHEN accounts.nickname IS NOT NULL THEN CONCAT('user-', accounts.email) ELSE NULL END, accounts.email FROM accounts")
          end
        end

        context "select query with one join" do
          let(:sql) { adapter.compile_ast(build_order_items_ast) }

          it "builds sql" do
            expect(sql).to eq(
              "SELECT order_items.id, order_items.quantity, order_items.order_id, order_items.product_id, order_items.updated_at, order_items.created_at FROM order_items JOIN orders ON order_items.order_id = orders.id AND orders.shop_id = 1"
            )
          end
        end

        context "select query with one join, one filter" do
          let(:sql) { adapter.compile_ast(build_order_items_ast("order_items.id > 1", nil)) }

          it "builds sql" do
            expect(sql).to eq(
              "SELECT order_items.id, order_items.quantity, order_items.order_id, order_items.product_id, order_items.updated_at, order_items.created_at FROM order_items JOIN orders ON order_items.order_id = orders.id AND orders.shop_id = 1 WHERE order_items.id > 1"
            )
          end
        end

        context "select query with filter on join" do
          let(:sql) { adapter.compile_ast(build_order_items_ast(nil,  "orders.id > 1")) }

          it "builds sql" do
            expect(sql).to eq(
              "SELECT order_items.id, order_items.quantity, order_items.order_id, order_items.product_id, order_items.updated_at, order_items.created_at FROM order_items JOIN orders ON order_items.order_id = orders.id AND orders.shop_id = 1 AND orders.id > 1"
            )
          end
        end

        context "select query with filter on join and filter on where" do
          let(:sql) { adapter.compile_ast(build_order_items_ast("order_items.id > 3",  "orders.id > 1")) }

          it "builds sql" do
            expect(sql).to eq(
              "SELECT order_items.id, order_items.quantity, order_items.order_id, order_items.product_id, order_items.updated_at, order_items.created_at FROM order_items JOIN orders ON order_items.order_id = orders.id AND orders.shop_id = 1 AND orders.id > 1 WHERE order_items.id > 3"
            )
          end
        end

        context "select query with two joins" do
          let(:sql) { adapter.compile_ast(build_transactions_two_join_ast) }

          it "uses each join's base table on the left side of ON" do
            expect(sql).to eq(
              "SELECT transactions.id, transactions.type, transactions.amount, transactions.order_id, transactions.updated_at, transactions.created_at FROM transactions JOIN orders ON transactions.order_id = orders.id JOIN shops ON orders.shop_id = shops.id AND shops.id = 1"
            )
          end
        end
      end

      # The reverse_scope id-set is emitted as a JOIN to a materialized
      # (SELECT DISTINCT) derived table; run against the real seed DB to prove
      # it returns the same rows as the pre-fix `<col> IN (subquery)` form.
      describe "scope id-set materialization (derived-table JOIN)" do
        it "returns the same users as the equivalent IN-subquery (result-set equivalence)" do
          ast = build_users_reverse_scope_over_seed_ast
          new_ids = adapter.execute(ast).to_a.map { |row| row.first.to_s }.sort
          old_ids = adapter.send(:connection).exec(users_reverse_scope_over_seed_in_sql).values.map { |row| row.first.to_s }.sort

          expect(new_ids).not_to be_empty
          expect(new_ids).to eq(old_ids)
        end
      end

      describe "#execute" do
        context "simple select query" do
          # #execute now returns a streaming Enumerable (single-row mode), so
          # drain it with #to_a to compare against the expected rows.
          let(:results) { adapter.execute(build_select_shops_ast).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "Shop 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with masking" do
          let(:results) { adapter.execute(build_select_users_ast).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "masked1", "masked1@example.com", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00", nil],
              ["2", "masked2", "masked2@example.com", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00", nil],
            ])
          end
        end

        context "select query with filter" do
          let(:results) { adapter.execute(build_select_users_ast("users.id > 1")).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["2", "masked2", "masked2@example.com", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00", nil],
            ])
          end
        end

        context "select query with one join" do
          let(:results) { adapter.execute(build_order_items_ast).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "1", "1", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["2", "1", "2", "2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["3", "1", "3", "3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["4", "1", "4", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["5", "1", "5", "2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["6", "1", "6", "3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with one join, one filter" do
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", nil)).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["2", "1", "2", "2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["3", "1", "3", "3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["4", "1", "4", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["5", "1", "5", "2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["6", "1", "6", "3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with filter on join" do
          let(:results) { adapter.execute(build_order_items_ast(nil, "orders.id < 6")).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "1", "1", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["2", "1", "2", "2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["3", "1", "3", "3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["4", "1", "4", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["5", "1", "5", "2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with filter on join and filter on where" do
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", "orders.id < 6")).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["2", "1", "2", "2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["3", "1", "3", "3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["4", "1", "4", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["5", "1", "5", "2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end
      end

      describe "#explain" do
        it "returns EXPLAIN output for a simple select" do
          output = adapter.explain(build_select_shops_ast)
          expect(output).to be_a(String)
          expect(output).not_to be_empty
          # postgres EXPLAIN includes scan-node descriptions
          expect(output).to match(/Scan|shops/i)
        end
      end

      describe "#to_bulk_insert" do
        let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

        context "simple select query" do
          let(:results) do
            [
              ["1", "Shop 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["2", "Shop 2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["3", "Shop 3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ]
          end

          it "returns correct bulk insert sql" do
            expect(bulk_insert_sql.strip).to eq(<<~SQL.strip)
              INSERT INTO shops (id, name, updated_at, created_at) VALUES
              ('1', 'Shop 1', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
              ('2', 'Shop 2', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
              ('3', 'Shop 3', '2025-01-01 00:00:00', '2025-01-01 00:00:00');
            SQL
          end
        end

        context "has single quote" do
          let(:results) do
            [
              ["1", "Shop' 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["2", "Shop 2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["3", "Shop 3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ]
          end

          let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

          it "returns correct bulk insert sql" do
            expect(bulk_insert_sql.strip).to eq(<<~SQL.strip)
              INSERT INTO shops (id, name, updated_at, created_at) VALUES
              ('1', 'Shop'' 1', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
              ('2', 'Shop 2', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
              ('3', 'Shop 3', '2025-01-01 00:00:00', '2025-01-01 00:00:00');
            SQL
          end
        end
      end

      describe "#to_copy_from_stdin" do
        context "simple rows" do
          let(:results) do
            [
              ["1", "Shop 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["2", "Shop 2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ]
          end
          let(:copy_sql) { adapter.to_copy_from_stdin(results, shops_table(adapter_name)) }

          it "returns correct COPY FROM stdin block" do
            expect(copy_sql).to eq(
              "COPY shops (id, name, updated_at, created_at) FROM stdin;\n" \
              "1\tShop 1\t2025-01-01 00:00:00\t2025-01-01 00:00:00\n" \
              "2\tShop 2\t2025-01-01 00:00:00\t2025-01-01 00:00:00\n" \
              "\\."
            )
          end
        end

        context "with NULL values" do
          let(:results) do
            [["1", nil, "2025-01-01 00:00:00", "2025-01-01 00:00:00"]]
          end
          let(:copy_sql) { adapter.to_copy_from_stdin(results, shops_table(adapter_name)) }

          it "escapes NULL as \\N" do
            lines = copy_sql.split("\n")
            expect(lines[1]).to eq("1\t\\N\t2025-01-01 00:00:00\t2025-01-01 00:00:00")
          end
        end

        context "with special characters" do
          let(:results) do
            [
              ["1", "Shop\twith\ttabs", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["2", "Shop\\with\\backslash", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              ["3", "Shop\nwith\nnewlines", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ]
          end
          let(:copy_sql) { adapter.to_copy_from_stdin(results, shops_table(adapter_name)) }

          it "escapes tabs, backslashes, and newlines" do
            lines = copy_sql.split("\n")
            expect(lines[1]).to include("Shop\\twith\\ttabs")
            expect(lines[2]).to include("Shop\\\\with\\\\backslash")
            expect(lines[3]).to include("Shop\\nwith\\nnewlines")
          end
        end
      end

      describe "#pre_insert_sql" do
        let(:pre_insert) { adapter.pre_insert_sql(shops_table(adapter_name)) }

        it "switches the session into replica mode" do
          expect(pre_insert).to include("set_config('session_replication_role', 'replica', false)")
        end

        it "downgrades a missing privilege to a WARNING instead of aborting the file" do
          expect(pre_insert).to include("EXCEPTION WHEN insufficient_privilege")
          expect(pre_insert).to include("RAISE WARNING")
        end

        # The temp table/trigger and the replica-mode setting both live on this
        # adapter's connection only, so the seed database is untouched.
        describe "against a live database" do
          let(:connection) { adapter.send(:connection) }

          before do
            connection.exec(<<~SQL)
              CREATE TEMP TABLE trigger_probe (id int PRIMARY KEY, touched boolean NOT NULL DEFAULT false);
              CREATE FUNCTION pg_temp.mark_touched() RETURNS trigger LANGUAGE plpgsql AS $probe$
                BEGIN NEW.touched := true; RETURN NEW; END;
              $probe$;
              CREATE TRIGGER mark_touched BEFORE INSERT ON trigger_probe
                FOR EACH ROW EXECUTE FUNCTION pg_temp.mark_touched();
            SQL
          end

          after do
            connection.exec("SELECT set_config('session_replication_role', 'origin', false)")
          end

          it "runs, and keeps the table's triggers from firing during the load" do
            connection.exec(pre_insert)
            connection.exec("INSERT INTO trigger_probe (id) VALUES (1)")

            expect(connection.exec("SELECT touched FROM trigger_probe").values).to eq([["f"]])
            expect(connection.exec("SHOW session_replication_role").values).to eq([["replica"]])
          end
        end
      end

      describe "uuid/varchar type cast" do
        before do
          # Default: all columns are int8 (no cast needed)
          allow(adapter).to receive(:column_pg_type).and_return('int8')
        end

        context "compile_ast JOIN with uuid/varchar mismatch" do
          it "casts both sides to ::text" do
            allow(adapter).to receive(:column_pg_type).with("order_items", "order_id").and_return('varchar')
            allow(adapter).to receive(:column_pg_type).with("orders", "id").and_return('uuid')

            sql = adapter.compile_ast(build_order_items_ast)
            expect(sql).to include("ON order_items.order_id::text = orders.id::text")
          end
        end

        context "compile_ast JOIN with matching types" do
          it "does not cast" do
            sql = adapter.compile_ast(build_order_items_ast)
            expect(sql).to include("ON order_items.order_id = orders.id")
          end
        end

        context "compile_where_condition with :in_subquery (flat Subquery) and uuid mismatch" do
          it "casts outer key and inner select column" do
            allow(adapter).to receive(:column_pg_type).with("users", "shop_id").and_return('varchar')
            allow(adapter).to receive(:column_pg_type).with("shops", "id").and_return('uuid')

            users_table = users_table(adapter_name)
            ast = Exwiw::QueryAst::Select.new.tap do |a|
              a.from(users_table.name)
              a.select(users_table.columns)
              a.where(
                Exwiw::QueryAst::WhereClause.new(
                  column_name: "shop_id",
                  operator: :in_subquery,
                  value: Exwiw::QueryAst::Subquery.new(
                    table_name: "shops",
                    select_column: "id",
                    where_column: "name",
                    where_values: ["Shop 1"]
                  )
                )
              )
            end

            sql = adapter.compile_ast(ast)
            expect(sql).to include("users.shop_id::text IN (SELECT shops.id::text FROM shops")
          end
        end

        context "compile_ast with :in_subquery (SelectSubquery) and uuid mismatch" do
          it "casts the outer join key and the inner projected column" do
            allow(adapter).to receive(:column_pg_type).with("shops", "id").and_return('uuid')
            allow(adapter).to receive(:column_pg_type).with("users", "shop_id").and_return('varchar')

            fk_column = Exwiw::TableColumn.from_symbol_keys(name: "shop_id")
            inner_query = Exwiw::QueryAst::Select.new
            inner_query.from("users")
            inner_query.select([fk_column])
            inner_query.where(
              Exwiw::QueryAst::WhereClause.new(
                column_name: "name",
                operator: :eq,
                value: ["Alice"]
              )
            )

            shops_table = shops_table(adapter_name)
            ast = Exwiw::QueryAst::Select.new.tap do |a|
              a.from(shops_table.name)
              a.select(shops_table.columns)
              a.where(
                Exwiw::QueryAst::WhereClause.new(
                  column_name: "id",
                  operator: :in_subquery,
                  value: Exwiw::QueryAst::SelectSubquery.new(query: inner_query)
                )
              )
            end

            sql = adapter.compile_ast(ast)
            expect(sql).to include("SELECT users.shop_id::text FROM users")
            expect(sql).to include("ON shops.id::text = exwiw_scope_ids_0.exwiw_scope_id")
          end
        end

        context "compile_ast with a UnionSubquery and matching arm types" do
          it "materializes the UNION as a derived-table JOIN, casting nothing" do
            sql = adapter.compile_ast(build_reverse_scope_union_ast)
            expect(sql).to eq(
              "SELECT users.* FROM users JOIN (" \
              "SELECT DISTINCT exwiw_scope_src_0.user_id AS exwiw_scope_id FROM (" \
              "SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 1 AND customers.user_id IS NOT NULL " \
              "UNION " \
              "SELECT staff.user_id FROM staff WHERE staff.business_entity_id = 1 AND staff.user_id IS NOT NULL" \
              ") AS exwiw_scope_src_0) AS exwiw_scope_ids_0 ON users.id = exwiw_scope_ids_0.exwiw_scope_id"
            )
            expect(sql).not_to include("::text")
          end
        end

        context "compile_ast with a UnionSubquery where a later arm's type differs" do
          it "casts the outer join key AND every arm to ::text (not just the first)" do
            allow(adapter).to receive(:column_pg_type).with("users", "id").and_return('uuid')
            allow(adapter).to receive(:column_pg_type).with("customers", "user_id").and_return('uuid')
            allow(adapter).to receive(:column_pg_type).with("staff", "user_id").and_return('varchar')

            sql = adapter.compile_ast(build_reverse_scope_union_ast)
            expect(sql).to include("ON users.id::text = exwiw_scope_ids_0.exwiw_scope_id")
            expect(sql).to include("SELECT customers.user_id::text FROM customers")
            expect(sql).to include("SELECT staff.user_id::text FROM staff")
          end
        end

        context "compile_ast with a polymorphic multi-arm UnionSubquery" do
          it "materializes each arm's join chain into one derived-table JOIN" do
            sql = adapter.compile_ast(build_polymorphic_arm_union_ast)
            expect(sql).to eq(
              "SELECT comments.id FROM comments JOIN (" \
              "SELECT DISTINCT exwiw_scope_src_0.id AS exwiw_scope_id FROM (" \
              "SELECT comments.id FROM comments " \
              "JOIN posts ON comments.commentable_id = posts.id AND comments.commentable_type = 'Post' " \
              "JOIN shops ON posts.shop_id = shops.id AND shops.tenant_id = 't1' " \
              "UNION " \
              "SELECT comments.id FROM comments " \
              "JOIN pages ON comments.commentable_id = pages.id AND comments.commentable_type = 'Page' " \
              "JOIN shops ON pages.shop_id = shops.id AND shops.tenant_id = 't1'" \
              ") AS exwiw_scope_src_0) AS exwiw_scope_ids_0 ON comments.id = exwiw_scope_ids_0.exwiw_scope_id"
            )
            expect(sql).not_to include("::text")
          end
        end

        context "compile_ast with a three-level nested IN subquery (multi-hop forward cascade)" do
          it "nests a materialized derived-table JOIN at every level (matching types, no cast)" do
            sql = adapter.compile_ast(build_multi_hop_nested_in_ast)
            expect(sql).to eq(
              "SELECT projects.* FROM projects JOIN (" \
              "SELECT DISTINCT exwiw_scope_src_0.id AS exwiw_scope_id FROM (" \
              "SELECT teams.id FROM teams JOIN (" \
              "SELECT DISTINCT exwiw_scope_src_0.id AS exwiw_scope_id FROM (" \
              "SELECT companies.id FROM companies JOIN (" \
              "SELECT DISTINCT exwiw_scope_src_0.company_id AS exwiw_scope_id FROM (" \
              "SELECT memberships.company_id FROM memberships WHERE memberships.business_entity_id = 1 AND memberships.company_id IS NOT NULL" \
              ") AS exwiw_scope_src_0) AS exwiw_scope_ids_0 ON companies.id = exwiw_scope_ids_0.exwiw_scope_id" \
              ") AS exwiw_scope_src_0) AS exwiw_scope_ids_0 ON teams.company_id = exwiw_scope_ids_0.exwiw_scope_id" \
              ") AS exwiw_scope_src_0) AS exwiw_scope_ids_0 ON projects.team_id = exwiw_scope_ids_0.exwiw_scope_id"
            )
            expect(sql).not_to include("::text")
          end
        end

        context "column_pg_type returns nil (graceful fallback)" do
          it "does not cast and does not raise" do
            allow(adapter).to receive(:column_pg_type).and_return(nil)

            sql = adapter.compile_ast(build_order_items_ast)
            expect(sql).to include("ON order_items.order_id = orders.id")
            expect(sql).not_to include("::text")
          end
        end
      end

      describe "reserved-word identifier quoting" do
        context "select query on a reserved-word table with reserved-word columns" do
          let(:sql) { adapter.compile_ast(build_reserved_word_select_ast) }

          it "double-quotes the reserved identifiers in SELECT, masking and WHERE, leaving safe names bare" do
            expect(sql).to eq(
              %(SELECT "order".id, "order"."from", CASE WHEN "order"."to" IS NOT NULL THEN CONCAT('masked-', "order"."from") ELSE NULL END FROM "order" WHERE "order"."from" = 1)
            )
          end
        end

        context "select query joining a reserved-word table via a reserved-word foreign key" do
          let(:sql) { adapter.compile_ast(build_reserved_word_join_ast) }

          it "double-quotes the reserved identifiers in every JOIN position" do
            expect(sql).to eq(
              %(SELECT "order".id, "order"."from", CASE WHEN "order"."to" IS NOT NULL THEN CONCAT('masked-', "order"."from") ELSE NULL END FROM "order" JOIN "group" ON "order"."references" = "group".id AND "group"."from" = 1)
            )
          end
        end

        context "select query with a materialized scope JOIN over reserved-word tables" do
          let(:sql) { adapter.compile_ast(build_reserved_word_scope_ast) }

          it "double-quotes the projection, the outer key and the qualified star" do
            expect(sql).to eq(
              %(SELECT "order".* FROM "order" JOIN (SELECT DISTINCT exwiw_scope_src_0."from" AS exwiw_scope_id FROM (SELECT "group"."from" FROM "group") AS exwiw_scope_src_0) AS exwiw_scope_ids_0 ON "order"."from" = exwiw_scope_ids_0.exwiw_scope_id)
            )
          end
        end

        context "bulk insert into the reserved-word table" do
          let(:bulk_insert_sql) { adapter.to_bulk_insert([[1, 1, 'x']], reserved_word_table) }

          it "double-quotes the reserved identifiers in the INSERT header" do
            expect(bulk_insert_sql.strip).to eq(<<~SQL.strip)
              INSERT INTO "order" (id, "from", "to") VALUES
              (1, 1, 'x');
            SQL
          end
        end

        context "copy output for the reserved-word table" do
          let(:copy_output) { adapter.to_copy_from_stdin([[1, 1, 'x']], reserved_word_table) }

          it "double-quotes the reserved identifiers in the COPY header" do
            expect(copy_output).to eq(<<~SQL.strip)
              COPY "order" (id, "from", "to") FROM stdin;
              1\t1\tx
              \\.
            SQL
          end
        end

        context "select query with only safe identifiers" do
          let(:sql) { adapter.compile_ast(build_select_shops_ast) }

          it "emits no quotes at all (byte-identical output)" do
            expect(sql).not_to include('"')
          end
        end

        # End-to-end proof (against the live postgres) that the quoted SQL
        # actually parses and round-trips. TEMP tables keep the seed database
        # untouched: they are visible only to this adapter's connection
        # (execute / COUNT / DELETE / INSERT all reuse it) and are dropped
        # with the connection when the example ends. Unquoted, `order` as a
        # table name and `from` in an INSERT column list are postgres syntax
        # errors.
        describe "against a live database" do
          let(:connection) { adapter.send(:connection) }
          let(:extracted_rows) { adapter.execute(build_reserved_word_select_ast).to_a }

          before do
            connection.exec(%(CREATE TEMP TABLE "order" (id int PRIMARY KEY, "from" int, "to" varchar(32))))
            connection.exec(%(INSERT INTO "order" (id, "from", "to") VALUES (1, 1, 'x'), (2, 2, 'y')))
          end

          context "extracting from the reserved-word table" do
            it "returns the scoped row with the reserved columns masked" do
              expect(extracted_rows).to eq([["1", "1", "masked-1"]])
            end
          end

          context "restoring the generated INSERT after the scoped row was deleted" do
            before do
              rows = extracted_rows
              connection.exec(%(DELETE FROM "order" WHERE "order"."from" = 1))
              connection.exec(adapter.to_bulk_insert(rows, reserved_word_table))
            end

            it "round-trips the extracted rows" do
              expect(connection.exec(%(SELECT id, "from", "to" FROM "order" ORDER BY id)).values).to eq([
                ["1", "1", "masked-1"],
                ["2", "2", "y"],
              ])
            end
          end

          context "reserved, mixed-case table with a serial primary key" do
            let(:serial_table) do
              Exwiw::TableConfig.from_symbol_keys(
                name: "Order",
                primary_key: "id",
                belongs_tos: [],
                columns: [{ name: "id" }, { name: "from" }],
              )
            end
            let(:post_insert) { adapter.post_insert_sql(serial_table) }

            before do
              connection.exec(%(CREATE TEMP TABLE "Order" (id serial PRIMARY KEY, "from" int)))
              connection.exec(%(INSERT INTO "Order" ("from") VALUES (1), (2)))
            end

            it "syncs the sequence via setval (pg_get_serial_sequence receives the quoted name, not the case-folded one)" do
              expect(post_insert).to include("setval")
              expect { connection.exec(post_insert) }.not_to raise_error
            end
          end
        end
      end

      # End-to-end proof against the live postgres that a polymorphic join table
      # scoped through several arms extracts every arm's rows and nothing from
      # another tenant. TEMP tables keep the seed database untouched: they live
      # on this adapter's connection only (execute / COUNT / DELETE all reuse
      # it) and vanish when the example's connection is dropped.
      describe "polymorphic multi-arm scope against a live database" do
        let(:connection) { adapter.send(:connection) }
        let(:dump_target) { Exwiw::DumpTarget.new(ids: ['t1'], scope_column: 'tenant_id') }
        let(:arm_shops) do
          TableConfig.from_symbol_keys(
            name: 'arm_shops', primary_key: 'id', belongs_tos: [],
            columns: [{ name: 'id' }, { name: 'tenant_id' }]
          )
        end
        let(:arm_posts) do
          TableConfig.from_symbol_keys(
            name: 'arm_posts', primary_key: 'id',
            belongs_tos: [{ table_name: 'arm_shops', foreign_key: 'shop_id' }],
            columns: [{ name: 'id' }, { name: 'shop_id' }]
          )
        end
        let(:arm_pages) do
          TableConfig.from_symbol_keys(
            name: 'arm_pages', primary_key: 'id',
            belongs_tos: [{ table_name: 'arm_shops', foreign_key: 'shop_id' }],
            columns: [{ name: 'id' }, { name: 'shop_id' }]
          )
        end
        let(:arm_comments) do
          TableConfig.from_symbol_keys(
            name: 'arm_comments', primary_key: 'id',
            belongs_tos: [
              { table_name: 'arm_posts', foreign_key: 'commentable_id',
                foreign_type: 'commentable_type', type_value: 'Post' },
              { table_name: 'arm_pages', foreign_key: 'commentable_id',
                foreign_type: 'commentable_type', type_value: 'Page' },
            ],
            columns: [
              { name: 'id' }, { name: 'commentable_type' },
              { name: 'commentable_id' }, { name: 'body' }
            ]
          )
        end
        let(:table_by_name) do
          [arm_shops, arm_posts, arm_pages, arm_comments].each_with_object({}) { |t, h| h[t.name] = t }
        end
        let(:comments_ast) { QueryAstBuilder.run('arm_comments', table_by_name, dump_target, logger) }

        before do
          connection.exec(<<~SQL)
            CREATE TEMP TABLE arm_shops (id int PRIMARY KEY, tenant_id varchar(8));
            CREATE TEMP TABLE arm_posts (id int PRIMARY KEY, shop_id int);
            CREATE TEMP TABLE arm_pages (id int PRIMARY KEY, shop_id int);
            CREATE TEMP TABLE arm_comments (id int PRIMARY KEY, commentable_type varchar(32), commentable_id int, body varchar(64));

            INSERT INTO arm_shops VALUES (1, 't1'), (2, 't2');
            INSERT INTO arm_posts VALUES (1, 1), (2, 2);
            INSERT INTO arm_pages VALUES (10, 1), (11, 2);
            INSERT INTO arm_comments VALUES
              (1, 'Post', 1, 'on t1 post'),
              (2, 'Page', 10, 'on t1 page'),
              (3, 'Post', 2, 'on t2 post'),
              (4, 'Page', 11, 'on t2 page'),
              (5, 'Post', 10, 'dangling');
          SQL
        end

        it "extracts every arm's rows and nothing from another tenant" do
          rows = adapter.execute(comments_ast).to_a

          expect(rows.map(&:first)).to eq(["1", "2"])
          expect(rows.map { |row| row[1] }).to eq(%w[Post Page])
          expect(rows.map(&:last)).to eq(['on t1 post', 'on t1 page'])
        end
      end
    end
  end
end

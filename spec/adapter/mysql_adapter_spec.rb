# frozen_string_literal: true

require 'tempfile'

module Exwiw
  module Adapter
    RSpec.describe MysqlAdapter do
      let(:adapter_name) { 'mysql' }
      let(:connection_config) do
        ConnectionConfig.new(
          adapter: adapter_name,
          database_name: 'exwiw_test',
          host: '127.0.0.1',
          port: 3306,
          user: 'root',
          password: 'rootpassword',
        )
      end
      let(:logger) { Logger.new(nil) }
      let(:adapter) { described_class.new(connection_config, logger) }

      describe "#execute scope id-set materialization" do
        let(:recorded) { [] }
        let(:fake_client) do
          client = instance_double(MysqlClient)
          allow(client).to receive(:query) do |sql|
            recorded << sql
            MysqlClient::Result.new(fields: ['COUNT(*)'], rows: [['42']])
          end
          client
        end

        before { allow(adapter).to receive(:connection).and_return(fake_client) }

        def data_sql_of(streaming_result)
          streaming_result.instance_variable_get(:@data_sql)
        end

        it "materializes a scope id-set once and joins the temp table in the data query" do
          result = adapter.execute(build_reverse_scope_union_ast)

          creates = recorded.grep(/\ACREATE TEMPORARY TABLE/)
          expect(creates.size).to eq(1)
          expect(creates.first).to include("SELECT customers.user_id FROM customers")
          expect(recorded.grep(/\AALTER TABLE/).size).to eq(1)

          expect(data_sql_of(result)).to include(
            "JOIN exwiw_scope_id_set_0 AS exwiw_scope_ids_0 ON users.id = exwiw_scope_ids_0.exwiw_scope_id"
          )
          expect(data_sql_of(result)).not_to include("UNION")
        end

        it "reuses the materialized id-set across executes with the same scope" do
          adapter.execute(build_reverse_scope_union_ast)
          result = adapter.execute(build_reverse_scope_union_ast)

          expect(recorded.grep(/\ACREATE TEMPORARY TABLE/).size).to eq(1)
          expect(data_sql_of(result)).to include("JOIN exwiw_scope_id_set_0")
        end

        it "materializes nested scopes bottom-up, building outer sets from inner ones" do
          result = adapter.execute(build_multi_hop_nested_in_ast)

          creates = recorded.grep(/\ACREATE TEMPORARY TABLE/)
          expect(creates.size).to eq(3)
          expect(creates[0]).to include("FROM memberships")
          expect(creates[1]).to include("JOIN exwiw_scope_id_set_0")
          expect(creates[2]).to include("JOIN exwiw_scope_id_set_1")
          expect(data_sql_of(result)).to include("JOIN exwiw_scope_id_set_2")
        end

        it "does not create temporary tables during explain" do
          adapter.explain(build_reverse_scope_union_ast)

          expect(recorded.grep(/\ACREATE TEMPORARY TABLE/)).to be_empty
          expect(recorded.grep(/\AEXPLAIN/).first).to include("SELECT DISTINCT exwiw_scope_src_0.user_id")
        end

        it "falls back to inline scope subqueries when temp table creation fails" do
          allow(fake_client).to receive(:query) do |sql|
            recorded << sql
            raise "CREATE TEMPORARY TABLES command denied" if sql.start_with?("CREATE TEMPORARY TABLE")

            MysqlClient::Result.new(fields: ['COUNT(*)'], rows: [['42']])
          end

          result = adapter.execute(build_reverse_scope_union_ast)
          expect(data_sql_of(result)).to include("JOIN (SELECT DISTINCT exwiw_scope_src_0.user_id AS exwiw_scope_id")

          adapter.execute(build_reverse_scope_union_ast)
          expect(recorded.grep(/\ACREATE TEMPORARY TABLE/).size).to eq(1)
        end
      end

      describe "#dump_schema" do
        let(:schema_path) { Tempfile.new(['mysql_schema', '.sql']).path }

        it "writes CREATE TABLE IF NOT EXISTS for every table in the database" do
          # Full-database dump: the passed tables no longer scope the output, so
          # pass a subset and assert the whole database's DDL is emitted.
          tables = [shops_table(adapter_name), users_table(adapter_name)]
          adapter.dump_schema(tables, schema_path)

          sql = File.read(schema_path)
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS `shops`/i)
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS `users`/i)
          # Tables NOT in the passed subset are still emitted (whole-database dump).
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS `products`/i)
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS `reviews`/i)
        end

        it "wraps output with SET FOREIGN_KEY_CHECKS" do
          tables = [shops_table(adapter_name)]
          adapter.dump_schema(tables, schema_path)

          lines = File.readlines(schema_path).map(&:chomp)
          expect(lines[1]).to eq("SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;")
          expect(lines.last).to eq("SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;")
        end

        context "when mysqldump is MariaDB" do
          let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
          let(:dump_output) { "CREATE TABLE `shops` (\n  `id` int NOT NULL\n) ENGINE=InnoDB;\n" }

          before do
            allow(Open3).to receive(:capture3)
              .with('mysqldump', '--version')
              .and_return(["mysqldump  Ver 10.11.6-MariaDB, for debian-linux-gnu (x86_64)\n", '', success_status])

            allow(Open3).to receive(:capture3)
              .with(hash_including('MYSQL_PWD'), 'mysqldump', any_args) do |_env, *cmd|
                @captured_cmd = cmd
                [dump_output, '', success_status]
              end
          end

          it "does not pass --set-gtid-purged=OFF" do
            tables = [shops_table(adapter_name)]
            adapter.dump_schema(tables, schema_path)
            expect(@captured_cmd).not_to include('--set-gtid-purged=OFF')
          end

          it "includes --no-tablespaces" do
            tables = [shops_table(adapter_name)]
            adapter.dump_schema(tables, schema_path)
            expect(@captured_cmd).to include('--no-tablespaces')
          end
        end

        context "when mysqldump is MySQL" do
          let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
          let(:dump_output) { "CREATE TABLE `shops` (\n  `id` int NOT NULL\n) ENGINE=InnoDB;\n" }

          before do
            allow(Open3).to receive(:capture3)
              .with('mysqldump', '--version')
              .and_return(["mysqldump  Ver 8.0.36 Distrib 8.0.36, for Linux on x86_64\n", '', success_status])

            allow(Open3).to receive(:capture3)
              .with(hash_including('MYSQL_PWD'), 'mysqldump', any_args) do |_env, *cmd|
                @captured_cmd = cmd
                [dump_output, '', success_status]
              end
          end

          it "passes --set-gtid-purged=OFF" do
            tables = [shops_table(adapter_name)]
            adapter.dump_schema(tables, schema_path)
            expect(@captured_cmd).to include('--set-gtid-purged=OFF')
          end

          it "includes --no-tablespaces" do
            tables = [shops_table(adapter_name)]
            adapter.dump_schema(tables, schema_path)
            expect(@captured_cmd).to include('--no-tablespaces')
          end
        end

        context "when mysqldump --version fails" do
          let(:failure_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }
          let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
          let(:dump_output) { "CREATE TABLE `shops` (\n  `id` int NOT NULL\n) ENGINE=InnoDB;\n" }

          before do
            allow(Open3).to receive(:capture3)
              .with('mysqldump', '--version')
              .and_return(['', 'some error', failure_status])

            allow(Open3).to receive(:capture3)
              .with(hash_including('MYSQL_PWD'), 'mysqldump', any_args) do |_env, *cmd|
                @captured_cmd = cmd
                [dump_output, '', success_status]
              end
          end

          it "defaults to including --set-gtid-purged=OFF" do
            tables = [shops_table(adapter_name)]
            adapter.dump_schema(tables, schema_path)
            expect(@captured_cmd).to include('--set-gtid-purged=OFF')
          end
        end

        context "when EXWIW_MYSQLDUMP points at a missing binary" do
          around do |example|
            original = ENV['EXWIW_MYSQLDUMP']
            ENV['EXWIW_MYSQLDUMP'] = '/nonexistent/path/to/mysqldump-xyz'
            example.run
            if original.nil?
              ENV.delete('EXWIW_MYSQLDUMP')
            else
              ENV['EXWIW_MYSQLDUMP'] = original
            end
          end

          it "raises a message naming the configured binary and EXWIW_MYSQLDUMP" do
            tables = [shops_table(adapter_name)]
            expect { adapter.dump_schema(tables, schema_path) }
              .to raise_error(/mysqldump-xyz.*EXWIW_MYSQLDUMP/m)
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
            expect(sql).to eq("SELECT users.id, CONCAT('masked', users.id), CASE WHEN users.email IS NOT NULL THEN CONCAT('masked', users.id, '@example.com') ELSE NULL END, users.shop_id, users.updated_at, users.created_at FROM users WHERE users.shop_id = 1")
          end
        end

        context "select query with filter" do
          let(:sql) { adapter.compile_ast(build_select_users_ast("users.id > 1")) }

          it "builds sql" do
            expect(sql).to eq("SELECT users.id, CONCAT('masked', users.id), CASE WHEN users.email IS NOT NULL THEN CONCAT('masked', users.id, '@example.com') ELSE NULL END, users.shop_id, users.updated_at, users.created_at FROM users WHERE users.shop_id = 1 AND users.id > 1")
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

        context "select query with a multi-referencer reverse-scope UNION subquery" do
          let(:sql) { adapter.compile_ast(build_reverse_scope_union_ast) }

          it "materializes the UNION id-set as a derived-table JOIN of NULL-excluding projected selects" do
            expect(sql).to eq(
              "SELECT users.* FROM users JOIN (" \
              "SELECT DISTINCT exwiw_scope_src_0.user_id AS exwiw_scope_id FROM (" \
              "SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 1 AND customers.user_id IS NOT NULL " \
              "UNION " \
              "SELECT staff.user_id FROM staff WHERE staff.business_entity_id = 1 AND staff.user_id IS NOT NULL" \
              ") AS exwiw_scope_src_0) AS exwiw_scope_ids_0 ON users.id = exwiw_scope_ids_0.exwiw_scope_id"
            )
          end
        end

        context "select query with a three-level nested IN subquery (multi-hop forward cascade)" do
          let(:sql) { adapter.compile_ast(build_multi_hop_nested_in_ast) }

          it "nests a materialized derived-table JOIN at every level" do
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
          end
        end
      end

      # The reverse_scope / forward-cascade id-set is emitted as a JOIN to a
      # materialized (SELECT DISTINCT) derived table rather than `<col> IN
      # (subquery)`. These run against the real seed DB to prove the rewrite
      # (a) returns the same rows and (b) no longer compiles to a correlated
      # DEPENDENT SUBQUERY (the per-row re-evaluation that timed out in prod).
      describe "scope id-set materialization (derived-table JOIN)" do
        let(:ast) { build_users_reverse_scope_over_seed_ast }
        let(:in_sql) { users_reverse_scope_over_seed_in_sql }

        it "returns the same users as the equivalent IN-subquery (result-set equivalence)" do
          new_ids = adapter.execute(ast).to_a.map { |row| row.first.to_s }.sort
          old_ids = adapter.send(:connection).query(in_sql).rows.map { |row| row.first.to_s }.sort

          expect(new_ids).not_to be_empty
          expect(new_ids).to eq(old_ids)
        end

        it "EXPLAINs as a materialized id-set with no correlated DEPENDENT SUBQUERY" do
          before_plan = adapter.send(:connection).query("EXPLAIN #{in_sql}").rows.flatten.join("\n").downcase
          after_plan = adapter.explain(ast).downcase

          # `IN (… UNION …)` makes MySQL re-evaluate the subquery per outer row.
          # exwiw runs a plain `EXPLAIN` (no FORMAT=); its default rendering is
          # server-version-dependent — tree-format on MySQL 8.3+/9 (this suite's
          # server), classic-tabular on older — but the per-row plan is flagged
          # "dependent" in both ("dependent" / "DEPENDENT SUBQUERY"), so the
          # before/after on that substring is the format-robust signal.
          expect(before_plan).to include("dependent")
          # After: the union is evaluated once and users is reached by probing
          # that id-set — no correlated subquery remains. The tree-format plan
          # this server returns also names the one-shot id-set ("Materialize").
          expect(after_plan).not_to include("dependent")
          expect(after_plan).to match(/materiali/)
        end
      end

      describe "#execute" do
        context "simple select query" do
          # #execute now returns a streaming Enumerable (mysql2 single-row
          # stream), so drain it with #to_a to compare against the expected rows.
          let(:results) { adapter.execute(build_select_shops_ast).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "Shop 1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ])
          end
        end

        context "select query with masking" do
          let(:results) { adapter.execute(build_select_users_ast).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "masked1", "masked1@example.com", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["2", "masked2", "masked2@example.com", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ])
          end
        end

        context "select query with filter" do
          let(:results) { adapter.execute(build_select_users_ast("users.id > 1")).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["2", "masked2", "masked2@example.com", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ])
          end
        end

        context "select query with one join" do
          let(:results) { adapter.execute(build_order_items_ast).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "1", "1", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["2", "1", "2", "2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["3", "1", "3", "3", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["4", "1", "4", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["5", "1", "5", "2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["6", "1", "6", "3", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ])
          end
        end

        context "select query with one join, one filter" do
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", nil)) }

          it "returns correct results" do
            expect(results.to_a).to eq([
              ["2", "1", "2", "2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["3", "1", "3", "3", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["4", "1", "4", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["5", "1", "5", "2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["6", "1", "6", "3", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ])
          end
        end

        context "select query with filter on join" do
          let(:results) { adapter.execute(build_order_items_ast(nil, "orders.id < 6")).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "1", "1", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["2", "1", "2", "2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["3", "1", "3", "3", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["4", "1", "4", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["5", "1", "5", "2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ])
          end
        end

        context "select query with filter on join and filter on where" do
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", "orders.id < 6")).to_a }

          it "returns correct results" do
            expect(results).to eq([
              ["2", "1", "2", "2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["3", "1", "3", "3", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["4", "1", "4", "1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["5", "1", "5", "2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ])
          end
        end
      end

      describe "#explain" do
        it "returns EXPLAIN output for a simple select" do
          output = adapter.explain(build_select_shops_ast)
          expect(output).to be_a(String)
          expect(output).not_to be_empty
          # Output is formatted as vertical rows; assert that header markers and
          # at least one key/value pair are present. MySQL 5.7/8.0 return classic
          # table columns (id/select_type/table/...); MySQL 8.0.16+ returns a
          # single EXPLAIN column with tree-format text. Both are acceptable.
          expect(output).to include('1. row')
          expect(output).to match(/(table|EXPLAIN):/i)
        end
      end

      describe "#to_bulk_insert" do
        let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

        context "simple select query" do
          let(:results) do
            [
              ["1", "Shop 1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["2", "Shop 2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["3", "Shop 3", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ]
          end

          let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

          it "returns correct bulk insert sql" do
            expect(bulk_insert_sql.strip).to eq(<<~SQL.strip)
              INSERT INTO `shops` (`id`, `name`, `updated_at`, `created_at`) VALUES
              ('1', 'Shop 1', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
              ('2', 'Shop 2', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
              ('3', 'Shop 3', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000');
            SQL
          end
        end

        context "has single quote" do
          let(:results) do
            [
              ["1", "Shop' 1", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["2", "Shop 2", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
              ["3", "Shop 3", "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ]
          end

          let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

          it "returns correct bulk insert sql" do
            expect(bulk_insert_sql.strip).to eq(<<~SQL.strip)
              INSERT INTO `shops` (`id`, `name`, `updated_at`, `created_at`) VALUES
              ('1', 'Shop'' 1', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
              ('2', 'Shop 2', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000'),
              ('3', 'Shop 3', '2025-01-01 00:00:00.000000', '2025-01-01 00:00:00.000000');
            SQL
          end
        end

        context "has backslash in JSON value" do
          let(:json_value) { '{"key":"val"}' }
          let(:results) do
            [
              ["1", json_value, "2025-01-01 00:00:00.000000", "2025-01-01 00:00:00.000000"],
            ]
          end

          let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

          it "doubles backslashes so MySQL preserves them on restore" do
            escaped = json_value.gsub('\\') { '\\\\' }
            expect(bulk_insert_sql).to include("'#{escaped}'")
          end
        end

        context "has control characters in value" do
          let(:results) do
            ts = "2025-01-01 00:00:00.000000"
            [
              ["1", "a;\nb", ts, ts],
              ["2", "a\rb", ts, ts],
              ["3", "a\u0000b", ts, ts],
              ["4", "a\u001Ab", ts, ts],
            ]
          end

          let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

          it "escapes control characters so tuples stay parseable" do
            expect(bulk_insert_sql).to include("'a;\\nb'")
            expect(bulk_insert_sql).to include("'a\\rb'")
            expect(bulk_insert_sql).to include("'a\\0b'")
            expect(bulk_insert_sql).to include("'a\\Zb'")

            expect(bulk_insert_sql).not_to include("a;\nb")
            expect(bulk_insert_sql).not_to include("a\rb")
            expect(bulk_insert_sql).not_to include("a\u0000b")
            expect(bulk_insert_sql).not_to include("a\u001Ab")
          end
        end
      end

      describe "#to_bulk_delete" do
        context "simple select query" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_select_shops_ast, shops_table(adapter_name)) }

          it "builds sql" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM shops
              WHERE shops.id = 1;
            SQL
          end
        end

        context "select query with masking" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_select_users_ast, users_table(adapter_name)) }

          it "builds sql" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM users
              WHERE users.shop_id = 1;
            SQL
          end
        end

        context "select query with filter" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_select_users_ast("users.id > 1"), users_table(adapter_name)) }

          it "ignores filter option" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM users
              WHERE users.shop_id = 1;
            SQL
          end
        end

        context "select query with one join" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_order_items_ast, order_items_table(adapter_name)) }

          it "ignores filter option" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM order_items
              WHERE order_items.order_id IN (SELECT orders.id FROM orders WHERE orders.shop_id = 1);
            SQL
          end
        end

        context "select query with one join, one filter" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_order_items_ast("order_items.id > 1", nil), order_items_table(adapter_name)) }

          it "ignores filter option" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM order_items
              WHERE order_items.order_id IN (SELECT orders.id FROM orders WHERE orders.shop_id = 1);
            SQL
          end
        end

        context "select query with filter on join" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_order_items_ast(nil, "orders.id > 1"), order_items_table(adapter_name)) }

          it "ignores filter option" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM order_items
              WHERE order_items.order_id IN (SELECT orders.id FROM orders WHERE orders.shop_id = 1);
            SQL
          end
        end

        context "select query with filter on join and filter on where" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_order_items_ast("order_items.id > 1", "orders.id > 1"), order_items_table(adapter_name)) }

          it "ignores filter option" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM order_items
              WHERE order_items.order_id IN (SELECT orders.id FROM orders WHERE orders.shop_id = 1);
            SQL
          end
        end
      end

      describe "reserved-word identifier quoting" do
        context "select query on a reserved-word table with reserved-word columns" do
          let(:sql) { adapter.compile_ast(build_reserved_word_select_ast) }

          it "backtick-quotes the reserved identifiers in SELECT, masking and WHERE, leaving safe names bare" do
            expect(sql).to eq(
              %(SELECT `order`.id, `order`.`from`, CASE WHEN `order`.`to` IS NOT NULL THEN CONCAT('masked-', `order`.`from`) ELSE NULL END FROM `order` WHERE `order`.`from` = 1)
            )
          end
        end

        context "select query joining a reserved-word table via a reserved-word foreign key" do
          let(:sql) { adapter.compile_ast(build_reserved_word_join_ast) }

          it "backtick-quotes the reserved identifiers in every JOIN position" do
            expect(sql).to eq(
              %(SELECT `order`.id, `order`.`from`, CASE WHEN `order`.`to` IS NOT NULL THEN CONCAT('masked-', `order`.`from`) ELSE NULL END FROM `order` JOIN `group` ON `order`.`references` = `group`.id AND `group`.`from` = 1)
            )
          end
        end

        context "select query with a materialized scope JOIN over reserved-word tables" do
          let(:sql) { adapter.compile_ast(build_reserved_word_scope_ast) }

          it "backtick-quotes the projection, the outer key and the qualified star" do
            expect(sql).to eq(
              %(SELECT `order`.* FROM `order` JOIN (SELECT DISTINCT exwiw_scope_src_0.`from` AS exwiw_scope_id FROM (SELECT `group`.`from` FROM `group`) AS exwiw_scope_src_0) AS exwiw_scope_ids_0 ON `order`.`from` = exwiw_scope_ids_0.exwiw_scope_id)
            )
          end
        end

        context "bulk insert into the reserved-word table" do
          let(:bulk_insert_sql) { adapter.to_bulk_insert([[1, 1, 'x']], reserved_word_table) }

          it "backtick-quotes the reserved table name in the INSERT header (columns were always quoted)" do
            expect(bulk_insert_sql.strip).to eq(<<~SQL.strip)
              INSERT INTO `order` (`id`, `from`, `to`) VALUES
              (1, 1, 'x');
            SQL
          end
        end

        context "bulk delete scoped by a reserved-word column" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_reserved_word_select_ast, reserved_word_table) }

          it "backtick-quotes the reserved identifiers in DELETE" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM `order`
              WHERE `order`.`from` = 1;
            SQL
          end
        end

        context "select query with only safe identifiers" do
          let(:sql) { adapter.compile_ast(build_select_shops_ast) }

          it "emits no backticks at all (byte-identical output)" do
            expect(sql).not_to include('`')
          end
        end

        # End-to-end proof (against the live mysql) that the quoted SQL
        # actually parses and round-trips. A TEMPORARY table keeps the seed
        # database untouched: it is visible only to this adapter's connection
        # (execute / COUNT / DELETE / INSERT all reuse it) and is dropped with
        # the connection when the example ends. Unquoted, `order` as a table
        # name is a mysql syntax error.
        describe "against a live database" do
          let(:client) { adapter.send(:connection) }
          # MysqlClient#query wraps SELECT results only; drive DDL/DML through
          # the underlying driver connection (same connection, so the
          # TEMPORARY table stays visible to the adapter's queries).
          let(:raw_connection) { client.send(:raw) }
          let(:extracted_rows) { adapter.execute(build_reserved_word_select_ast).to_a }

          before do
            raw_connection.query(%(CREATE TEMPORARY TABLE `order` (id INT PRIMARY KEY, `from` INT, `to` VARCHAR(32))))
            raw_connection.query(%(INSERT INTO `order` (id, `from`, `to`) VALUES (1, 1, 'x'), (2, 2, 'y')))
          end

          context "extracting from the reserved-word table" do
            it "returns the scoped row with the reserved columns masked" do
              expect(extracted_rows).to eq([["1", "1", "masked-1"]])
            end
          end

          context "applying the generated DELETE" do
            before do
              raw_connection.query(adapter.to_bulk_delete(build_reserved_word_select_ast, reserved_word_table).delete_suffix(";"))
            end

            it "removes only the scoped row" do
              expect(client.query(%(SELECT id FROM `order`)).rows).to eq([["2"]])
            end
          end

          context "restoring the generated INSERT after the scoped row was deleted" do
            before do
              rows = extracted_rows
              raw_connection.query(adapter.to_bulk_delete(build_reserved_word_select_ast, reserved_word_table).delete_suffix(";"))
              raw_connection.query(adapter.to_bulk_insert(rows, reserved_word_table).delete_suffix(";"))
            end

            it "round-trips the extracted rows" do
              expect(client.query(%(SELECT id, `from`, `to` FROM `order` ORDER BY id)).rows).to eq([
                ["1", "1", "masked-1"],
                ["2", "2", "y"],
              ])
            end
          end
        end
      end
    end
  end
end

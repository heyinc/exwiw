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

      describe "#dump_schema" do
        let(:schema_path) { Tempfile.new(['mysql_schema', '.sql']).path }

        it "writes CREATE TABLE IF NOT EXISTS for the requested tables" do
          tables = [shops_table(adapter_name), users_table(adapter_name)]
          adapter.dump_schema(tables, schema_path)

          sql = File.read(schema_path)
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS `shops`/i)
          expect(sql).to match(/CREATE TABLE IF NOT EXISTS `users`/i)
          expect(sql).not_to match(/`products`/) # not in scope
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

          it "compiles to IN (… UNION …) of NULL-excluding projected selects" do
            expect(sql).to eq(
              "SELECT * FROM users WHERE users.id IN (" \
              "SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 1 AND customers.user_id IS NOT NULL " \
              "UNION " \
              "SELECT staff.user_id FROM staff WHERE staff.business_entity_id = 1 AND staff.user_id IS NOT NULL)"
            )
          end
        end

        context "select query with a three-level nested IN subquery (multi-hop forward cascade)" do
          let(:sql) { adapter.compile_ast(build_multi_hop_nested_in_ast) }

          it "renders the subqueries recursively at every level" do
            expect(sql).to eq(
              "SELECT * FROM projects WHERE projects.team_id IN (" \
              "SELECT teams.id FROM teams WHERE teams.company_id IN (" \
              "SELECT companies.id FROM companies WHERE companies.id IN (" \
              "SELECT memberships.company_id FROM memberships WHERE memberships.business_entity_id = 1 AND memberships.company_id IS NOT NULL)))"
            )
          end
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
    end
  end
end

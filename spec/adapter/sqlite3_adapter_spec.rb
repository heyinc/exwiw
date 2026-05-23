# frozen_string_literal: true

require 'tempfile'

module Exwiw
  module Adapter
    RSpec.describe Sqlite3Adapter do
      let(:adapter_name) { 'sqlite3' }
      let(:connection_config) do
        ConnectionConfig.new(
          adapter: adapter_name,
          database_name: 'tmp/test.sqlite3',
          host: nil,
          port: nil,
          user: nil,
          password: nil,
        )
      end
      let(:logger) { Logger.new(nil) }
      let(:adapter) { described_class.new(connection_config, logger) }

      describe "#schema_output_extension" do
        it { expect(adapter.schema_output_extension).to eq('sql') }
      end

      describe "#dump_schema" do
        let(:schema_path) { Tempfile.new(['sqlite3_schema', '.sql']).path }

        it "writes idempotent CREATE TABLE/INDEX statements for the given tables" do
          tables = [shops_table(adapter_name), users_table(adapter_name)]
          adapter.dump_schema(tables, schema_path)

          sql = File.read(schema_path)
          expect(sql).to include('CREATE TABLE IF NOT EXISTS "shops"')
          expect(sql).to include('CREATE TABLE IF NOT EXISTS "users"')
          expect(sql).to include('CREATE INDEX IF NOT EXISTS "index_users_on_shop_id"')
          # Tables not in ordered_tables are not emitted
          expect(sql).not_to include('"products"')
        end

        it "emits tables in the provided order" do
          tables = [users_table(adapter_name), shops_table(adapter_name)]
          adapter.dump_schema(tables, schema_path)

          sql = File.read(schema_path)
          expect(sql.index('CREATE TABLE IF NOT EXISTS "users"')).to be < sql.index('CREATE TABLE IF NOT EXISTS "shops"')
        end

        it "is idempotent — re-running the produced SQL against the same DB does not raise" do
          tables = [shops_table(adapter_name)]
          adapter.dump_schema(tables, schema_path)
          sql = File.read(schema_path)
          # Strip comment lines (SQLite's execute_batch doesn't handle leading `--` cleanly in all versions but it's tolerant; keep raw).
          expect { ::SQLite3::Database.new(connection_config.database_name).execute_batch(sql) }.not_to raise_error
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
            expect(sql).to eq("SELECT users.id, ('masked' || users.id), ('masked' || users.id || '@example.com'), users.shop_id, users.updated_at, users.created_at FROM users WHERE users.shop_id = 1")
          end
        end

        context "select query with filter" do
          let(:sql) { adapter.compile_ast(build_select_users_ast("users.id > 1")) }

          it "builds sql" do
            expect(sql).to eq("SELECT users.id, ('masked' || users.id), ('masked' || users.id || '@example.com'), users.shop_id, users.updated_at, users.created_at FROM users WHERE users.shop_id = 1 AND users.id > 1")
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

      describe "#execute" do
        context "simple select query" do
          let(:results) { adapter.execute(build_select_shops_ast) }

          it "returns correct results" do
            expect(results).to eq([
              [1, "Shop 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with masking" do
          let(:results) { adapter.execute(build_select_users_ast) }

          it "returns correct results" do
            expect(results).to eq([
              [1, "masked1", "masked1@example.com", 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [2, "masked2", "masked2@example.com", 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with filter" do
          let(:results) { adapter.execute(build_select_users_ast("users.id > 1")) }

          it "returns correct results" do
            expect(results).to eq([
              [2, "masked2", "masked2@example.com", 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with one join" do
          let(:results) { adapter.execute(build_order_items_ast) }

          it "returns correct results" do
            expect(results).to eq([
              [1, 1, 1, 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [2, 1, 2, 2, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [3, 1, 3, 3, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [4, 1, 4, 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [5, 1, 5, 2, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [6, 1, 6, 3, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with one join, one filter" do
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", nil)) }

          it "returns correct results" do
            expect(results).to eq([
              [2, 1, 2, 2, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [3, 1, 3, 3, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [4, 1, 4, 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [5, 1, 5, 2, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [6, 1, 6, 3, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with filter on join" do
          let(:results) { adapter.execute(build_order_items_ast(nil, "orders.id < 6")) }

          it "returns correct results" do
            expect(results).to eq([
              [1, 1, 1, 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [2, 1, 2, 2, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [3, 1, 3, 3, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [4, 1, 4, 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [5, 1, 5, 2, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with filter on join and filter on where" do
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", "orders.id < 6")) }

          it "returns correct results" do
            expect(results).to eq([
              [2, 1, 2, 2, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [3, 1, 3, 3, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [4, 1, 4, 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [5, 1, 5, 2, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end
      end

      describe "#explain" do
        it "returns EXPLAIN QUERY PLAN output for a simple select" do
          output = adapter.explain(build_select_shops_ast)
          expect(output).to be_a(String)
          expect(output).not_to be_empty
          expect(output).to match(/shops/i)
        end

        it "returns EXPLAIN QUERY PLAN output for a join query" do
          output = adapter.explain(build_order_items_ast)
          expect(output).to be_a(String)
          expect(output).not_to be_empty
          expect(output).to match(/order_items|orders/i)
        end
      end

      describe "#to_bulk_insert" do
        let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

        context "simple select query" do
          let(:results) do
            [
              [1, "Shop 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [2, "Shop 2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [3, "Shop 3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ]
          end

          it "returns correct bulk insert sql" do
            expect(bulk_insert_sql.strip).to eq(<<~SQL.strip)
              INSERT INTO shops (id, name, updated_at, created_at) VALUES
              (1, 'Shop 1', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
              (2, 'Shop 2', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
              (3, 'Shop 3', '2025-01-01 00:00:00', '2025-01-01 00:00:00');
            SQL
          end
        end

        context "has single quote" do
          let(:results) do
            [
              [1, "Shop' 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [2, "Shop 2", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [3, "Shop 3", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ]
          end

          let(:bulk_insert_sql) { adapter.to_bulk_insert(results, shops_table(adapter_name)) }

          it "returns correct bulk insert sql" do
            expect(bulk_insert_sql.strip).to eq(<<~SQL.strip)
              INSERT INTO shops (id, name, updated_at, created_at) VALUES
              (1, 'Shop'' 1', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
              (2, 'Shop 2', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
              (3, 'Shop 3', '2025-01-01 00:00:00', '2025-01-01 00:00:00');
            SQL
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

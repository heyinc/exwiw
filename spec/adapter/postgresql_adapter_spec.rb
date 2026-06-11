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
          # If pg_dump emits any ADD CONSTRAINT lines, they must be wrapped in DO block
          if sql =~ /ALTER TABLE/i
            expect(sql).to include('DO $exwiw$')
            expect(sql).to include('EXCEPTION WHEN duplicate_object')
          end
          expect(sql).to include('DO $$ BEGIN CREATE EXTENSION IF NOT EXISTS "btree_gist"; EXCEPTION WHEN feature_not_supported THEN NULL; END $$;')
          ext_pos = sql.index("DO $$ BEGIN CREATE EXTENSION")
          table_pos = sql.index("CREATE TABLE")
          expect(ext_pos).to be < table_pos
          expect(ext_pos).to be < sql.index("CREATE TYPE")
          expect(sql).to include('CREATE TYPE')
          expect(sql).to include("AS ENUM ('admin', 'member')")
          enum_match = sql.match(/AS ENUM \(([^)]+)\)/)
          labels = enum_match[1].scan(/'([^']*(?:''[^']*)*)'/).flatten
          expect(labels).to eq(labels.uniq), "enum labels should not be duplicated: #{labels}"
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
            expect(sql).to eq("SELECT users.id, CONCAT('masked', users.id), CONCAT('masked', users.id, '@example.com'), users.shop_id, users.updated_at, users.created_at, users.role FROM users WHERE users.shop_id = 1")
          end
        end

        context "select query with filter" do
          let(:sql) { adapter.compile_ast(build_select_users_ast("users.id > 1")) }

          it "builds sql" do
            expect(sql).to eq("SELECT users.id, CONCAT('masked', users.id), CONCAT('masked', users.id, '@example.com'), users.shop_id, users.updated_at, users.created_at, users.role FROM users WHERE users.shop_id = 1 AND users.id > 1")
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
              ["1", "Shop 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with masking" do
          let(:results) { adapter.execute(build_select_users_ast) }

          it "returns correct results" do
            expect(results).to eq([
              ["1", "masked1", "masked1@example.com", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00", nil],
              ["2", "masked2", "masked2@example.com", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00", nil],
            ])
          end
        end

        context "select query with filter" do
          let(:results) { adapter.execute(build_select_users_ast("users.id > 1")) }

          it "returns correct results" do
            expect(results).to eq([
              ["2", "masked2", "masked2@example.com", "1", "2025-01-01 00:00:00", "2025-01-01 00:00:00", nil],
            ])
          end
        end

        context "select query with one join" do
          let(:results) { adapter.execute(build_order_items_ast) }

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
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", nil)) }

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
          let(:results) { adapter.execute(build_order_items_ast(nil, "orders.id < 6")) }

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
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", "orders.id < 6")) }

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

        context "compile_where_condition with :in_subquery (SelectSubquery) and uuid mismatch" do
          it "casts outer key and inner select column" do
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
            expect(sql).to include("shops.id::text IN (SELECT users.shop_id::text FROM users")
          end
        end

        context "to_bulk_delete with uuid/varchar mismatch" do
          it "casts both sides in the IN clause" do
            allow(adapter).to receive(:column_pg_type).with("order_items", "order_id").and_return('varchar')
            allow(adapter).to receive(:column_pg_type).with("orders", "id").and_return('uuid')

            sql = adapter.to_bulk_delete(build_order_items_ast, order_items_table(adapter_name))
            expect(sql).to include("order_items.order_id::text IN (SELECT orders.id::text FROM orders")
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

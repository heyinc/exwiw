# frozen_string_literal: true

require 'tempfile'

module Exwiw
  module Adapter
    RSpec.describe SqliteAdapter do
      let(:adapter_name) { 'sqlite' }
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
        let(:schema_path) { Tempfile.new(['sqlite_schema', '.sql']).path }

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
            expect(sql).to eq("SELECT users.id, ('masked' || users.id), CASE WHEN users.email IS NOT NULL THEN ('masked' || users.id || '@example.com') ELSE NULL END, users.shop_id, users.updated_at, users.created_at FROM users WHERE users.shop_id = 1")
          end
        end

        context "select query with filter" do
          let(:sql) { adapter.compile_ast(build_select_users_ast("users.id > 1")) }

          it "builds sql" do
            expect(sql).to eq("SELECT users.id, ('masked' || users.id), CASE WHEN users.email IS NOT NULL THEN ('masked' || users.id || '@example.com') ELSE NULL END, users.shop_id, users.updated_at, users.created_at FROM users WHERE users.shop_id = 1 AND users.id > 1")
          end
        end

        context "masking template referencing another column" do
          let(:sql) { adapter.compile_ast(build_select_masked_reference_ast) }

          it "guards on the masked column itself, not the referenced column" do
            expect(sql).to eq("SELECT accounts.id, CASE WHEN accounts.nickname IS NOT NULL THEN ('user-' || accounts.email) ELSE NULL END, accounts.email FROM accounts")
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

        context "select query with a polymorphic join (base_where_clauses)" do
          let(:sql) { adapter.compile_ast(build_comments_polymorphic_join_ast) }

          it "compiles where_clauses against the join table and base_where_clauses against the base table" do
            expect(sql).to eq(
              "SELECT * FROM comments JOIN posts ON comments.commentable_id = posts.id AND posts.user_id = 1 AND comments.commentable_type = 'Post'"
            )
          end
        end
      end

      describe "#commented_sql" do
        it "prefixes the compiled SELECT with an exwiw identifier comment" do
          ast = build_select_shops_ast
          expect(adapter.commented_sql(ast)).to eq(
            "/* exwiw table=shops */ #{adapter.compile_ast(ast)}"
          )
        end

        it "leaves the bare compile_ast output free of comments (subquery/DELETE reuse)" do
          expect(adapter.compile_ast(build_select_shops_ast)).not_to include('exwiw')
        end
      end

      describe "#query_comment_text" do
        it "strips comment terminators to prevent breaking out of the comment" do
          expect(adapter.query_comment_text("table=foo*/DROP")).not_to include('*/')
        end
      end

      describe "#execute" do
        # #execute returns a lazy StreamingResult (cursor-backed); drain it with
        # .to_a to compare the materialized rows.
        context "simple select query" do
          let(:results) { adapter.execute(build_select_shops_ast).to_a }

          it "returns correct results" do
            expect(results).to eq([
              [1, "Shop 1", "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with masking" do
          let(:results) { adapter.execute(build_select_users_ast).to_a }

          it "returns correct results" do
            expect(results).to eq([
              [1, "masked1", "masked1@example.com", 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
              [2, "masked2", "masked2@example.com", 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with filter" do
          let(:results) { adapter.execute(build_select_users_ast("users.id > 1")).to_a }

          it "returns correct results" do
            expect(results).to eq([
              [2, "masked2", "masked2@example.com", 1, "2025-01-01 00:00:00", "2025-01-01 00:00:00"],
            ])
          end
        end

        context "select query with one join" do
          let(:results) { adapter.execute(build_order_items_ast).to_a }

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
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", nil)).to_a }

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
          let(:results) { adapter.execute(build_order_items_ast(nil, "orders.id < 6")).to_a }

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
          let(:results) { adapter.execute(build_order_items_ast("order_items.id > 1", "orders.id < 6")).to_a }

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

      # End-to-end (against a real, isolated sqlite file) proof that masking
      # preserves a NULL source value: a NULL row stays NULL, a non-NULL row is
      # masked. Self-contained so it does not depend on the shared seeded DB
      # (whose masked columns are all NOT NULL).
      describe "NULL-preserving masking" do
        let(:db_path) { Tempfile.new(["null_mask", ".sqlite3"]).path }
        let(:null_connection_config) do
          ConnectionConfig.new(
            adapter: adapter_name,
            database_name: db_path,
            host: nil,
            port: nil,
            user: nil,
            password: nil,
          )
        end
        let(:null_adapter) { described_class.new(null_connection_config, logger) }
        let(:masked_ast) do
          table = Exwiw::TableConfig.from_symbol_keys(
            name: "accounts",
            primary_key: "id",
            belongs_tos: [],
            columns: [{ name: "id" }, { name: "nickname", replace_with: "masked-{id}" }],
          )
          QueryAst::Select.new.tap do |ast|
            ast.from(table.name)
            ast.select(table.columns)
          end
        end

        before do
          db = ::SQLite3::Database.new(db_path)
          db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, nickname TEXT)")
          db.execute("INSERT INTO accounts (id, nickname) VALUES (1, NULL)")
          db.execute("INSERT INTO accounts (id, nickname) VALUES (2, 'Alice')")
          db.close
        end

        it "keeps a NULL source value NULL and masks a non-NULL value" do
          expect(null_adapter.execute(masked_ast).to_a).to eq([
            [1, nil],
            [2, "masked-2"],
          ])
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

        context "select query with a polymorphic join (base_where_clauses)" do
          let(:comments_table) do
            Exwiw::TableConfig.from_symbol_keys(
              name: 'comments',
              primary_key: 'id',
              belongs_tos: [],
              columns: [{ name: 'id' }, { name: 'commentable_type' }, { name: 'commentable_id' }],
            )
          end
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_comments_polymorphic_join_ast, comments_table) }

          it "keeps the polymorphic type filter on the outer delete to avoid deleting other types" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM comments
              WHERE comments.commentable_id IN (SELECT posts.id FROM posts WHERE posts.user_id = 1) AND comments.commentable_type = 'Post';
            SQL
          end
        end
      end
    end
  end
end

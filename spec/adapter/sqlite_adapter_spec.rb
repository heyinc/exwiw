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

        it "writes idempotent CREATE TABLE/INDEX statements for every table in the database" do
          # Full-database dump: the passed tables no longer scope the output, so
          # pass a subset and assert the whole database's DDL is emitted.
          tables = [shops_table(adapter_name), users_table(adapter_name)]
          adapter.dump_schema(tables, schema_path)

          sql = File.read(schema_path)
          expect(sql).to include('CREATE TABLE IF NOT EXISTS "shops"')
          expect(sql).to include('CREATE TABLE IF NOT EXISTS "users"')
          expect(sql).to include('CREATE INDEX IF NOT EXISTS "index_users_on_shop_id"')
          # Tables NOT in the passed subset are still emitted (whole-database dump).
          expect(sql).to include('CREATE TABLE IF NOT EXISTS "products"')
        end

        it "emits every table in sqlite_master (creation) order, independent of the passed subset" do
          # Pass only `users`, yet the whole database is emitted in creation
          # order (shops was created before users in the seed schema).
          tables = [users_table(adapter_name)]
          adapter.dump_schema(tables, schema_path)

          sql = File.read(schema_path)
          expect(sql).to include('CREATE TABLE IF NOT EXISTS "shops"')
          expect(sql).to include('CREATE TABLE IF NOT EXISTS "products"')
          expect(sql.index('CREATE TABLE IF NOT EXISTS "shops"')).to be < sql.index('CREATE TABLE IF NOT EXISTS "users"')
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

        context "select query with a polymorphic multi-arm UNION subquery" do
          let(:sql) { adapter.compile_ast(build_polymorphic_arm_union_ast) }

          it "materializes each arm's join chain into one derived-table JOIN" do
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

      # The reverse_scope id-set is emitted as a JOIN to a materialized
      # (SELECT DISTINCT) derived table; run against the real seed DB to prove
      # it returns the same rows as the pre-fix `<col> IN (subquery)` form.
      describe "scope id-set materialization (derived-table JOIN)" do
        it "returns the same users as the equivalent IN-subquery (result-set equivalence)" do
          ast = build_users_reverse_scope_over_seed_ast
          new_ids = adapter.execute(ast).to_a.map { |row| row.first.to_s }.sort
          old_ids = adapter.send(:connection).execute(users_reverse_scope_over_seed_in_sql).map { |row| row.first.to_s }.sort

          expect(new_ids).not_to be_empty
          expect(new_ids).to eq(old_ids)
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

      # Ruby-side masking against a real sqlite cursor: sqlite yields native
      # Integer ids, so this proves the seed's to_s normalization on real
      # driver output (pg/mysql yield strings; RowTransformer specs cover the
      # equivalence).
      describe "ruby-side masking (RowTransformer over a live cursor)" do
        # Keep the Tempfile object referenced: taking only #path lets GC
        # finalize (unlink) it mid-example, silently replacing the seeded DB
        # with an empty one.
        let(:db_file) { Tempfile.new(["row_transform", ".sqlite3"]) }
        let(:db_path) { db_file.path }
        let(:transform_connection_config) do
          ConnectionConfig.new(
            adapter: adapter_name,
            database_name: db_path,
            host: nil,
            port: nil,
            user: nil,
            password: nil,
          )
        end
        let(:transform_adapter) { described_class.new(transform_connection_config, logger) }
        let(:table) do
          Exwiw::TableConfig.from_symbol_keys(
            name: "accounts",
            primary_key: "id",
            belongs_tos: [],
            columns: [
              { name: "id" },
              { name: "nickname", replace_with_fake_data: { seed: "accounts.id", type: "human_name" } },
              { name: "email", map: 'proc { |r| "user#{r["id"]}@masked.example" }' },
            ],
          )
        end
        let(:ast) do
          QueryAst::Select.new.tap do |select_ast|
            select_ast.from(table.name)
            select_ast.select(table.columns)
          end
        end

        before do
          db = ::SQLite3::Database.new(db_path)
          db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, nickname TEXT, email TEXT)")
          db.execute("INSERT INTO accounts (id, nickname, email) VALUES (1, 'Alice', 'a@example.com')")
          db.execute("INSERT INTO accounts (id, nickname, email) VALUES (2, NULL, 'b@example.com')")
          db.close
        end

        it "transforms streamed rows, matching the value derived from a string seed" do
          transformer = Exwiw::RowTransformer.build(table)
          rows = transformer.wrap(transform_adapter.execute(ast)).to_a

          expected_fake = Exwiw::RowTransformer.build(table).wrap([["1", "Alice", "x"]]).to_a[0][1]
          expect(rows).to eq([
            [1, expected_fake, "user1@masked.example"],
            [2, nil, "user2@masked.example"],
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

      describe "reserved-word identifier quoting" do
        context "select query on a reserved-word table with reserved-word columns" do
          let(:sql) { adapter.compile_ast(build_reserved_word_select_ast) }

          it "double-quotes the reserved identifiers in SELECT, masking and WHERE, leaving safe names bare" do
            expect(sql).to eq(
              %(SELECT "order".id, "order"."from", CASE WHEN "order"."to" IS NOT NULL THEN ('masked-' || "order"."from") ELSE NULL END FROM "order" WHERE "order"."from" = 1)
            )
          end
        end

        context "select query joining a reserved-word table via a reserved-word foreign key" do
          let(:sql) { adapter.compile_ast(build_reserved_word_join_ast) }

          it "double-quotes the reserved identifiers in every JOIN position" do
            expect(sql).to eq(
              %(SELECT "order".id, "order"."from", CASE WHEN "order"."to" IS NOT NULL THEN ('masked-' || "order"."from") ELSE NULL END FROM "order" JOIN "group" ON "order"."references" = "group".id AND "group"."from" = 1)
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

        context "bulk delete scoped by a reserved-word column" do
          let(:bulk_delete_sql) { adapter.to_bulk_delete(build_reserved_word_select_ast, reserved_word_table) }

          it "double-quotes the reserved identifiers in DELETE" do
            expect(bulk_delete_sql.strip).to eq(<<~SQL.strip)
              DELETE FROM "order"
              WHERE "order"."from" = 1;
            SQL
          end
        end

        context "select query with only safe identifiers" do
          let(:sql) { adapter.compile_ast(build_select_shops_ast) }

          it "emits no quotes at all (byte-identical output)" do
            expect(sql).not_to include('"')
          end
        end

        # End-to-end proof (against a real, isolated sqlite file) that the
        # quoted SQL actually parses and round-trips: SELECT with masking,
        # the generated INSERT restored into a fresh database, and DELETE.
        # Unquoted, every one of these statements is a sqlite syntax error.
        describe "against a live database" do
          # Keep the Tempfile objects referenced: taking only #path lets GC
          # finalize (unlink) them mid-example, silently replacing the seeded
          # DB with an empty one.
          let(:source_db_file) { Tempfile.new(["reserved_source", ".sqlite3"]) }
          let(:reserved_ddl) { %(CREATE TABLE "order" (id INTEGER PRIMARY KEY, "from" INTEGER, "to" TEXT)) }
          let(:reserved_adapter) do
            described_class.new(
              ConnectionConfig.new(
                adapter: adapter_name,
                database_name: source_db_file.path,
                host: nil,
                port: nil,
                user: nil,
                password: nil,
              ),
              logger
            )
          end
          let(:extracted_rows) { reserved_adapter.execute(build_reserved_word_select_ast).to_a }

          before do
            db = ::SQLite3::Database.new(source_db_file.path)
            db.execute(reserved_ddl)
            db.execute(%(INSERT INTO "order" (id, "from", "to") VALUES (1, 1, 'x')))
            db.execute(%(INSERT INTO "order" (id, "from", "to") VALUES (2, 2, 'y')))
            db.close
          end

          context "extracting from the reserved-word table" do
            it "returns the scoped row with the reserved columns masked" do
              expect(extracted_rows).to eq([[1, 1, "masked-1"]])
            end
          end

          context "restoring the generated INSERT into a fresh database" do
            let(:restore_db_file) { Tempfile.new(["reserved_restore", ".sqlite3"]) }
            let(:restore_db) { ::SQLite3::Database.new(restore_db_file.path) }

            before do
              restore_db.execute(reserved_ddl)
              restore_db.execute_batch(reserved_adapter.to_bulk_insert(extracted_rows, reserved_word_table))
            end

            after { restore_db.close }

            it "round-trips the extracted rows" do
              expect(restore_db.execute(%(SELECT id, "from", "to" FROM "order"))).to eq([[1, 1, "masked-1"]])
            end
          end

          context "applying the generated DELETE to the source database" do
            before do
              db = ::SQLite3::Database.new(source_db_file.path)
              db.execute_batch(reserved_adapter.to_bulk_delete(build_reserved_word_select_ast, reserved_word_table))
              db.close
            end

            it "removes only the scoped row" do
              db = ::SQLite3::Database.new(source_db_file.path)
              expect(db.execute(%(SELECT id FROM "order"))).to eq([[2]])
              db.close
            end
          end
        end
      end

      # End-to-end proof, against a real sqlite file, that a polymorphic join
      # table scoped through several arms extracts every arm's rows AND nothing
      # from another tenant. Before multi-arm support the same schema produced a
      # single `commentable_type = 'Post'` filter, so the Page-owned comments
      # were silently missing from the dump.
      describe "polymorphic multi-arm scope against a live database" do
        # Keep the Tempfile referenced: taking only #path lets GC finalize
        # (unlink) it mid-example.
        let(:poly_db_file) { Tempfile.new(["poly_arm_source", ".sqlite3"]) }
        let(:poly_adapter) do
          described_class.new(
            ConnectionConfig.new(
              adapter: adapter_name,
              database_name: poly_db_file.path,
              host: nil,
              port: nil,
              user: nil,
              password: nil,
            ),
            logger
          )
        end
        let(:dump_target) { Exwiw::DumpTarget.new(ids: ['t1'], scope_column: 'tenant_id') }
        let(:shops) do
          TableConfig.from_symbol_keys(
            name: 'shops', primary_key: 'id', belongs_tos: [],
            columns: [{ name: 'id' }, { name: 'tenant_id' }]
          )
        end
        let(:posts) do
          TableConfig.from_symbol_keys(
            name: 'posts', primary_key: 'id',
            belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
            columns: [{ name: 'id' }, { name: 'shop_id' }]
          )
        end
        let(:pages) do
          TableConfig.from_symbol_keys(
            name: 'pages', primary_key: 'id',
            belongs_tos: [{ table_name: 'shops', foreign_key: 'shop_id' }],
            columns: [{ name: 'id' }, { name: 'shop_id' }]
          )
        end
        let(:comments) do
          TableConfig.from_symbol_keys(
            name: 'comments', primary_key: 'id',
            belongs_tos: [
              { table_name: 'posts', foreign_key: 'commentable_id',
                foreign_type: 'commentable_type', type_value: 'Post' },
              { table_name: 'pages', foreign_key: 'commentable_id',
                foreign_type: 'commentable_type', type_value: 'Page' },
            ],
            columns: [
              { name: 'id' }, { name: 'commentable_type' },
              { name: 'commentable_id' }, { name: 'body' }
            ]
          )
        end
        let(:table_by_name) do
          [shops, posts, pages, comments].each_with_object({}) { |t, h| h[t.name] = t }
        end
        let(:comments_ast) { QueryAstBuilder.run('comments', table_by_name, dump_target, logger) }

        before do
          db = ::SQLite3::Database.new(poly_db_file.path)
          db.execute_batch(<<~SQL)
            CREATE TABLE shops (id INTEGER PRIMARY KEY, tenant_id TEXT);
            CREATE TABLE posts (id INTEGER PRIMARY KEY, shop_id INTEGER);
            CREATE TABLE pages (id INTEGER PRIMARY KEY, shop_id INTEGER);
            CREATE TABLE comments (id INTEGER PRIMARY KEY, commentable_type TEXT, commentable_id INTEGER, body TEXT);

            INSERT INTO shops VALUES (1, 't1'), (2, 't2');
            INSERT INTO posts VALUES (1, 1), (2, 2);
            INSERT INTO pages VALUES (10, 1), (11, 2);

            -- in scope, one per arm
            INSERT INTO comments VALUES (1, 'Post', 1, 'on t1 post');
            INSERT INTO comments VALUES (2, 'Page', 10, 'on t1 page');
            -- other tenant, one per arm
            INSERT INTO comments VALUES (3, 'Post', 2, 'on t2 post');
            INSERT INTO comments VALUES (4, 'Page', 11, 'on t2 page');
            -- a Post-typed row whose id collides with an in-scope page id: only
            -- the type column tells it apart from comment 2.
            INSERT INTO comments VALUES (5, 'Post', 10, 'dangling');
          SQL
          db.close
        end

        it "extracts every arm's rows" do
          rows = poly_adapter.execute(comments_ast).to_a

          expect(rows.map(&:first)).to eq([1, 2])
          expect(rows.map { |row| row[1] }).to eq(%w[Post Page])
        end

        it "extracts nothing belonging to another tenant" do
          bodies = poly_adapter.execute(comments_ast).to_a.map(&:last)

          expect(bodies).not_to include('on t2 post')
          expect(bodies).not_to include('on t2 page')
        end

        it "does not confuse arms that share a foreign-key value" do
          expect(poly_adapter.execute(comments_ast).to_a.map(&:first)).not_to include(5)
        end

        context "the generated DELETE" do
          before do
            db = ::SQLite3::Database.new(poly_db_file.path)
            db.execute_batch(poly_adapter.to_bulk_delete(comments_ast, comments))
            db.close
          end

          it "removes exactly the rows the extraction keeps" do
            db = ::SQLite3::Database.new(poly_db_file.path)
            expect(db.execute("SELECT id FROM comments ORDER BY id")).to eq([[3], [4], [5]])
            db.close
          end
        end
      end
    end
  end
end

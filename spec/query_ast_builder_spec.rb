# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Exwiw::QueryAstBuilder do
  describe '.run' do
    let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'shops', ids: [1]) }
    let(:all_tables) do
      [
        users_table(:sqlite),
        shops_table(:sqlite),
        products_table(:sqlite),
        orders_table(:sqlite),
        order_items_table(:sqlite),
        transactions_table(:sqlite),
        system_announcements_table(:sqlite),
      ]
    end
    let(:table_by_name) do
      all_tables.each_with_object({}) do |table, hash|
        hash[table.name] = table
      end
    end
    let(:logger) { Logger.new(nil) }
    let(:built_query_ast) { described_class.run(table.name, table_by_name, dump_target, logger) }

    def simply_columns(columns)
      columns.map do |c|
        case c
        when Exwiw::QueryAst::ColumnValue::Plain
          { name: c.name }
        when Exwiw::QueryAst::ColumnValue::ReplaceWith
          { name: c.name, replace_with: c.value }
        when Exwiw::QueryAst::ColumnValue::RawSql
          { name: c.name, raw_sql: c.value }
        end
      end
    end

    context 'when the table is same as dump target table' do
      let(:table) { shops_table(:sqlite) }

      it 'builds correct query ast' do
        expect(built_query_ast.from_table_name).to eq('shops')
        expect(simply_columns(built_query_ast.columns)).to eq([
          { name: 'id' },
          { name: 'name' },
          { name: 'updated_at' },
          { name: 'created_at' },
        ])
        expect(built_query_ast.join_clauses).to eq([])
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
          { column_name: 'id', operator: :eq, value: [1] },
        ])
      end
    end

    context 'when dump_target.ids_field overrides the target table filter column' do
      let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'shops', ids: ['acme'], ids_field: 'name') }
      let(:table) { shops_table(:sqlite) }

      it 'filters the target table on ids_field instead of the primary key' do
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
          { column_name: 'name', operator: :eq, value: ['acme'] },
        ])
      end

      context 'for a table with a foreign key to the dump target' do
        let(:table) { users_table(:sqlite) }

        it 'resolves the foreign key through the target via a subquery' do
          expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
            {
              column_name: 'shop_id',
              operator: :in_subquery,
              value: {
                table_name: 'shops',
                select_column: 'id',
                where_column: 'name',
                where_values: ['acme'],
              },
            },
          ])
        end
      end
    end

    context 'when the table has foreign key to dump target table' do
      let(:table) { users_table(:sqlite) }

      it 'builds correct query ast' do
        expect(built_query_ast.from_table_name).to eq('users')
        expect(simply_columns(built_query_ast.columns)).to eq([
          { name: 'id' },
          { name: 'name', raw_sql: "('masked' || users.id)" },
          { name: 'email', replace_with: 'masked{id}@example.com' },
          { name: 'shop_id' },
          { name: 'updated_at' },
          { name: 'created_at' },
        ])
        expect(built_query_ast.join_clauses.map(&:to_h)).to eq([])
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
          { column_name: 'shop_id', operator: :eq, value: [1] },
        ])
      end
    end

    context 'when the table is N:M relation to dump target table' do
      let(:table) { order_items_table(:sqlite) }

      it 'builds correct query ast' do
        expect(built_query_ast.from_table_name).to eq('order_items')
        expect(simply_columns(built_query_ast.columns)).to eq([
          { name: 'id' },
          { name: 'quantity' },
          { name: 'order_id' },
          { name: 'product_id' },
          { name: 'updated_at' },
          { name: 'created_at' },
        ])
        # Verify join clause includes both the foreign key condition and the filter from orders table
        join_clauses = built_query_ast.join_clauses.map(&:to_h)
        expect(join_clauses.size).to eq(1)
        expect(join_clauses[0][:base_table_name]).to eq('order_items')
        expect(join_clauses[0][:foreign_key]).to eq('order_id')
        expect(join_clauses[0][:join_table_name]).to eq('orders')
        expect(join_clauses[0][:primary_key]).to eq('id')
        # The where_clauses should contain both the shop_id condition and the filter string
        expect(join_clauses[0][:where_clauses].size).to eq(2)
        expect(join_clauses[0][:where_clauses][0]).to eq({ column_name: 'shop_id', operator: :eq, value: [1] })
        expect(join_clauses[0][:where_clauses][1]).to eq('orders.id > 2')
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([])
      end
    end

    context 'when the table is indirect relation with dump target table' do
      let(:table) { transactions_table(:sqlite) }

      it 'builds correct query ast' do
        expect(built_query_ast.from_table_name).to eq('transactions')
        expect(simply_columns(built_query_ast.columns)).to eq([
          { name: 'id' },
          { name: 'type' },
          { name: 'amount' },
          { name: 'order_id' },
          { name: 'updated_at' },
          { name: 'created_at' },
        ])
        # Verify join clause includes both the foreign key condition and the filter from orders table
        join_clauses = built_query_ast.join_clauses.map(&:to_h)
        expect(join_clauses.size).to eq(1)
        expect(join_clauses[0][:base_table_name]).to eq('transactions')
        expect(join_clauses[0][:foreign_key]).to eq('order_id')
        expect(join_clauses[0][:join_table_name]).to eq('orders')
        expect(join_clauses[0][:primary_key]).to eq('id')
        # The where_clauses should contain both the shop_id condition and the filter string
        expect(join_clauses[0][:where_clauses].size).to eq(2)
        expect(join_clauses[0][:where_clauses][0]).to eq({ column_name: 'shop_id', operator: :eq, value: [1] })
        expect(join_clauses[0][:where_clauses][1]).to eq('orders.id > 2')
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([])
      end
    end

    context 'when the table has a polymorphic belongs_to to the dump target table' do
      let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'products', ids: [1]) }
      let(:reviews_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'reviews',
          primary_key: 'id',
          belongs_tos: [
            { table_name: 'users', foreign_key: 'user_id' },
            {
              table_name: 'products',
              foreign_key: 'reviewable_id',
              foreign_type: 'reviewable_type',
              type_value: 'Product',
            },
          ],
          columns: [
            { name: 'id' },
            { name: 'reviewable_type' },
            { name: 'reviewable_id' },
            { name: 'user_id' },
          ],
        )
      end
      let(:all_tables) do
        [
          reviews_table,
          users_table(:sqlite),
          shops_table(:sqlite),
          products_table(:sqlite),
        ]
      end
      let(:table) { reviews_table }

      it 'filters by both the foreign key and the polymorphic type column' do
        expect(built_query_ast.from_table_name).to eq('reviews')
        expect(built_query_ast.join_clauses).to eq([])
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
          { column_name: 'reviewable_id', operator: :eq, value: [1] },
          { column_name: 'reviewable_type', operator: :eq, value: ['Product'] },
        ])
      end
    end

    context 'when the table has polymorphic belongs_tos to multiple targets' do
      # reviews が reviewable として products と shops の両方へ polymorphic に
      # belongs_to するケース。dump target に一致する型だけが絞り込まれ、もう一方
      # の belongs_to (Shop) が products dump に混入しないこと、その逆も確認する。
      let(:reviews_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'reviews',
          primary_key: 'id',
          belongs_tos: [
            { table_name: 'users', foreign_key: 'user_id' },
            {
              table_name: 'products',
              foreign_key: 'reviewable_id',
              foreign_type: 'reviewable_type',
              type_value: 'Product',
            },
            {
              table_name: 'shops',
              foreign_key: 'reviewable_id',
              foreign_type: 'reviewable_type',
              type_value: 'Shop',
            },
          ],
          columns: [
            { name: 'id' },
            { name: 'reviewable_type' },
            { name: 'reviewable_id' },
            { name: 'user_id' },
          ],
        )
      end
      let(:all_tables) do
        [
          reviews_table,
          users_table(:sqlite),
          shops_table(:sqlite),
          products_table(:sqlite),
        ]
      end
      let(:table) { reviews_table }

      context 'when dumping the Product target' do
        let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'products', ids: [1]) }

        it 'filters by the Product type only' do
          expect(built_query_ast.from_table_name).to eq('reviews')
          expect(built_query_ast.join_clauses).to eq([])
          expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
            { column_name: 'reviewable_id', operator: :eq, value: [1] },
            { column_name: 'reviewable_type', operator: :eq, value: ['Product'] },
          ])
        end
      end

      context 'when dumping the Shop target' do
        let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'shops', ids: [1]) }

        it 'filters by the Shop type only' do
          expect(built_query_ast.from_table_name).to eq('reviews')
          expect(built_query_ast.join_clauses).to eq([])
          expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
            { column_name: 'reviewable_id', operator: :eq, value: [1] },
            { column_name: 'reviewable_type', operator: :eq, value: ['Shop'] },
          ])
        end
      end
    end

    context 'when the table joins through an intermediate polymorphic belongs_to to the dump target table' do
      let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'products', ids: [1]) }
      let(:reviews_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'reviews',
          primary_key: 'id',
          belongs_tos: [
            {
              table_name: 'products',
              foreign_key: 'reviewable_id',
              foreign_type: 'reviewable_type',
              type_value: 'Product',
            },
          ],
          columns: [
            { name: 'id' },
            { name: 'reviewable_type' },
            { name: 'reviewable_id' },
          ],
        )
      end
      let(:comments_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'comments',
          primary_key: 'id',
          belongs_tos: [
            { table_name: 'reviews', foreign_key: 'review_id' },
          ],
          columns: [
            { name: 'id' },
            { name: 'review_id' },
          ],
        )
      end
      let(:all_tables) do
        [
          comments_table,
          reviews_table,
          products_table(:sqlite),
        ]
      end
      let(:table) { comments_table }

      it 'adds the polymorphic type filter to the join clause against the intermediate table' do
        expect(built_query_ast.from_table_name).to eq('comments')
        join_clauses = built_query_ast.join_clauses.map(&:to_h)
        expect(join_clauses.size).to eq(1)
        expect(join_clauses[0][:base_table_name]).to eq('comments')
        expect(join_clauses[0][:foreign_key]).to eq('review_id')
        expect(join_clauses[0][:join_table_name]).to eq('reviews')
        expect(join_clauses[0][:primary_key]).to eq('id')
        expect(join_clauses[0][:where_clauses]).to eq([
          { column_name: 'reviewable_id', operator: :eq, value: [1] },
          { column_name: 'reviewable_type', operator: :eq, value: ['Product'] },
        ])
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([])
      end
    end

    context 'when the table itself polymorphically belongs_to an intermediate table on the path' do
      let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'users', ids: [1]) }
      let(:comments_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'comments',
          primary_key: 'id',
          belongs_tos: [
            {
              table_name: 'posts',
              foreign_key: 'commentable_id',
              foreign_type: 'commentable_type',
              type_value: 'Post',
            },
          ],
          columns: [
            { name: 'id' },
            { name: 'commentable_type' },
            { name: 'commentable_id' },
          ],
        )
      end
      let(:posts_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'posts',
          primary_key: 'id',
          belongs_tos: [
            { table_name: 'users', foreign_key: 'user_id' },
          ],
          columns: [
            { name: 'id' },
            { name: 'user_id' },
          ],
        )
      end
      let(:all_tables) do
        [
          comments_table,
          posts_table,
          users_table(:sqlite),
        ]
      end
      let(:table) { comments_table }

      it 'filters the base table by the polymorphic type column via base_where_clauses' do
        expect(built_query_ast.from_table_name).to eq('comments')
        join_clauses = built_query_ast.join_clauses.map(&:to_h)
        expect(join_clauses.size).to eq(1)
        expect(join_clauses[0][:base_table_name]).to eq('comments')
        expect(join_clauses[0][:foreign_key]).to eq('commentable_id')
        expect(join_clauses[0][:join_table_name]).to eq('posts')
        expect(join_clauses[0][:primary_key]).to eq('id')
        # The type column lives on the base table (comments), so it goes to base_where_clauses.
        expect(join_clauses[0][:base_where_clauses]).to eq([
          { column_name: 'commentable_type', operator: :eq, value: ['Post'] },
        ])
        # The regular FK constraint to the dump target lives on the join table (posts).
        expect(join_clauses[0][:where_clauses]).to eq([
          { column_name: 'user_id', operator: :eq, value: [1] },
        ])
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([])
      end
    end

    context 'when the table is referenced by an extractable child but has no relation of its own (ActiveStorage blobs)' do
      # Mirrors ActiveStorage: active_storage_blobs has no belongs_to, but
      # active_storage_attachments.blob_id references it AND attachments are
      # extractable via the polymorphic `record` belongs_to to the dump target.
      # The blobs query should be narrowed to just the referenced blob ids
      # instead of dumping every blob.
      let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'as_users', ids: [1]) }
      let(:blobs_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'active_storage_blobs',
          primary_key: 'id',
          belongs_tos: [],
          columns: [{ name: 'id' }, { name: 'key' }, { name: 'filename' }],
        )
      end
      let(:attachments_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'active_storage_attachments',
          primary_key: 'id',
          belongs_tos: [
            { table_name: 'active_storage_blobs', foreign_key: 'blob_id' },
            {
              table_name: 'as_users',
              foreign_key: 'record_id',
              foreign_type: 'record_type',
              type_value: 'AsUser',
            },
          ],
          columns: [
            { name: 'id' },
            { name: 'name' },
            { name: 'record_type' },
            { name: 'record_id' },
            { name: 'blob_id' },
          ],
        )
      end
      let(:as_users_table) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'as_users',
          primary_key: 'id',
          belongs_tos: [],
          columns: [{ name: 'id' }, { name: 'name' }],
        )
      end
      let(:all_tables) { [blobs_table, attachments_table, as_users_table] }
      let(:table) { blobs_table }

      it 'constrains blobs to the ids referenced by the extracted attachments' do
        expect(built_query_ast.from_table_name).to eq('active_storage_blobs')
        expect(built_query_ast.join_clauses).to eq([])
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
          {
            column_name: 'id',
            operator: :in_subquery,
            value: {
              query: {
                from: 'active_storage_attachments',
                columns: [{ name: 'blob_id', value: 'blob_id' }],
                joins: [],
                where: [
                  { column_name: 'record_id', operator: :eq, value: [1] },
                  { column_name: 'record_type', operator: :eq, value: ['AsUser'] },
                ],
              },
            },
          },
        ])
      end

      it 'compiles to a nested IN-subquery SELECT for SQLite' do
        adapter = Exwiw::Adapter::SqliteAdapter.new(
          Exwiw::ConnectionConfig.new(
            adapter: 'sqlite', database_name: 'tmp/test.sqlite3',
            host: nil, port: nil, user: nil, password: nil
          ),
          logger,
        )

        expect(adapter.compile_ast(built_query_ast)).to eq(
          'SELECT active_storage_blobs.id, active_storage_blobs.key, active_storage_blobs.filename ' \
          'FROM active_storage_blobs ' \
          'WHERE active_storage_blobs.id IN (' \
          'SELECT active_storage_attachments.blob_id FROM active_storage_attachments ' \
          "WHERE active_storage_attachments.record_id = 1 AND active_storage_attachments.record_type = 'AsUser')"
        )
      end

      context 'when the referencer is itself unconstrained (no path to the dump target)' do
        # If active_storage_attachments has no relation to the dump target, it
        # would dump all attachments, so reverse extraction cannot narrow blobs
        # and we fall back to dumping all blobs.
        let(:attachments_table) do
          Exwiw::TableConfig.from_symbol_keys(
            name: 'active_storage_attachments',
            primary_key: 'id',
            belongs_tos: [
              { table_name: 'active_storage_blobs', foreign_key: 'blob_id' },
            ],
            columns: [{ name: 'id' }, { name: 'blob_id' }],
          )
        end

        it 'falls back to dumping all blobs' do
          expect(built_query_ast.where_clauses).to eq([])
          expect(built_query_ast.join_clauses).to eq([])
        end
      end

      context 'when an additional unconstrained referencer exists (active_storage_variant_records)' do
        # Real ActiveStorage also has active_storage_variant_records.blob_id
        # pointing at blobs. On paper that makes blobs a *multi-referencer*
        # table, which the reverse-extraction guards against (multiple
        # referencers would need OR'd subqueries, not yet supported). But
        # variant_records has no path of its own to the dump target, so its
        # child query is unconstrained and filtered out as a candidate. blobs
        # therefore stays a single-referencer case (attachments only) and is
        # still narrowed correctly rather than dumping every blob.
        let(:variant_records_table) do
          Exwiw::TableConfig.from_symbol_keys(
            name: 'active_storage_variant_records',
            primary_key: 'id',
            belongs_tos: [
              { table_name: 'active_storage_blobs', foreign_key: 'blob_id' },
            ],
            columns: [
              { name: 'id' },
              { name: 'blob_id' },
              { name: 'variation_digest' },
            ],
          )
        end
        let(:all_tables) { [blobs_table, attachments_table, variant_records_table, as_users_table] }

        it 'still narrows blobs to the attachments-referenced ids only' do
          expect(built_query_ast.from_table_name).to eq('active_storage_blobs')
          expect(built_query_ast.join_clauses).to eq([])
          expect(built_query_ast.where_clauses.map(&:to_h)).to eq([
            {
              column_name: 'id',
              operator: :in_subquery,
              value: {
                query: {
                  from: 'active_storage_attachments',
                  columns: [{ name: 'blob_id', value: 'blob_id' }],
                  joins: [],
                  where: [
                    { column_name: 'record_id', operator: :eq, value: [1] },
                    { column_name: 'record_type', operator: :eq, value: ['AsUser'] },
                  ],
                },
              },
            },
          ])
        end
      end
    end

    context 'when the table has no relation with dump target table' do
      let(:table) { system_announcements_table(:sqlite) }

      it 'builds correct query ast' do
        expect(built_query_ast.from_table_name).to eq('system_announcements')
        expect(simply_columns(built_query_ast.columns)).to eq([
          { name: 'id' },
          { name: 'title' },
          { name: 'content' },
          { name: 'updated_at' },
          { name: 'created_at' },
        ])
        expect(built_query_ast.join_clauses).to eq([])
        expect(built_query_ast.where_clauses.map(&:to_h)).to eq([])
      end
    end
  end

  describe 'scope-column mode' do
    let(:logger) { Logger.new(nil) }
    # Filter every table by a shared `tenant_id`, values = ['t1']. No single
    # --target-table anchor.
    let(:dump_target) { Exwiw::DumpTarget.new(ids: ['t1'], scope_column: 'tenant_id') }

    # A top-level table that carries the scope column itself.
    let(:orders) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'orders', primary_key: 'id', belongs_tos: [],
        columns: [{ name: 'id' }, { name: 'tenant_id' }, { name: 'total' }]
      )
    end
    # A child that lacks the scope column; reachable via belongs_to to `orders`.
    let(:order_items) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'order_items', primary_key: 'id',
        belongs_tos: [{ table_name: 'orders', foreign_key: 'order_id' }],
        columns: [{ name: 'id' }, { name: 'order_id' }, { name: 'quantity' }]
      )
    end
    # A reference/master table with no scope linkage, intentionally full-dumped.
    let(:countries) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'countries', primary_key: 'id', scope_exempt: true, belongs_tos: [],
        columns: [{ name: 'id' }, { name: 'code' }]
      )
    end
    # Same scope value, but stored under a differently named column.
    let(:legacy_orders) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'legacy_orders', primary_key: 'id', scope_column: 'legacy_tenant', belongs_tos: [],
        columns: [{ name: 'id' }, { name: 'legacy_tenant' }, { name: 'amount' }]
      )
    end
    # No scope column, no belongs_to path to one: unscopable.
    let(:widgets) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'widgets', primary_key: 'id', belongs_tos: [],
        columns: [{ name: 'id' }, { name: 'name' }]
      )
    end
    let(:schema_migrations) do
      Exwiw::TableConfig.from_symbol_keys(name: 'schema_migrations', type: 'rails_managed_schema_migrations')
    end

    let(:all_tables) { [orders, order_items, countries, legacy_orders, widgets, schema_migrations] }
    let(:table_by_name) { all_tables.each_with_object({}) { |t, h| h[t.name] = t } }

    def build(name)
      described_class.run(name, table_by_name, dump_target, logger)
    end

    context 'a table that carries the scope column directly' do
      it 'filters by the scope column' do
        ast = build('orders')
        expect(ast.from_table_name).to eq('orders')
        expect(ast.join_clauses).to eq([])
        expect(ast.where_clauses.map(&:to_h)).to eq([
          { column_name: 'tenant_id', operator: :eq, value: ['t1'] },
        ])
      end

      it 'compiles to a WHERE on the scope column (sqlite)' do
        expect(sqlite_adapter.compile_ast(build('orders'))).to eq(
          "SELECT orders.id, orders.tenant_id, orders.total FROM orders WHERE orders.tenant_id = 't1'"
        )
      end
    end

    context 'a child reached via belongs_to to a scoped table' do
      it 'joins up to the scoped ancestor and filters there' do
        ast = build('order_items')
        expect(ast.from_table_name).to eq('order_items')
        joins = ast.join_clauses.map(&:to_h)
        expect(joins.size).to eq(1)
        expect(joins[0][:base_table_name]).to eq('order_items')
        expect(joins[0][:foreign_key]).to eq('order_id')
        expect(joins[0][:join_table_name]).to eq('orders')
        expect(joins[0][:primary_key]).to eq('id')
        expect(joins[0][:where_clauses]).to eq([
          { column_name: 'tenant_id', operator: :eq, value: ['t1'] },
        ])
        expect(ast.where_clauses).to eq([])
      end

      it 'compiles to a JOIN ending in the scope filter (sqlite)' do
        expect(sqlite_adapter.compile_ast(build('order_items'))).to eq(
          'SELECT order_items.id, order_items.order_id, order_items.quantity FROM order_items ' \
          "JOIN orders ON order_items.order_id = orders.id AND orders.tenant_id = 't1'"
        )
      end
    end

    context 'a table with a per-table scope_column override' do
      it 'filters on the overridden column name' do
        ast = build('legacy_orders')
        expect(ast.join_clauses).to eq([])
        expect(ast.where_clauses.map(&:to_h)).to eq([
          { column_name: 'legacy_tenant', operator: :eq, value: ['t1'] },
        ])
      end
    end

    context 'a scope_exempt reference table' do
      it 'is exported in full with no scope filter' do
        ast = build('countries')
        expect(ast.select_all).to eq(false)
        expect(ast.join_clauses).to eq([])
        expect(ast.where_clauses).to eq([])
      end
    end

    context 'a rails-managed table' do
      it 'is exported in full (treated as exempt)' do
        ast = build('schema_migrations')
        expect(ast.select_all).to eq(true)
        expect(ast.join_clauses).to eq([])
        expect(ast.where_clauses).to eq([])
      end
    end

    context 'an unscopable table built at top level' do
      it 'raises rather than emitting an unfiltered dump' do
        expect { build('widgets') }.to raise_error(ArgumentError, /cannot be scoped/)
      end
    end

    context 'a child whose belongs_to parent is itself scoped only via referenced_by' do
      # Mirrors CDP: `accounts` carries no scope column and has no belongs_to, but
      # `customers` references it AND carries tenant_id, so accounts is scoped via
      # referenced_by. `account_details` is a sibling under the same hub — it has
      # no scope column and no path to one, yet should be constrained to the
      # in-scope accounts rather than dumped in full.
      let(:accounts) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'accounts', primary_key: 'id', belongs_tos: [],
          columns: [{ name: 'id' }, { name: 'uuid' }]
        )
      end
      let(:customers) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'customers', primary_key: 'id',
          belongs_tos: [{ table_name: 'accounts', foreign_key: 'account_id' }],
          columns: [{ name: 'id' }, { name: 'account_id' }, { name: 'tenant_id' }]
        )
      end
      let(:account_details) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'account_details', primary_key: 'id',
          belongs_tos: [{ table_name: 'accounts', foreign_key: 'account_id' }],
          columns: [{ name: 'id' }, { name: 'account_id' }, { name: 'secret' }]
        )
      end
      let(:all_tables) { [accounts, customers, account_details, schema_migrations] }

      it 'classifies the sibling as :via_scoped_parent' do
        expect(described_class.scope_category('account_details', table_by_name, dump_target, logger)).to eq(:via_scoped_parent)
      end

      it 'constrains it to parent ids that are themselves in scope' do
        ast = build('account_details')
        expect(ast.from_table_name).to eq('account_details')
        expect(ast.join_clauses).to eq([])
        expect(ast.where_clauses.map(&:to_h)).to eq([
          {
            column_name: 'account_id',
            operator: :in_subquery,
            value: {
              query: {
                from: 'accounts',
                columns: [{ name: 'id', value: 'id' }],
                joins: [],
                where: [
                  {
                    column_name: 'id',
                    operator: :in_subquery,
                    value: {
                      query: {
                        from: 'customers',
                        columns: [{ name: 'account_id', value: 'account_id' }],
                        joins: [],
                        where: [{ column_name: 'tenant_id', operator: :eq, value: ['t1'] }],
                      },
                    },
                  },
                ],
              },
            },
          },
        ])
      end

      it 'compiles to a nested IN-subquery (sqlite)' do
        expect(sqlite_adapter.compile_ast(build('account_details'))).to eq(
          'SELECT account_details.id, account_details.account_id, account_details.secret FROM account_details ' \
          'WHERE account_details.account_id IN (' \
          'SELECT accounts.id FROM accounts WHERE accounts.id IN (' \
          "SELECT customers.account_id FROM customers WHERE customers.tenant_id = 't1'))"
        )
      end

      it 'passes validate_scope! (the sibling is no longer unscopable)' do
        expect {
          described_class.validate_scope!(all_tables, table_by_name, dump_target, logger)
        }.not_to raise_error
      end
    end

    describe '.validate_scope!' do
      it 'raises listing the unscopable table(s)' do
        expect {
          described_class.validate_scope!(all_tables, table_by_name, dump_target, logger)
        }.to raise_error(ArgumentError, /widgets/)
      end

      it 'passes once the unscopable table is marked ignore:true' do
        widgets.ignore = true
        expect {
          described_class.validate_scope!(all_tables, table_by_name, dump_target, logger)
        }.not_to raise_error
      end

      it 'passes once the unscopable table is marked scope_exempt:true' do
        widgets.scope_exempt = true
        expect {
          described_class.validate_scope!(all_tables, table_by_name, dump_target, logger)
        }.not_to raise_error
      end

      it 'is a no-op outside scope-column mode' do
        target_mode = Exwiw::DumpTarget.new(table_name: 'orders', ids: ['t1'])
        expect {
          described_class.validate_scope!(all_tables, table_by_name, target_mode, logger)
        }.not_to raise_error
      end
    end

    # The preferred trigger: no --scope-column flag, but the named --target-table
    # declares a per-table scope_column, so the run is scope-column mode and the
    # target's --ids are scope values rather than primary keys.
    context 'scope-column mode triggered by a target that declares scope_column' do
      # legacy_orders declares scope_column: 'legacy_tenant'.
      let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'legacy_orders', ids: ['t1']) }

      it 'reports scope_mode? for the declaring target' do
        expect(described_class.scope_mode?(table_by_name, dump_target)).to eq(true)
      end

      it 'scopes the target by its own scope_column, not by its primary key' do
        ast = build('legacy_orders')
        expect(ast.join_clauses).to eq([])
        expect(ast.where_clauses.map(&:to_h)).to eq([
          { column_name: 'legacy_tenant', operator: :eq, value: ['t1'] },
        ])
      end

      it 'still triggers validate_scope! so an unscopable table aborts' do
        expect {
          described_class.validate_scope!(all_tables, table_by_name, dump_target, logger)
        }.to raise_error(ArgumentError, /widgets/)
      end

      it 'is plain target mode when the target declares no scope_column' do
        # orders carries a tenant_id column but does not *declare* scope_column.
        target_mode = Exwiw::DumpTarget.new(table_name: 'orders', ids: ['1'])
        expect(described_class.scope_mode?(table_by_name, target_mode)).to eq(false)
      end
    end

    def sqlite_adapter
      Exwiw::Adapter::SqliteAdapter.new(
        Exwiw::ConnectionConfig.new(
          adapter: 'sqlite', database_name: 'tmp/test.sqlite3',
          host: nil, port: nil, user: nil, password: nil
        ),
        logger,
      )
    end
  end

  describe 'multi-referencer reverse scope (reverse_scope.via)' do
    # A global-identity table (`users`) that carries no scope column and has no
    # belongs_to of its own is referenced by several scoped tables. With two or
    # more referencers the automatic single-referencer reverse extraction bails
    # to a full dump; `reverse_scope.via` instead UNIONs each referencer's
    # scoped query into the id set `users` is constrained to.
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:dump_target) { Exwiw::DumpTarget.new(ids: ['be1'], scope_column: 'business_entity_id') }

    let(:users) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'users', primary_key: 'id', belongs_tos: [],
        reverse_scope: { via: reverse_scope_via },
        columns: [{ name: 'id' }, { name: 'name' }]
      )
    end
    let(:reverse_scope_via) do
      [
        { table: 'customers', column: 'user_id' },
        { table: 'staff', column: 'user_id' },
      ]
    end
    # Two directly-scoped referencers that point at users via a non-default and
    # a default foreign key respectively.
    let(:customers) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'customers', primary_key: 'id',
        belongs_tos: [{ table_name: 'users', foreign_key: 'user_id' }],
        columns: [{ name: 'id' }, { name: 'business_entity_id' }, { name: 'user_id' }]
      )
    end
    let(:staff) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'staff', primary_key: 'id',
        belongs_tos: [{ table_name: 'users', foreign_key: 'user_id' }],
        columns: [{ name: 'id' }, { name: 'business_entity_id' }, { name: 'user_id' }]
      )
    end
    # A satellite whose own primary key references users.id (end_users.id ==
    # users.id): it carries no scope column and needs NO reverse_scope of its
    # own — it tightens to the kept users via the via_scoped_parent cascade.
    let(:end_users) do
      Exwiw::TableConfig.from_symbol_keys(
        name: 'end_users', primary_key: 'id',
        belongs_tos: [{ table_name: 'users', foreign_key: 'id' }],
        columns: [{ name: 'id' }, { name: 'nickname' }]
      )
    end
    let(:schema_migrations) do
      Exwiw::TableConfig.from_symbol_keys(name: 'schema_migrations', type: 'rails_managed_schema_migrations')
    end
    let(:all_tables) { [users, customers, staff, end_users, schema_migrations] }
    let(:table_by_name) { all_tables.each_with_object({}) { |t, h| h[t.name] = t } }

    def build(name)
      described_class.run(name, table_by_name, dump_target, logger)
    end

    it 'constrains users to the UNION of every via referencer, excluding NULLs' do
      ast = build('users')
      expect(ast.from_table_name).to eq('users')
      expect(ast.join_clauses).to eq([])
      expect(ast.where_clauses.map(&:to_h)).to eq([
        {
          column_name: 'id',
          operator: :in_subquery,
          value: {
            union: [
              {
                from: 'customers',
                columns: [{ name: 'user_id', value: 'user_id' }],
                joins: [],
                where: [
                  { column_name: 'business_entity_id', operator: :eq, value: ['be1'] },
                  { column_name: 'user_id', operator: :not_null, value: nil },
                ],
              },
              {
                from: 'staff',
                columns: [{ name: 'user_id', value: 'user_id' }],
                joins: [],
                where: [
                  { column_name: 'business_entity_id', operator: :eq, value: ['be1'] },
                  { column_name: 'user_id', operator: :not_null, value: nil },
                ],
              },
            ],
          },
        },
      ])
    end

    it 'compiles users to IN (… UNION …) (sqlite)' do
      expect(sqlite_adapter.compile_ast(build('users'))).to eq(
        'SELECT users.id, users.name FROM users WHERE users.id IN (' \
        "SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 'be1' AND customers.user_id IS NOT NULL " \
        'UNION ' \
        "SELECT staff.user_id FROM staff WHERE staff.business_entity_id = 'be1' AND staff.user_id IS NOT NULL)"
      )
    end

    it 'classifies users as :referenced_by and passes validate_scope!' do
      expect(described_class.scope_category('users', table_by_name, dump_target, logger)).to eq(:referenced_by)
      expect {
        described_class.validate_scope!(all_tables, table_by_name, dump_target, logger)
      }.not_to raise_error
    end

    it 'cascades to a satellite that belongs_to users, with no config of its own' do
      expect(sqlite_adapter.compile_ast(build('end_users'))).to eq(
        'SELECT end_users.id, end_users.nickname FROM end_users WHERE end_users.id IN (' \
        'SELECT users.id FROM users WHERE users.id IN (' \
        "SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 'be1' AND customers.user_id IS NOT NULL " \
        'UNION ' \
        "SELECT staff.user_id FROM staff WHERE staff.business_entity_id = 'be1' AND staff.user_id IS NOT NULL))"
      )
    end

    context 'when a via arm references an unknown table' do
      let(:reverse_scope_via) do
        [
          { table: 'customers', column: 'user_id' },
          { table: 'ghosts', column: 'user_id' },
        ]
      end

      it 'skips the unknown arm with a warning and unions the rest' do
        expect(sqlite_adapter.compile_ast(build('users'))).to eq(
          'SELECT users.id, users.name FROM users WHERE users.id IN (' \
          "SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 'be1' AND customers.user_id IS NOT NULL)"
        )
        expect(log_output.string).to include("references unknown table 'ghosts'")
      end
    end

    context 'when a via arm references a table that is not scoped (would union all rows back)' do
      # `audit_logs` is scope_exempt (intentional full dump), so its scoped query
      # is unconstrained — including it would project every user_id and defeat
      # the prune. The arm must be dropped, not silently widen the dump.
      let(:audit_logs) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'audit_logs', primary_key: 'id', scope_exempt: true, belongs_tos: [],
          columns: [{ name: 'id' }, { name: 'user_id' }]
        )
      end
      let(:all_tables) { [users, customers, staff, end_users, audit_logs, schema_migrations] }
      let(:reverse_scope_via) do
        [
          { table: 'customers', column: 'user_id' },
          { table: 'audit_logs', column: 'user_id' },
        ]
      end

      it 'skips the unconstrained arm with a warning and unions the rest' do
        expect(sqlite_adapter.compile_ast(build('users'))).to eq(
          'SELECT users.id, users.name FROM users WHERE users.id IN (' \
          "SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 'be1' AND customers.user_id IS NOT NULL)"
        )
        expect(log_output.string).to include("arm 'audit_logs.user_id' is not scoped")
      end
    end

    context 'when every via arm is dropped' do
      let(:reverse_scope_via) { [{ table: 'ghosts', column: 'user_id' }] }

      it 'leaves users unscopable so the top-level build raises' do
        expect { build('users') }.to raise_error(ArgumentError, /cannot be scoped/)
      end
    end

    context 'when a via referencer is scoped through a JOIN (via_path)' do
      # `reservations` carries no scope column; it reaches the scope through
      # belongs_to shops, which does. The arm must carry that JOIN and apply the
      # scope filter on the joined ancestor.
      let(:reverse_scope_via) { [{ table: 'reservations', column: 'user_id' }] }
      let(:reservations) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'reservations', primary_key: 'id',
          belongs_tos: [
            { table_name: 'shops', foreign_key: 'shop_id' },
            { table_name: 'users', foreign_key: 'user_id' },
          ],
          columns: [{ name: 'id' }, { name: 'shop_id' }, { name: 'user_id' }]
        )
      end
      let(:shops) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'shops', primary_key: 'id', belongs_tos: [],
          columns: [{ name: 'id' }, { name: 'business_entity_id' }]
        )
      end
      let(:all_tables) { [users, reservations, shops, schema_migrations] }

      it 'projects the arm with its JOIN to the scoped ancestor' do
        expect(sqlite_adapter.compile_ast(build('users'))).to eq(
          'SELECT users.id, users.name FROM users WHERE users.id IN (' \
          'SELECT reservations.user_id FROM reservations ' \
          "JOIN shops ON reservations.shop_id = shops.id AND shops.business_entity_id = 'be1' " \
          'WHERE reservations.user_id IS NOT NULL)'
        )
      end
    end

    context 'when a via referencer carries a filter' do
      # The referencer's own filter (e.g. a soft-delete guard) rides along in the
      # arm, with the appended IS NOT NULL last.
      let(:reverse_scope_via) { [{ table: 'customers', column: 'user_id' }] }
      let(:customers) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'customers', primary_key: 'id', filter: 'customers.deleted_at IS NULL',
          belongs_tos: [{ table_name: 'users', foreign_key: 'user_id' }],
          columns: [{ name: 'id' }, { name: 'business_entity_id' }, { name: 'user_id' }]
        )
      end
      let(:all_tables) { [users, customers, schema_migrations] }

      it 'keeps the referencer filter, with IS NOT NULL appended last' do
        expect(sqlite_adapter.compile_ast(build('users'))).to eq(
          'SELECT users.id, users.name FROM users WHERE users.id IN (' \
          "SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 'be1' " \
          'AND customers.deleted_at IS NULL AND customers.user_id IS NOT NULL)'
        )
      end
    end

    context 'in single-target mode' do
      # reverse_scope also works when anchoring on a named target rather than a
      # scope column: each arm reuses the referencer's target-scoped query.
      let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'business_entities', ids: [1]) }
      let(:customers) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'customers', primary_key: 'id',
          belongs_tos: [
            { table_name: 'users', foreign_key: 'user_id' },
            { table_name: 'business_entities', foreign_key: 'business_entity_id' },
          ],
          columns: [{ name: 'id' }, { name: 'business_entity_id' }, { name: 'user_id' }]
        )
      end
      let(:staff) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'staff', primary_key: 'id',
          belongs_tos: [
            { table_name: 'users', foreign_key: 'user_id' },
            { table_name: 'business_entities', foreign_key: 'business_entity_id' },
          ],
          columns: [{ name: 'id' }, { name: 'business_entity_id' }, { name: 'user_id' }]
        )
      end
      let(:business_entities) do
        Exwiw::TableConfig.from_symbol_keys(
          name: 'business_entities', primary_key: 'id', belongs_tos: [],
          columns: [{ name: 'id' }, { name: 'name' }]
        )
      end
      let(:all_tables) { [users, customers, staff, business_entities] }

      it 'unions each referencer constrained by the foreign key to the target' do
        expect(sqlite_adapter.compile_ast(build('users'))).to eq(
          'SELECT users.id, users.name FROM users WHERE users.id IN (' \
          'SELECT customers.user_id FROM customers WHERE customers.business_entity_id = 1 AND customers.user_id IS NOT NULL ' \
          'UNION ' \
          'SELECT staff.user_id FROM staff WHERE staff.business_entity_id = 1 AND staff.user_id IS NOT NULL)'
        )
      end
    end

    def sqlite_adapter
      Exwiw::Adapter::SqliteAdapter.new(
        Exwiw::ConnectionConfig.new(
          adapter: 'sqlite', database_name: 'tmp/test.sqlite3',
          host: nil, port: nil, user: nil, password: nil
        ),
        logger,
      )
    end
  end
end

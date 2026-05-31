# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Exwiw::QueryAstBuilder do
  describe '.run' do
    let(:dump_target) { Exwiw::DumpTarget.new(table_name: 'shops', ids: [1]) }
    let(:all_tables) do
      [
        users_table(:sqlite3),
        shops_table(:sqlite3),
        products_table(:sqlite3),
        orders_table(:sqlite3),
        order_items_table(:sqlite3),
        transactions_table(:sqlite3),
        system_announcements_table(:sqlite3),
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
      let(:table) { shops_table(:sqlite3) }

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

    context 'when the table has foreign key to dump target table' do
      let(:table) { users_table(:sqlite3) }

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
      let(:table) { order_items_table(:sqlite3) }

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
      let(:table) { transactions_table(:sqlite3) }

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
          users_table(:sqlite3),
          shops_table(:sqlite3),
          products_table(:sqlite3),
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
          users_table(:sqlite3),
          shops_table(:sqlite3),
          products_table(:sqlite3),
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
          products_table(:sqlite3),
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
          users_table(:sqlite3),
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

    context 'when the table has no relation with dump target table' do
      let(:table) { system_announcements_table(:sqlite3) }

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
end

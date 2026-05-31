# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Exwiw::DetermineTableProcessingOrder do
  describe '.run' do
    let(:target_table_name) { 'shops' }
    let(:target_ids) { [1] }

    let(:sorted_table_names) { described_class.run(tables) }


    context 'when there are only shops' do
      let(:tables) do
        [shops_table(:sqlite3)]
      end

      it 'returns shops' do
        expect(sorted_table_names).to eq(['shops'])
      end
    end

    context 'when there are independent' do
      let(:tables) do
        [
          system_announcements_table(:sqlite3),
          shops_table(:sqlite3),
        ]
      end

      it 'returns ordered names' do
        expect(sorted_table_names).to eq(['system_announcements', 'shops'])
      end
    end

    context 'when there are just belongs_to' do
      let(:tables) do
        [
          orders_table(:sqlite3),
          users_table(:sqlite3),
          products_table(:sqlite3),
          system_announcements_table(:sqlite3),
          shops_table(:sqlite3),
        ]
      end

      it 'returns ordered names' do
        expect(sorted_table_names).to eq([
          'system_announcements',
          'shops',
          'users',
          'products',
          'orders',
        ])
      end
    end

    context 'when there are belongs_to, n:m' do
      let(:tables) do
        [
          order_items_table(:sqlite3),
          orders_table(:sqlite3),
          users_table(:sqlite3),
          products_table(:sqlite3),
          shops_table(:sqlite3),
        ]
      end

      it 'returns ordered names' do
        expect(sorted_table_names).to eq([
          'shops',
          'users',
          'products',
          'orders',
          'order_items',
        ])
      end
    end

    context 'when there is polymorphic' do
      # No scenario/sqlite3-schema/reviews.json fixture exists on purpose (it would
      # be consumed by the full-dump snapshot specs), so the polymorphic reviews
      # config is built inline. The polymorphic belongs_to is expanded into one
      # regular table_name dependency per target (here products), exactly as
      # schema:generate emits it.
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

      let(:tables) do
        [
          users_table(:sqlite3),
          products_table(:sqlite3),
          reviews_table,
          shops_table(:sqlite3),
        ]
      end

      it 'returns ordered names' do
        expect(sorted_table_names).to eq([
          'shops',
          'users',
          'products',
          'reviews',
        ])
      end
    end

    context 'when there is sti' do
      let(:tables) do
        [
          transactions_table(:sqlite3),
          orders_table(:sqlite3),
          users_table(:sqlite3),
          products_table(:sqlite3),
          shops_table(:sqlite3),
        ]
      end

      it 'returns ordered names' do
        expect(sorted_table_names).to eq([
          'shops',
          'users',
          'products',
          'orders',
          'transactions',
        ])
      end
    end

    context 'when full tables' do
      let(:tables) do
        [
          order_items_table(:sqlite3),
          transactions_table(:sqlite3),
          orders_table(:sqlite3),
          users_table(:sqlite3),
          products_table(:sqlite3),
          system_announcements_table(:sqlite3),
          shops_table(:sqlite3),
        ]
      end

      it 'returns ordered names' do
        expect(sorted_table_names).to eq([
          'system_announcements',
          'shops',
          'users',
          'products',
          'orders',
          'order_items',
          'transactions',
        ])
      end
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Exwiw::DetermineTableProcessingOrder do
  describe '.run' do
    let(:target_table_name) { 'shops' }
    let(:target_ids) { [1] }

    let(:sorted_table_names) { described_class.run(tables) }


    context 'when there are only shops' do
      let(:tables) do
        [shops_table(:sqlite)]
      end

      it 'returns shops' do
        expect(sorted_table_names).to eq(['shops'])
      end
    end

    context 'when there are independent' do
      let(:tables) do
        [
          system_announcements_table(:sqlite),
          shops_table(:sqlite),
        ]
      end

      it 'returns ordered names' do
        expect(sorted_table_names).to eq(['system_announcements', 'shops'])
      end
    end

    context 'when there are just belongs_to' do
      let(:tables) do
        [
          orders_table(:sqlite),
          users_table(:sqlite),
          products_table(:sqlite),
          system_announcements_table(:sqlite),
          shops_table(:sqlite),
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
          order_items_table(:sqlite),
          orders_table(:sqlite),
          users_table(:sqlite),
          products_table(:sqlite),
          shops_table(:sqlite),
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
      # No e2e/sqlite-schema/reviews.json fixture exists on purpose (it would
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
          users_table(:sqlite),
          products_table(:sqlite),
          reviews_table,
          shops_table(:sqlite),
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
          transactions_table(:sqlite),
          orders_table(:sqlite),
          users_table(:sqlite),
          products_table(:sqlite),
          shops_table(:sqlite),
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

    context 'when there is a circular belongs_to dependency' do
      let(:tables) do
        [
          Exwiw::TableConfig.from_symbol_keys(
            name: 'binders',
            primary_key: 'id',
            belongs_tos: [{ table_name: 'responses', foreign_key: 'response_id' }],
            columns: [{ name: 'id' }, { name: 'response_id' }],
          ),
          Exwiw::TableConfig.from_symbol_keys(
            name: 'responses',
            primary_key: 'id',
            belongs_tos: [{ table_name: 'binders', foreign_key: 'binder_id' }],
            columns: [{ name: 'id' }, { name: 'binder_id' }],
          ),
        ]
      end

      it 'breaks the cycle deterministically instead of raising' do
        expect { sorted_table_names }.not_to raise_error
        # Both tables are emitted; ties are broken by name, so the
        # lexicographically smaller one is chosen as the break point and ordered
        # first.
        expect(sorted_table_names).to eq(%w[binders responses])
      end

      it 'warns about the broken cycle when a logger is given' do
        logger = spy('logger')
        described_class.run(tables, logger: logger)
        expect(logger).to have_received(:warn).with(/Circular belongs_to dependency/).at_least(:once)
      end
    end

    context 'when a belongs_to targets a table outside the set' do
      # e.g. an embedded MongoDB collection (masked through its parent, never
      # dumped on its own). The dependency must neither block ordering nor be
      # mistaken for a circular dependency.
      let(:tables) do
        [
          Exwiw::TableConfig.from_symbol_keys(
            name: 'orders',
            primary_key: 'id',
            belongs_tos: [
              { table_name: 'shops', foreign_key: 'shop_id' },
              { table_name: 'coupon_coupons', foreign_key: 'coupon_id' }, # not in the set
            ],
            columns: [{ name: 'id' }, { name: 'shop_id' }, { name: 'coupon_id' }],
          ),
          shops_table(:sqlite),
        ]
      end

      it 'ignores the out-of-set dependency and orders the remaining tables' do
        expect(sorted_table_names).to eq(%w[shops orders])
      end
    end

    context 'when a cycle is surrounded by acyclic tables' do
      # Mirrors the rt-rails shape: chargebacks <-> remittances_items <->
      # deduction_requests form a 3-node cycle; each also belongs_to out-of-cycle
      # parents (stores, orders) that resolve normally, and refund_to_purchasers
      # is acyclic but depends on the cycle.
      def node(name, deps)
        Exwiw::TableConfig.from_symbol_keys(
          name: name,
          primary_key: 'id',
          belongs_tos: deps.map { |d| { table_name: d, foreign_key: "#{d}_id" } },
          columns: [{ name: 'id' }] + deps.map { |d| { name: "#{d}_id" } },
        )
      end

      let(:tables) do
        [
          node('stores', []),
          node('orders', %w[stores]),
          node('chargebacks', %w[orders stores remittances_items]),
          node('deduction_requests', %w[stores orders remittances_items]),
          node('remittances_items', %w[stores chargebacks deduction_requests]),
          node('refund_to_purchasers', %w[orders deduction_requests remittances_items]),
        ]
      end

      it 'breaks only the cycle and keeps acyclic tables after their parents' do
        order = sorted_table_names

        expect(order).to contain_exactly(
          'stores', 'orders', 'chargebacks', 'deduction_requests', 'remittances_items', 'refund_to_purchasers'
        )
        # The acyclic dependent is never reordered ahead of its (cycle-member) parents.
        expect(order.index('refund_to_purchasers')).to be > order.index('deduction_requests')
        expect(order.index('refund_to_purchasers')).to be > order.index('remittances_items')
        # The cycle hub is emitted after its in-cycle parents.
        expect(order.index('remittances_items')).to be > order.index('chargebacks')
        expect(order.index('remittances_items')).to be > order.index('deduction_requests')
      end

      it 'produces the same order regardless of input order' do
        expect(described_class.run(tables)).to eq(described_class.run(tables.reverse))
      end
    end

    context 'with runtime_reverse_scope (mongodb)' do
      # Generic reverse-scope shape: `accounts` is a global-identity collection
      # referenced by two organization-scoped collections. In runtime mode the
      # adapter needs the referencers' captured ids BEFORE accounts is dumped,
      # so the reverse_scope arms become ordering dependencies — and an arm's
      # own belongs_to back to the reverse-scoped collection is inverted rather
      # than kept.
      def collection(name, deps: [], reverse_via: nil)
        Exwiw::MongodbCollectionConfig.from_symbol_keys(
          name: name,
          primary_key: '_id',
          belongs_tos: deps.map { |d| { table_name: d, foreign_key: "#{d}_id" } },
          fields: [{ name: '_id' }] + deps.map { |d| { name: "#{d}_id" } },
          **(reverse_via ? { reverse_scope: { via: reverse_via } } : {}),
        )
      end

      let(:organizations) { collection('organizations') }
      let(:articles) { collection('articles', deps: %w[organizations accounts]) }
      let(:invitations) { collection('invitations', deps: %w[organizations]) }
      let(:accounts) do
        collection('accounts', reverse_via: [
          { table: 'articles', column: 'accounts_id' },
          { table: 'invitations', column: 'invitee_account_id' },
        ])
      end
      let(:account_profiles) { collection('account_profiles', deps: %w[accounts]) }

      let(:tables) { [accounts, account_profiles, organizations, articles, invitations] }

      it 'orders the reverse-scoped collection after all of its via referencers' do
        order = described_class.run(tables, runtime_reverse_scope: true)

        expect(order).to contain_exactly(*%w[organizations articles invitations accounts account_profiles])
        expect(order.index('accounts')).to be > order.index('articles')
        expect(order.index('accounts')).to be > order.index('invitations')
        # articles belongs_to accounts, but that edge is inverted by the arm —
        # while the non-arm satellite still comes after the reverse-scoped
        # collection, so its filter can use the captured accounts ids.
        expect(order.index('account_profiles')).to be > order.index('accounts')
      end

      it 'keeps the historical belongs_to-only order by default (SQL adapters)' do
        order = described_class.run(tables)

        # Without runtime mode, accounts (no belongs_to) resolves first and the
        # referencer that belongs_to it comes after — the FK-loadable order the
        # SQL output needs.
        expect(order.index('accounts')).to be < order.index('articles')
      end

      it 'raises when reverse_scope arms create an ordering cycle' do
        # accounts must come after articles (arm), articles after categories
        # (belongs_to), categories after accounts (belongs_to): no order can
        # satisfy all three, and silently breaking the arm would build the
        # reverse filter from missing state.
        articles_via_category = collection('articles', deps: %w[organizations categories])
        categories = collection('categories', deps: %w[accounts])
        accounts_config = collection('accounts', reverse_via: [{ table: 'articles', column: 'author_account_id' }])
        tables = [organizations, articles_via_category, categories, accounts_config]

        expect {
          described_class.run(tables, runtime_reverse_scope: true)
        }.to raise_error(ArgumentError, /reverse_scope creates an ordering cycle.*'accounts' \(via: articles\)/m)
      end

      it 'still breaks a plain belongs_to cycle (no reverse_scope edge involved) instead of raising' do
        binders = collection('binders', deps: %w[responses])
        responses = collection('responses', deps: %w[binders])

        expect(
          described_class.run([binders, responses, accounts, articles, invitations, organizations], runtime_reverse_scope: true)
        ).to contain_exactly(*%w[binders responses accounts articles invitations organizations])
      end
    end

    context 'when full tables' do
      let(:tables) do
        [
          order_items_table(:sqlite),
          transactions_table(:sqlite),
          orders_table(:sqlite),
          users_table(:sqlite),
          products_table(:sqlite),
          system_announcements_table(:sqlite),
          shops_table(:sqlite),
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

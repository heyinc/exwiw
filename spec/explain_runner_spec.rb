require 'spec_helper'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'

module Exwiw
  RSpec.describe ExplainRunner do
    let(:connection_config) do
      ConnectionConfig.new(
        adapter: 'sqlite',
        database_name: 'tmp/test.sqlite3',
        host: nil,
        port: nil,
        user: nil,
        password: nil,
      )
    end
    let(:io) { StringIO.new }
    let(:logger) { ::Logger.new(nil) }
    let(:schema_dir) { @schema_dir }
    let(:dump_target) { DumpTarget.new(table_name: nil, ids: []) }
    let(:runner) do
      ExplainRunner.new(
        connection_config: connection_config,
        schema_dir: schema_dir,
        dump_target: dump_target,
        logger: logger,
        io: io,
      )
    end

    around do |example|
      Dir.mktmpdir do |config|
        @schema_dir = config
        example.run
      end
    end

    describe '#run with --target-table' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1']) }

      before do
        FileUtils.cp('e2e/sqlite-schema/shops.json', File.join(schema_dir, 'shops.json'))
      end

      it 'prints compiled SQL and EXPLAIN output for the target table' do
        runner.run

        out = io.string
        expect(out).to include('-- [1/1] shops')
        expect(out).to include('SELECT shops.id')
        expect(out).to include('FROM shops')
        expect(out).to include('-- EXPLAIN:')
      end

      it 'does not write any file' do
        Dir.mktmpdir do |dir|
          before_files = Dir[File.join(dir, '*')]
          runner.run
          after_files = Dir[File.join(dir, '*')]
          expect(after_files).to eq(before_files)
        end
      end
    end

    describe '#run without --target-table (dump-all mode)' do
      let(:runner) do
        ExplainRunner.new(
          connection_config: connection_config,
          schema_dir: 'e2e/sqlite-schema',
          dump_target: dump_target,
          logger: logger,
          io: io,
        )
      end

      it 'prints one block per table' do
        runner.run

        out = io.string
        expect(out).to include('-- [1/')
        expect(out.scan(/-- EXPLAIN:/).size).to be >= 1
        expect(out).to include('FROM shops')
      end
    end

    describe '#run with a batch_scope table' do
      # Scope-column mode over the seeded fixture (see the Runner spec): orders is
      # filtered by shop_id, order_items reaches the scope through it and is
      # batched by orders' in-scope ids.
      let(:dump_target) { DumpTarget.new(table_name: 'orders', ids: ['1']) }

      before do
        orders = JSON.parse(File.read('e2e/sqlite-schema/orders.json'))
        orders['scope_column'] = 'shop_id'
        orders.delete('filter')
        orders['belongs_tos'] = []
        File.write(File.join(schema_dir, 'orders.json'), JSON.dump(orders))

        order_items = JSON.parse(File.read('e2e/sqlite-schema/order_items.json'))
        order_items['batch_scope'] = { 'table' => 'orders', 'size' => 4 }
        order_items['belongs_tos'] = [{ 'table_name' => 'orders', 'foreign_key' => 'order_id' }]
        File.write(File.join(schema_dir, 'order_items.json'), JSON.dump(order_items))
      end

      # A batched export runs a query the table's own block does not show — the
      # one resolving the ids it is sliced by — so explain prints that too.
      it 'also prints the id-set query and its EXPLAIN' do
        runner.run

        out = io.string
        expect(out).to include('-- batch_scope: extracted in batches of up to 4 orders.id value(s).')
        expect(out).to include("SELECT orders.id FROM orders WHERE orders.shop_id = '1'")
        expect(out).to include('-- EXPLAIN (batch_scope id set):')
      end

      it 'executes no extraction query' do
        expect_any_instance_of(Adapter::SqliteAdapter).not_to receive(:execute)

        runner.run
      end
    end

    describe '#run when --target-table is marked ignore:true' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1']) }

      before do
        shops = JSON.parse(File.read('e2e/sqlite-schema/shops.json'))
        shops['ignore'] = true
        File.write(File.join(schema_dir, 'shops.json'), JSON.dump(shops))
      end

      it 'raises ArgumentError' do
        expect { runner.run }.to raise_error(ArgumentError, /target-table 'shops' is marked ignore:true/)
      end
    end

    describe '#run when --target-table does not exist in the schema' do
      let(:dump_target) { DumpTarget.new(table_name: 'no_such_table', ids: ['1']) }

      before do
        FileUtils.cp('e2e/sqlite-schema/shops.json', File.join(schema_dir, 'shops.json'))
      end

      it 'raises ArgumentError' do
        expect { runner.run }.to raise_error(ArgumentError, /--target-table 'no_such_table' does not exist in the schema/)
      end
    end
  end
end

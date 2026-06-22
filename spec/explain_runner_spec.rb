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

    describe '#run in hybrid mode (--target-table + --scope-column)' do
      # Anchor on a specific user, and additionally scope by the shared shop_id
      # derived from that user. `products` is unrelated to `users` by belongs_to
      # but carries shop_id, so it is reached only by the scope column.
      let(:dump_target) { DumpTarget.new(table_name: 'users', ids: ['1'], scope_column: 'shop_id') }

      before do
        %w[shops users products].each do |t|
          FileUtils.cp("e2e/sqlite-schema/#{t}.json", File.join(schema_dir, "#{t}.json"))
        end
      end

      it 'compiles, validates and EXPLAINs the OR-union without error' do
        runner.run
        out = io.string

        # users is reachable by both anchors -> OR-union.
        expect(out).to match(/FROM users WHERE \(.* OR .*\)/)
        # products is reachable only by the derived scope column (single branch).
        expect(out).to include(
          'products.shop_id IN (SELECT users.shop_id FROM users WHERE users.id IN (\'1\'))'
        )
        expect(out.scan(/-- EXPLAIN:/).size).to eq(3)
      end
    end
  end
end

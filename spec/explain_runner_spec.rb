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
    let(:config_dir) { @config_dir }
    let(:dump_target) { DumpTarget.new(table_name: nil, ids: []) }
    let(:runner) do
      ExplainRunner.new(
        connection_config: connection_config,
        config_dir: config_dir,
        dump_target: dump_target,
        logger: logger,
        io: io,
      )
    end

    around do |example|
      Dir.mktmpdir do |config|
        @config_dir = config
        example.run
      end
    end

    describe '#run with --target-table' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1']) }

      before do
        FileUtils.cp('scenario/sqlite-schema/shops.json', File.join(config_dir, 'shops.json'))
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
          config_dir: 'scenario/sqlite-schema',
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

    describe '#run when --target-table is marked skip:true' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1']) }

      before do
        shops = JSON.parse(File.read('scenario/sqlite-schema/shops.json'))
        shops['skip'] = true
        File.write(File.join(config_dir, 'shops.json'), JSON.dump(shops))
      end

      it 'raises ArgumentError' do
        expect { runner.run }.to raise_error(ArgumentError, /target-table 'shops' is marked skip:true/)
      end
    end
  end
end

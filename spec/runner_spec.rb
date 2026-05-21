require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'

module Exwiw
  RSpec.describe Runner do
    let(:connection_config) do
      ConnectionConfig.new(
        adapter: 'sqlite3',
        database_name: 'tmp/test.sqlite3',
        host: nil,
        port: nil,
        user: nil,
        password: nil,
      )
    end
    let(:output_dir) { @output_dir }
    let(:config_dir) { @config_dir }
    let(:dump_target) { DumpTarget.new(table_name: nil, ids: []) }
    let(:runner) do
      Runner.new(
        connection_config: connection_config,
        output_dir: output_dir,
        config_dir: config_dir,
        dump_target: dump_target,
        logger: ::Logger.new(nil),
      )
    end

    around do |example|
      Dir.mktmpdir do |config|
        Dir.mktmpdir do |output|
          @config_dir = config
          @output_dir = output
          example.run
        end
      end
    end

    it 'writes bulk insert SQL to the output file' do
      expect { runner.run }.not_to raise_error
    end

    describe 'with bulk_insert_chunk_size' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1', '2', '3', '4', '5']) }
      let(:insert_sql_regex) { /INSERT INTO shops .+ VALUES\n\([^)]+\)(?:,\n\([^)]+\))*;/ }

      before do
        shops_config = JSON.parse(File.read('scenario/sqlite3-schema/shops.json'))
        shops_config['bulk_insert_chunk_size'] = 2
        File.write(File.join(config_dir, 'shops.json'), JSON.dump(shops_config))
      end

      it 'splits INSERT statements into chunks within a single file' do
        runner.run

        sql_file = Dir[File.join(output_dir, 'insert-*-shops.sql')].first
        expect(sql_file).not_to be_nil

        insert_statements = File.read(sql_file).scan(insert_sql_regex)
        expect(insert_statements.size).to eq(3)
      end

      it 'writes the leading insert-000-schema.sql with idempotent CREATE TABLE' do
        runner.run

        schema_file = File.join(output_dir, 'insert-000-schema.sql')
        expect(File.exist?(schema_file)).to be(true)
        expect(File.read(schema_file)).to include('CREATE TABLE IF NOT EXISTS "shops"')
      end
    end

    describe 'without bulk_insert_chunk_size' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1', '2', '3', '4', '5']) }

      before do
        FileUtils.cp('scenario/sqlite3-schema/shops.json', File.join(config_dir, 'shops.json'))
      end

      it 'emits a single INSERT statement per table' do
        runner.run

        sql_file = Dir[File.join(output_dir, 'insert-*-shops.sql')].first
        expect(sql_file).not_to be_nil

        sql = File.read(sql_file)
        expect(sql.scan(/INSERT INTO shops/).size).to eq(1)
      end
    end
    describe 'dump-all mode (no target table or ids)' do
      let(:dump_target) { DumpTarget.new(table_name: nil, ids: []) }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          config_dir: 'scenario/sqlite3-schema',
          dump_target: dump_target,
          logger: ::Logger.new(nil),
        )
      end

      it 'writes insert files for all tables without raising' do
        expect { runner.run }.not_to raise_error

        insert_files = Dir[File.join(output_dir, 'insert-*-*.sql')]
        expect(insert_files).not_to be_empty
      end
    end

    describe 'with insert_only' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1']) }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          config_dir: config_dir,
          dump_target: dump_target,
          insert_only: true,
          logger: ::Logger.new(nil),
        )
      end

      before do
        FileUtils.cp('scenario/sqlite3-schema/shops.json', File.join(config_dir, 'shops.json'))
      end

      it 'does not generate delete files' do
        runner.run

        insert_files = Dir[File.join(output_dir, 'insert-*-shops.sql')]
        expect(insert_files).not_to be_empty

        delete_files = Dir[File.join(output_dir, 'delete-*.sql')]
        expect(delete_files).to be_empty
      end
    end

    describe 'with output_format copy' do
      let(:connection_config) do
        ConnectionConfig.new(
          adapter: 'postgresql',
          database_name: 'exwiw_test',
          host: '127.0.0.1',
          port: 5432,
          user: 'postgres',
          password: 'test_password',
        )
      end
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1']) }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          config_dir: 'scenario/postgresql-schema',
          dump_target: dump_target,
          output_format: 'copy',
          logger: ::Logger.new(nil),
        )
      end

      it 'generates COPY FROM stdin format instead of INSERT' do
        runner.run

        sql_file = Dir[File.join(output_dir, 'insert-*-shops.sql')].first
        expect(sql_file).not_to be_nil

        sql = File.read(sql_file)
        expect(sql).to include('COPY shops')
        expect(sql).to include('FROM stdin;')
        expect(sql).to include('\\.')
        expect(sql).not_to include('INSERT INTO')
      end

      it 'still generates post_insert_sql (setval)' do
        runner.run

        sql_file = Dir[File.join(output_dir, 'insert-*-shops.sql')].first
        sql = File.read(sql_file)
        expect(sql).to include('pg_catalog.setval')
      end

      it 'still generates delete files' do
        runner.run

        delete_files = Dir[File.join(output_dir, 'delete-*.sql')]
        expect(delete_files).not_to be_empty
      end
    end
  end
end

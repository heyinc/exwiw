require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'stringio'

module Exwiw
  RSpec.describe Runner do
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
    let(:output_dir) { @output_dir }
    let(:schema_dir) { @schema_dir }
    let(:dump_target) { DumpTarget.new(table_name: nil, ids: []) }
    let(:runner) do
      Runner.new(
        connection_config: connection_config,
        output_dir: output_dir,
        schema_dir: schema_dir,
        dump_target: dump_target,
        logger: ::Logger.new(nil),
      )
    end

    around do |example|
      Dir.mktmpdir do |config|
        Dir.mktmpdir do |output|
          @schema_dir = config
          @output_dir = output
          example.run
        end
      end
    end

    it 'writes bulk insert SQL to the output file' do
      expect { runner.run }.not_to raise_error
    end

    it 'generates no delete files' do
      runner.run

      expect(Dir[File.join(output_dir, 'insert-*.sql')]).not_to be_empty
      expect(Dir[File.join(output_dir, 'delete-*.sql')]).to be_empty
    end

    describe 'output dir cleaning' do
      it 'removes pre-existing contents of the output dir before export' do
        stale_file = File.join(output_dir, 'insert-999-stale.sql')
        stale_dir = File.join(output_dir, 'leftover')
        dotfile = File.join(output_dir, '.hidden')
        File.write(stale_file, 'stale')
        FileUtils.mkdir_p(stale_dir)
        File.write(dotfile, 'hidden')

        runner.run

        expect(File.exist?(stale_file)).to be(false)
        expect(File.exist?(stale_dir)).to be(false)
        expect(File.exist?(dotfile)).to be(false)
        expect(Dir[File.join(output_dir, 'insert-000-schema.sql')]).not_to be_empty
      end

      it 'creates the output dir when it does not exist' do
        missing = File.join(output_dir, 'nested', 'out')
        runner_for_missing = Runner.new(
          connection_config: connection_config,
          output_dir: missing,
          schema_dir: schema_dir,
          dump_target: dump_target,
          logger: ::Logger.new(nil),
        )

        runner_for_missing.run

        expect(Dir.exist?(missing)).to be(true)
        expect(Dir[File.join(missing, 'insert-000-schema.sql')]).not_to be_empty
      end
    end

    describe 'with bulk_insert_chunk_size' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1', '2', '3', '4', '5']) }
      let(:insert_sql_regex) { /INSERT INTO shops .+ VALUES\n\([^)]+\)(?:,\n\([^)]+\))*;/ }

      before do
        shops_config = JSON.parse(File.read('e2e/sqlite-schema/shops.json'))
        shops_config['bulk_insert_chunk_size'] = 2
        File.write(File.join(schema_dir, 'shops.json'), JSON.dump(shops_config))
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
        FileUtils.cp('e2e/sqlite-schema/shops.json', File.join(schema_dir, 'shops.json'))
      end

      it 'emits a single INSERT statement per table' do
        runner.run

        sql_file = Dir[File.join(output_dir, 'insert-*-shops.sql')].first
        expect(sql_file).not_to be_nil

        sql = File.read(sql_file)
        expect(sql.scan(/INSERT INTO shops/).size).to eq(1)
      end
    end

    describe 'when a schema config carries an unknown key' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1']) }

      before do
        shops_config = JSON.parse(File.read('e2e/sqlite-schema/shops.json'))
        shops_config['bulk_insert_chunk_sise'] = 2 # typo'd key
        File.write(File.join(schema_dir, 'shops.json'), JSON.dump(shops_config))
      end

      it 'aborts with an error naming the key, the table, and the offending file' do
        expect { runner.run }.to raise_error(UnknownConfigKeyError) { |e|
          expect(e.message).to include(File.join(schema_dir, 'shops.json'))
          expect(e.message).to include("Unknown key 'bulk_insert_chunk_sise' in table 'shops'")
        }
      end
    end

    describe 'ruby-side masking (map)' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: shop_ids) }
      let(:shop_ids) { ['1'] }

      before do
        shops_config = JSON.parse(File.read('e2e/sqlite-schema/shops.json'))
        name_column = shops_config['columns'].find { |c| c['name'] == 'name' }
        name_column['map'] = 'proc { |r| "shop-#{r["id"]}-masked" }'
        File.write(File.join(schema_dir, 'shops.json'), JSON.dump(shops_config))
      end

      it 'writes the mapped value into the dump' do
        runner.run

        sql = File.read(Dir[File.join(output_dir, 'insert-*-shops.sql')].first)
        expect(sql).to include("'shop-1-masked'")
      end

      context 'when no rows match' do
        let(:shop_ids) { ['999999'] }

        it 'still detects the empty table and skips the file' do
          runner.run

          expect(Dir[File.join(output_dir, 'insert-*-shops.sql')]).to be_empty
        end
      end
    end
    describe 'error reporting when SQL generation fails' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1', '2']) }
      let(:log_io) { StringIO.new }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          schema_dir: 'e2e/sqlite-schema',
          dump_target: dump_target,
          logger: ::Logger.new(log_io),
        )
      end

      it 're-raises and logs the table, phase, and extraction query that produced the failing data' do
        # The Runner delegates INSERT-statement writing to #write_inserts, so
        # simulate the row-serialization failure there (this is the method on the
        # "generating INSERT statement" phase).
        allow_any_instance_of(Adapter::SqliteAdapter)
          .to receive(:write_inserts)
          .and_raise(RuntimeError, 'simulated encoding error in row data')

        expect { runner.run }.to raise_error(RuntimeError, 'simulated encoding error in row data')

        log = log_io.string
        expect(log).to include("Error while generating INSERT statement for table 'shops'")
        expect(log).to include('Extraction query that produced the data being processed:')
        expect(log).to match(/SELECT .+ FROM shops WHERE shops\.id IN \('1', '2'\)/)
      end
    end

    describe 'dump-all mode (no target table or ids)' do
      let(:dump_target) { DumpTarget.new(table_name: nil, ids: []) }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          schema_dir: 'e2e/sqlite-schema',
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

    describe 'when the extraction query matches zero rows' do
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['999999']) }
      let(:log_io) { StringIO.new }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          schema_dir: schema_dir,
          dump_target: dump_target,
          logger: ::Logger.new(log_io),
        )
      end

      before do
        FileUtils.cp('e2e/sqlite-schema/shops.json', File.join(schema_dir, 'shops.json'))
      end

      # Regression guard for runner.rb's `record_num.zero?` short-circuit: a
      # zero-row table must be skipped entirely rather than fed to
      # to_bulk_insert, which would otherwise emit broken `INSERT ... VALUES ;`.
      it 'skips the table without emitting an insert file' do
        expect { runner.run }.not_to raise_error

        expect(Dir[File.join(output_dir, 'insert-*-shops.sql')]).to be_empty
        expect(log_io.string).to include('No records matched. skip this table.')
      end
    end

    describe 'with batch_scope' do
      # Scope-column mode over the seeded fixture: shop 1 owns orders 1-6, and
      # order_items is batched by them four at a time -- six rows, two queries.
      let(:dump_target) { DumpTarget.new(table_name: 'orders', ids: ['1']) }
      let(:log_io) { StringIO.new }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          schema_dir: schema_dir,
          dump_target: dump_target,
          logger: ::Logger.new(log_io),
        )
      end

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

      it 'extracts the batched table over several queries into one insert file' do
        runner.run

        insert_file = Dir[File.join(output_dir, 'insert-*-order_items.sql')].first
        expect(insert_file).not_to be_nil
        expect(File.read(insert_file).scan(/INSERT INTO/).size).to eq(1)
        expect(log_io.string).to include('Extracting in 2 batch(es) of up to 4 orders.id value(s) (6 in scope)')
        expect(log_io.string).to include('Generated INSERT statement for 6 records')
      end

      it 'aborts pre-flight, before any output, when the scope shape cannot be sliced' do
        order_items = JSON.parse(File.read(File.join(schema_dir, 'order_items.json')))
        order_items['batch_scope'] = { 'table' => 'ghosts' }
        File.write(File.join(schema_dir, 'order_items.json'), JSON.dump(order_items))

        expect { runner.run }.to raise_error(ArgumentError, /order_items.*batch_scope names table 'ghosts'/)
        expect(Dir[File.join(output_dir, '*')]).to be_empty
      end
    end

    describe 'with after_insert_hook_path (.rb)' do
      let(:hook_path) { 'tmp/runner_spec_after_hook.rb' }
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['1', '2']) }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          schema_dir: schema_dir,
          dump_target: dump_target,
          after_insert_hook_path: hook_path,
          cli_options: { ids: ['1', '2'], target_table: 'shops' },
          logger: ::Logger.new(nil),
        )
      end

      before do
        FileUtils.cp('e2e/sqlite-schema/shops.json', File.join(schema_dir, 'shops.json'))

        File.write(hook_path, <<~RUBY)
          insert_sql <<~SQL
            -- after-insert for ids: <%= cli_options.fetch(:ids).join(',') %>
          SQL
        RUBY
      end

      after do
        FileUtils.rm_f(hook_path)
      end

      it 'writes insert-{N+1}-after_insert.sql with ERB-expanded content' do
        runner.run

        files = Dir[File.join(output_dir, 'insert-*-after_insert.sql')]
        expect(files.size).to eq(1)
        content = File.read(files.first)
        expect(content).to include('-- after-insert for ids: 1,2')
      end
    end

    describe 'with after_insert_hook_path (.rb) targeting collections on mongodb' do
      let(:connection_config) do
        ConnectionConfig.new(
          adapter: 'mongodb',
          database_name: 'exwiw_test',
          host: ENV.fetch('MONGO_HOST', '127.0.0.1'),
          port: ENV.fetch('MONGO_PORT', 27017).to_i,
          user: nil,
          password: nil,
        )
      end
      let(:hook_path) { 'tmp/runner_spec_after_hook_mongodb.rb' }
      let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['a00100000000000000000001']) }
      let(:runner) do
        Runner.new(
          connection_config: connection_config,
          output_dir: output_dir,
          schema_dir: 'e2e/mongodb-schema',
          dump_target: dump_target,
          after_insert_hook_path: hook_path,
          cli_options: { ids: ['a00100000000000000000001'], target_table: 'shops' },
          logger: ::Logger.new(nil),
        )
      end

      before do
        File.write(hook_path, <<~RUBY)
          insert_jsonl 'coupons', '{"code":"WELCOME"}'
          insert_jsonl 'coupons', '{"code":"VIP"}'
          insert_jsonl 'tags', '{"name":"new"}'
        RUBY
      end

      after do
        FileUtils.rm_f(hook_path)
      end

      it 'writes one jsonl file per targeted collection, numbered after the extracted collections' do
        runner.run

        coupons = Dir[File.join(output_dir, 'insert-*-coupons.jsonl')]
        tags = Dir[File.join(output_dir, 'insert-*-tags.jsonl')]
        expect(coupons.size).to eq(1)
        expect(tags.size).to eq(1)
        expect(File.read(coupons.first)).to eq(%({"code":"WELCOME"}\n{"code":"VIP"}))
        expect(File.read(tags.first)).to eq('{"name":"new"}')

        index = ->(path) { File.basename(path)[/\Ainsert-(\d{3})/, 1].to_i }
        extracted_max = (Dir[File.join(output_dir, 'insert-*')] - coupons - tags).map(&index).max
        expect(index.(coupons.first)).to eq(extracted_max + 1)
        expect(index.(tags.first)).to eq(extracted_max + 2)
      end
    end

    describe 'with ignore:true on a table config' do
      let(:dump_target) { DumpTarget.new(table_name: nil, ids: []) }

      before do
        FileUtils.cp('e2e/sqlite-schema/shops.json', File.join(schema_dir, 'shops.json'))

        announcements = JSON.parse(File.read('e2e/sqlite-schema/system_announcements.json'))
        announcements['ignore'] = true
        File.write(File.join(schema_dir, 'system_announcements.json'), JSON.dump(announcements))
      end

      it 'emits schema for the ignored table but no insert files' do
        runner.run

        expect(Dir[File.join(output_dir, 'insert-*-system_announcements.sql')]).to be_empty

        schema_file = File.join(output_dir, 'insert-000-schema.sql')
        expect(File.exist?(schema_file)).to be(true)
        expect(File.read(schema_file)).to include('system_announcements')
      end

      it 'still emits files for non-ignored tables' do
        runner.run

        expect(Dir[File.join(output_dir, 'insert-*-shops.sql')]).not_to be_empty
      end
    end

    describe 'when a non-ignored table has belongs_to an ignored table' do
      let(:dump_target) { DumpTarget.new(table_name: nil, ids: []) }

      before do
        shops = JSON.parse(File.read('e2e/sqlite-schema/shops.json'))
        shops['ignore'] = true
        File.write(File.join(schema_dir, 'shops.json'), JSON.dump(shops))
        FileUtils.cp('e2e/sqlite-schema/users.json', File.join(schema_dir, 'users.json'))
      end

      it 'raises ArgumentError with a clear message' do
        expect { runner.run }.to raise_error(ArgumentError, /belongs_to references to ignored table\(s\): shops/)
      end
    end

    describe 'when --target-table is ignored' do
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

    describe 'when --target-table does not exist in the schema' do
      let(:dump_target) { DumpTarget.new(table_name: 'no_such_table', ids: ['1']) }

      before do
        FileUtils.cp('e2e/sqlite-schema/shops.json', File.join(schema_dir, 'shops.json'))
      end

      it 'raises ArgumentError instead of silently dumping nothing' do
        expect { runner.run }.to raise_error(ArgumentError, /--target-table 'no_such_table' does not exist in the schema/)
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
          schema_dir: 'e2e/postgresql-schema',
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

      context 'when the extraction query matches zero rows' do
        let(:dump_target) { DumpTarget.new(table_name: 'shops', ids: ['999999']) }

        it 'skips the table without emitting a COPY file' do
          expect { runner.run }.not_to raise_error

          expect(Dir[File.join(output_dir, 'insert-*-shops.sql')]).to be_empty
        end
      end
    end
  end
end

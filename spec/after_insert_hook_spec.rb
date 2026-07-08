require 'spec_helper'
require 'fileutils'
require 'tempfile'

module Exwiw
  RSpec.describe AfterInsertHook do
    let(:logger) { ::Logger.new(nil) }

    describe AfterInsertHook::Context do
      let(:cli_options) { { ids: ['1', '2', '3'], target_table: 'shops' } }
      let(:ctx) { described_class.new(cli_options) }

      it 'evaluates the template as ERB and exposes cli_options' do
        ctx.insert_sql("ids=<%= cli_options.fetch(:ids).join(',') %>")
        expect(ctx.collected).to eq(['ids=1,2,3'])
      end

      it 'concatenates multiple insert_sql calls' do
        ctx.insert_sql('A')
        ctx.insert_sql('B')
        expect(ctx.collected).to eq(['A', 'B'])
      end

      it 'aliases insert_jsonl to insert_sql' do
        ctx.insert_jsonl('{"x":<%= cli_options.fetch(:ids).first %>}')
        expect(ctx.collected).to eq(['{"x":1}'])
      end

      context 'with a jsonl output extension' do
        let(:ctx) { described_class.new(cli_options, output_extension: 'jsonl') }

        it 'collects collection-targeted insert_jsonl output per collection' do
          ctx.insert_jsonl('users', '{"email":"u<%= cli_options.fetch(:ids).first %>@example.com"}')
          ctx.insert_jsonl('posts', '{"title":"hello"}')
          expect(ctx.collected_by_collection).to eq(
            'users' => ['{"email":"u1@example.com"}'],
            'posts' => ['{"title":"hello"}'],
          )
          expect(ctx.collected).to eq([])
        end

        it 'appends multiple calls for the same collection' do
          ctx.insert_jsonl('users', '{"n":1}')
          ctx.insert_jsonl('users', '{"n":2}')
          expect(ctx.collected_by_collection).to eq('users' => ['{"n":1}', '{"n":2}'])
        end

        it 'raises for a collection name that is not filename-safe' do
          expect { ctx.insert_jsonl('../evil', '{}') }.to raise_error(ArgumentError, /invalid collection name/)
        end
      end

      it 'raises when the collection-targeted form is used with a non-jsonl adapter' do
        expect {
          ctx.insert_jsonl('users', '{}')
        }.to raise_error(ArgumentError, /only supported for the MongoDB adapter/)
      end
    end

    describe '.run with a .rb hook' do
      let(:output_dir) { 'tmp/after_insert_hook_spec_output' }
      let(:hook_path) { File.join(output_dir, 'hook.rb') }
      let(:cli_options) { { ids: ['10', '20'], target_table: 'shops' } }

      before do
        FileUtils.rm_rf(output_dir)
        FileUtils.mkdir_p(output_dir)
        File.write(hook_path, <<~RUBY)
          insert_sql <<~SQL
            -- ids: <%= cli_options.fetch(:ids).join(',') %>
            <%- cli_options.fetch(:ids).each do |id| -%>
            INSERT INTO defaults (tenant_id) VALUES (<%= id %>);
            <%- end -%>
          SQL
        RUBY
      end

      it 'writes the next-numbered insert file with ERB-expanded contents' do
        AfterInsertHook.run(
          path: hook_path,
          cli_options: cli_options,
          output_dir: output_dir,
          next_idx: 4,
          output_extension: 'sql',
          logger: logger,
        )

        out = File.join(output_dir, 'insert-004-after_insert.sql')
        expect(File.exist?(out)).to be(true)
        content = File.read(out)
        expect(content).to include('-- ids: 10,20')
        expect(content).to include('INSERT INTO defaults (tenant_id) VALUES (10);')
        expect(content).to include('INSERT INTO defaults (tenant_id) VALUES (20);')
      end

      it 'does not create a file when insert_sql is never called' do
        File.write(hook_path, "# noop\n")

        AfterInsertHook.run(
          path: hook_path,
          cli_options: cli_options,
          output_dir: output_dir,
          next_idx: 7,
          output_extension: 'sql',
          logger: logger,
        )

        expect(Dir[File.join(output_dir, 'insert-*-after_insert.sql')]).to be_empty
      end
    end

    describe '.run with a .rb hook targeting collections (jsonl)' do
      let(:output_dir) { 'tmp/after_insert_hook_spec_jsonl' }
      let(:hook_path) { File.join(output_dir, 'hook.rb') }
      let(:cli_options) { { ids: ['10', '20'], target_table: 'shops' } }

      before do
        FileUtils.rm_rf(output_dir)
        FileUtils.mkdir_p(output_dir)
      end

      def run_hook(next_idx: 4)
        AfterInsertHook.run(
          path: hook_path,
          cli_options: cli_options,
          output_dir: output_dir,
          next_idx: next_idx,
          output_extension: 'jsonl',
          logger: logger,
        )
      end

      it 'writes one sequentially numbered file per collection' do
        File.write(hook_path, <<~RUBY)
          insert_jsonl 'users', <<~JSONL
            <%- cli_options.fetch(:ids).each do |id| -%>
            {"shop_id":<%= id %>,"email":"default@example.com"}
            <%- end -%>
          JSONL
          insert_jsonl 'posts', '{"title":"welcome"}'
        RUBY

        run_hook

        users = File.read(File.join(output_dir, 'insert-004-users.jsonl'))
        expect(users).to include('{"shop_id":10,"email":"default@example.com"}')
        expect(users).to include('{"shop_id":20,"email":"default@example.com"}')
        posts = File.read(File.join(output_dir, 'insert-005-posts.jsonl'))
        expect(posts).to include('{"title":"welcome"}')
      end

      it 'appends multiple calls for the same collection into one file' do
        File.write(hook_path, <<~RUBY)
          insert_jsonl 'users', '{"n":1}'
          insert_jsonl 'users', '{"n":2}'
        RUBY

        run_hook

        users = File.read(File.join(output_dir, 'insert-004-users.jsonl'))
        expect(users).to eq(%({"n":1}\n{"n":2}))
        expect(Dir[File.join(output_dir, 'insert-005-*.jsonl')]).to be_empty
      end

      it 'keeps the collection-less buffer at next_idx and numbers collections after it' do
        File.write(hook_path, <<~RUBY)
          insert_jsonl '{"untargeted":true}'
          insert_jsonl 'users', '{"n":1}'
        RUBY

        run_hook

        expect(File.read(File.join(output_dir, 'insert-004-after_insert.jsonl'))).to eq('{"untargeted":true}')
        expect(File.read(File.join(output_dir, 'insert-005-users.jsonl'))).to eq('{"n":1}')
      end
    end

    describe '.run with a shell hook' do
      let(:output_dir) { 'tmp/after_insert_hook_spec_shell' }
      let(:hook_path) { File.join(output_dir, 'hook.sh') }
      let(:cli_options) do
        {
          ids: ['1', '2'], target_table: 'shops', schema_dir: '/cfg',
          database_adapter: 'sqlite', database_host: nil, database_port: nil,
          database_user: nil, database_name: 'db', output_format: 'insert',
        }
      end

      before do
        FileUtils.rm_rf(output_dir)
        FileUtils.mkdir_p(output_dir)
        File.write(hook_path, <<~SH)
          #!/usr/bin/env bash
          set -eu
          echo "ids=$EXWIW_IDS table=$EXWIW_TARGET_TABLE adapter=$EXWIW_DATABASE_ADAPTER" \\
            > "$EXWIW_OUTPUT_DIR/shell_out.txt"
        SH
        FileUtils.chmod(0o755, hook_path)
      end

      it 'executes the shell script with EXWIW_* env vars' do
        AfterInsertHook.run(
          path: hook_path,
          cli_options: cli_options,
          output_dir: output_dir,
          next_idx: 5,
          output_extension: 'sql',
          logger: logger,
        )

        out = File.read(File.join(output_dir, 'shell_out.txt'))
        expect(out).to include('ids=1,2')
        expect(out).to include('table=shops')
        expect(out).to include('adapter=sqlite')
      end

      it 'raises when the shell hook exits non-zero' do
        File.write(hook_path, "#!/usr/bin/env bash\nexit 7\n")
        FileUtils.chmod(0o755, hook_path)

        expect {
          AfterInsertHook.run(
            path: hook_path,
            cli_options: cli_options,
            output_dir: output_dir,
            next_idx: 5,
            output_extension: 'sql',
            logger: logger,
          )
        }.to raise_error(/after-insert shell hook failed/)
      end
    end
  end
end

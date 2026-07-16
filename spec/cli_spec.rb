require 'spec_helper'
require 'exwiw/cli'
require 'tmpdir'
require 'fileutils'

module Exwiw
  RSpec.describe CLI do
    describe 'subcommand parsing' do
      it 'defaults to "export" when no subcommand is given' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('export')
      end

      it 'recognizes "export" as a subcommand' do
        cli = CLI.new(['export', '--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('export')
      end

      it 'recognizes "explain" as a subcommand' do
        cli = CLI.new(['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('explain')
      end

      it 'does not treat an option-looking argv[0] as a subcommand' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('export')
      end

      it 'does not consume unknown positional arguments as a subcommand' do
        cli = CLI.new(['foo', '--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('export')
      end
    end

    describe '#build_logger' do
      # build_logger flips STDOUT.sync so piped/redirected progress logs are not
      # block-buffered. Restore the flag so it does not leak into other specs.
      around do |example|
        original_sync = STDOUT.sync
        example.run
      ensure
        STDOUT.sync = original_sync
      end

      it 'enables STDOUT sync so per-collection progress flushes in real time' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3',
                       '--schema-dir=e2e/sqlite-schema', '--log-level=info'])
        STDOUT.sync = false

        cli.send(:build_logger)

        expect(STDOUT.sync).to be(true)
      end
    end

    describe 'explain subcommand validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'rejects --output-format with explain' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=e2e/sqlite-schema', '--output-format=copy']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --insert-only with explain' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=e2e/sqlite-schema', '--insert-only']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --output-dir with explain' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=e2e/sqlite-schema', '--output-dir=tmp/x']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --after-insert-hook with explain' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=e2e/sqlite-schema', '--after-insert-hook=/tmp/some.rb']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'accepts the mongodb adapter (no longer rejected)' do
        cli = CLI.new(['explain', '--adapter=mongodb', '--host=localhost', '--port=27017',
                       '--database=app', '--schema-dir=e2e/mongodb-schema'])
        expect { cli.send(:validate_options!) }.not_to raise_error
      end
    end

    describe 'explain verbosity (mongodb)' do
      def explain_cli(extra = [])
        CLI.new(['explain', '--adapter=mongodb', '--host=localhost', '--port=27017',
                 '--database=app', '--schema-dir=e2e/mongodb-schema', *extra])
      end

      def stub_env(value)
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('EXWIW_MONGODB_EXPLAIN_VERBOSITY').and_return(value)
      end

      it 'defaults to queryPlanner (the query is not executed)' do
        cli = explain_cli
        cli.send(:validate_options!)
        expect(cli.instance_variable_get(:@explain_verbosity)).to eq('queryPlanner')
      end

      it 'reads verbosity from EXWIW_MONGODB_EXPLAIN_VERBOSITY' do
        stub_env('executionStats')
        cli = explain_cli
        cli.send(:validate_options!)
        expect(cli.instance_variable_get(:@explain_verbosity)).to eq('executionStats')
      end

      it 'reads verbosity from the config file' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'exwiw.yml')
          File.write(path, "explain_verbosity: allPlansExecution\n")
          cli = explain_cli(["--config=#{path}"])
          cli.send(:validate_options!)
          expect(cli.instance_variable_get(:@explain_verbosity)).to eq('allPlansExecution')
        end
      end

      it 'prefers the env var over the config-file value' do
        stub_env('executionStats')
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'exwiw.yml')
          File.write(path, "explain_verbosity: allPlansExecution\n")
          cli = explain_cli(["--config=#{path}"])
          cli.send(:validate_options!)
          expect(cli.instance_variable_get(:@explain_verbosity)).to eq('executionStats')
        end
      end

      it 'rejects an invalid verbosity' do
        stub_env('bogus')
        cli = explain_cli
        expect { cli.send(:validate_options!) }.to raise_error(SystemExit)
          .and output(/Invalid explain verbosity 'bogus'/).to_stderr
      end

      it 'ignores verbosity for non-mongodb adapters (never validated)' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'exwiw.yml')
          File.write(path, "explain_verbosity: bogus\n")
          cli = CLI.new(['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                         '--schema-dir=e2e/sqlite-schema', "--config=#{path}"])
          expect { cli.send(:validate_options!) }.not_to raise_error
        end
      end
    end

    describe '--ids-field validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'parses --ids-field onto the dump target' do
        cli = CLI.new(['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                       '--schema-dir=e2e/mongodb-schema', '--target-table=users',
                       '--ids=a@example.com', '--ids-field=email'])
        expect(cli.instance_variable_get(:@ids_field)).to eq('email')
      end

      it 'rejects --ids-field without --target-table' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=e2e/mongodb-schema', '--ids-field=email']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--target-table is required when --ids-field is specified/).to_stderr
      end

      it 'rejects --ids-field for non-mongodb adapters' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema',
                '--target-table=users', '--ids=1', '--ids-field=email']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--ids-field is only supported by the mongodb adapter/).to_stderr
      end
    end

    describe '--scope-column validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'parses --scope-column into the ivar' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3',
                       '--schema-dir=e2e/sqlite-schema', '--scope-column=tenant_id', '--ids=1'])
        expect(cli.instance_variable_get(:@scope_column)).to eq('tenant_id')
      end

      it 'warns that --scope-column is deprecated' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema',
                       '--scope-column=tenant_id', '--ids=1'])
        expect { cli.send(:validate_options!) }.to output(/--scope-column is deprecated/).to_stderr
      end

      it 'rejects combining --scope-column with --target-table' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema',
                '--scope-column=tenant_id', '--target-table=users', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--scope-column cannot be combined with --target-table/).to_stderr
      end

      it 'rejects combining --scope-column with --ids-field' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema',
                '--scope-column=tenant_id', '--ids-field=email', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--scope-column cannot be combined with --ids-field/).to_stderr
      end

      it 'rejects --scope-column for the mongodb adapter' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=e2e/mongodb-schema', '--scope-column=tenant_id', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--scope-column is only supported by the sql adapters/).to_stderr
      end

      it 'rejects --scope-column without --ids' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema',
                '--scope-column=tenant_id']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--ids is required when --scope-column is specified/).to_stderr
      end
    end

    describe '--target-collection alias' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'folds --target-collection into the target table for the mongodb adapter' do
        cli = CLI.new(['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                       '--schema-dir=e2e/mongodb-schema', '--target-collection=users', '--ids=1'])
        cli.send(:resolve_target_collection_alias!)
        expect(cli.instance_variable_get(:@target_table_name)).to eq('users')
      end

      it 'rejects --target-collection for non-mongodb adapters' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema',
                '--target-collection=users', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--target-collection is only supported by the mongodb adapter/).to_stderr
      end

      it 'rejects specifying both --target-table and --target-collection' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=e2e/mongodb-schema', '--target-table=users',
                '--target-collection=users', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/Specify only one of --target-table and --target-collection/).to_stderr
      end
    end

    describe '--uri option' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'parses --uri onto the connection for the mongodb adapter' do
        cli = CLI.new(['--adapter=mongodb', '--database=app', '--schema-dir=e2e/mongodb-schema',
                       '--uri=mongodb+srv://u:p@cluster.example.com/app?authSource=admin&tls=true'])
        expect(cli.instance_variable_get(:@connection_uri))
          .to eq('mongodb+srv://u:p@cluster.example.com/app?authSource=admin&tls=true')
      end

      it 'rejects --uri for non-mongodb adapters' do
        argv = ['--adapter=postgresql', '--database=app', '--schema-dir=e2e/postgresql-schema',
                '--uri=mongodb://localhost:27017/app']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--uri is only supported by the mongodb adapter/).to_stderr
      end

      it 'does not require --host/--port/--database when --uri is given' do
        cli = CLI.new(['--adapter=mongodb', '--schema-dir=e2e/mongodb-schema',
                       '--uri=mongodb+srv://u:p@cluster.example.com/app'])
        expect { cli.send(:validate_options!) }.not_to raise_error
      end
    end

    describe '--parallel-workers validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'parses --parallel-workers into the ivar for the mongodb adapter' do
        cli = CLI.new(['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                       '--schema-dir=e2e/mongodb-schema', '--target-collection=users', '--ids=1',
                       '--parallel-workers=4'])
        cli.send(:validate_options!)
        expect(cli.instance_variable_get(:@parallel_workers)).to eq(4)
      end

      it 'rejects --parallel-workers for non-mongodb adapters' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema',
                '--target-table=users', '--ids=1', '--parallel-workers=4']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--parallel-workers is only supported by the mongodb adapter/).to_stderr
      end

      it 'rejects a non-positive --parallel-workers' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=e2e/mongodb-schema', '--target-collection=users', '--ids=1',
                '--parallel-workers=0']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--parallel-workers must be a positive integer/).to_stderr
      end

      it 'rejects --parallel-workers in the explain subcommand' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=e2e/sqlite-schema', '--target-table=users', '--ids=1',
                '--parallel-workers=4']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--parallel-workers is only supported by the mongodb adapter/).to_stderr
      end
    end

    describe '--mongodb-query-timeout-ms validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'parses --mongodb-query-timeout-ms into the ivar for the mongodb adapter' do
        cli = CLI.new(['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                       '--schema-dir=e2e/mongodb-schema', '--target-collection=users', '--ids=1',
                       '--mongodb-query-timeout-ms=30000'])
        cli.send(:validate_options!)
        expect(cli.instance_variable_get(:@mongodb_query_timeout_ms)).to eq(30000)
      end

      it 'rejects --mongodb-query-timeout-ms for non-mongodb adapters' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema',
                '--target-table=users', '--ids=1', '--mongodb-query-timeout-ms=30000']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--mongodb-query-timeout-ms is only supported by the mongodb adapter/).to_stderr
      end

      it 'rejects a non-positive --mongodb-query-timeout-ms' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=e2e/mongodb-schema', '--target-collection=users', '--ids=1',
                '--mongodb-query-timeout-ms=0']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--mongodb-query-timeout-ms must be a positive integer/).to_stderr
      end

      it 'flows the parsed value into the ConnectionConfig' do
        cli = CLI.new(['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                       '--schema-dir=e2e/mongodb-schema', '--target-collection=users', '--ids=1',
                       '--mongodb-query-timeout-ms=30000'])
        captured = nil
        allow(Runner).to receive(:new) do |**kwargs|
          captured = kwargs[:connection_config]
          instance_double(Runner, run: nil)
        end
        allow($stdin).to receive(:tty?).and_return(false)
        cli.run
        expect(captured.mongodb_query_timeout_ms).to eq(30000)
      end
    end

    describe 'output dir clear confirmation' do
      around do |example|
        Dir.mktmpdir do |dir|
          @output_dir = dir
          example.run
        end
      end

      def cli_with_output_dir
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema'])
        cli.instance_variable_set(:@output_dir, @output_dir)
        cli
      end

      it 'does not prompt when stdin is not a tty' do
        File.write(File.join(@output_dir, 'stale.sql'), 'x')
        allow($stdin).to receive(:tty?).and_return(false)
        expect($stdin).not_to receive(:gets)

        expect { cli_with_output_dir.send(:confirm_output_dir_clear!) }.not_to raise_error
      end

      it 'does not prompt on a tty when the output dir is empty' do
        allow($stdin).to receive(:tty?).and_return(true)
        expect($stdin).not_to receive(:gets)

        expect { cli_with_output_dir.send(:confirm_output_dir_clear!) }.not_to raise_error
      end

      it 'proceeds when the user answers yes on a tty' do
        File.write(File.join(@output_dir, 'stale.sql'), 'x')
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdin).to receive(:gets).and_return("y\n")

        expect { cli_with_output_dir.send(:confirm_output_dir_clear!) }
          .to output(/All contents of the output dir will be removed/).to_stderr
      end

      it 'aborts when the user declines on a tty' do
        File.write(File.join(@output_dir, 'stale.sql'), 'x')
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdin).to receive(:gets).and_return("n\n")

        expect { cli_with_output_dir.send(:confirm_output_dir_clear!) }
          .to raise_error(SystemExit).and output(/Aborted/).to_stderr
      end

      it 'aborts on empty input (default is no)' do
        File.write(File.join(@output_dir, 'stale.sql'), 'x')
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdin).to receive(:gets).and_return("\n")

        expect { cli_with_output_dir.send(:confirm_output_dir_clear!) }
          .to raise_error(SystemExit).and output(/Aborted/).to_stderr
      end
    end

    describe 'adapter name normalization' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'accepts the mysql2 alias and folds it into the canonical mysql name' do
        original = ENV['DATABASE_PASSWORD']
        ENV['DATABASE_PASSWORD'] = 'secret'
        cli = CLI.new(['--adapter=mysql2', '--host=localhost', '--port=3306', '--user=root',
                       '--database=app', '--schema-dir=e2e/mysql-schema'])
        cli.send(:validate_options!)
        expect(cli.instance_variable_get(:@database_adapter)).to eq('mysql')
      ensure
        ENV['DATABASE_PASSWORD'] = original
      end

      it 'accepts the sqlite3 alias and folds it into the canonical sqlite name' do
        cli = CLI.new(['--adapter=sqlite3', '--database=tmp/test.sqlite3', '--schema-dir=e2e/sqlite-schema'])
        cli.send(:validate_options!)
        expect(cli.instance_variable_get(:@database_adapter)).to eq('sqlite')
      end

      it 'rejects an unknown adapter with a message listing canonical names and aliases' do
        argv = ['--adapter=oracle', '--host=localhost', '--port=1521', '--user=system',
                '--database=app', '--schema-dir=e2e/sqlite-schema']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/Invalid adapter.*mysql, sqlite, postgresql, mongodb.*aliases.*mysql2/m).to_stderr
      end
    end

    describe 'config file (--config / exwiw.yml)' do
      around do |example|
        Dir.mktmpdir { |dir| @tmpdir = dir; example.run }
      end

      def write_config(contents)
        path = File.join(@tmpdir, 'config.yml')
        File.write(path, contents)
        path
      end

      it 'fills options from the config file when not given on the CLI' do
        path = write_config("schema_dir: e2e/sqlite-schema\noutput_format: insert\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        # Resolved relative to the config file's directory (@tmpdir), not cwd.
        expect(cli.instance_variable_get(:@schema_dir)).to eq(File.expand_path('e2e/sqlite-schema', @tmpdir))
        expect(cli.instance_variable_get(:@output_format)).to eq('insert')
      end

      it 'resolves a relative config path against the config file, not cwd' do
        FileUtils.mkdir_p(File.join(@tmpdir, 'sub'))
        path = File.join(@tmpdir, 'sub', 'exwiw.yml')
        File.write(path, "schema_dir: schema\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@schema_dir)).to eq(File.join(@tmpdir, 'sub', 'schema'))
      end

      it 'leaves an absolute config path untouched' do
        abs = File.expand_path('e2e/sqlite-schema')
        path = write_config("schema_dir: #{abs}\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@schema_dir)).to eq(abs)
      end

      it 'accepts the -c short flag' do
        path = write_config("schema_dir: e2e/sqlite-schema\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '-c', path])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@schema_dir)).to eq(File.expand_path('e2e/sqlite-schema', @tmpdir))
      end

      it 'lets a CLI option take precedence over the config file' do
        path = write_config("schema_dir: e2e/sqlite-schema\noutput_format: insert\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}", '--output-format=copy'])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@output_format)).to eq('copy')
      end

      it 'accepts adapter from the config file' do
        path = write_config("adapter: sqlite\nschema_dir: e2e/sqlite-schema\n")
        cli = CLI.new(['--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@database_adapter)).to eq('sqlite')
      end

      it 'parses ids given as a YAML list into an array of strings' do
        path = write_config("schema_dir: e2e/sqlite-schema\nids:\n  - 1\n  - 2\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@ids)).to eq(['1', '2'])
      end

      it 'parses fail_fast_strategies given as a YAML list' do
        path = write_config("schema_dir: e2e/sqlite-schema\nfail_fast_strategies:\n  - target_has_no_matched_records\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@fail_fast_strategies)).to eq(['target_has_no_matched_records'])
      end

      it 'rejects an unknown fail_fast_strategies value' do
        path = write_config("schema_dir: e2e/sqlite-schema\nfail_fast_strategies:\n  - no_such_strategy\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        expect { cli.send(:apply_config_file!) }.to raise_error(SystemExit)
          .and output(/Unknown fail_fast_strategies value\(s\): no_such_strategy/).to_stderr
      end

      it 'ignores fail_fast_strategies for the explain subcommand' do
        schema = File.expand_path('e2e/sqlite-schema')
        path = write_config("schema_dir: #{schema}\nfail_fast_strategies:\n  - target_has_no_matched_records\n")
        cli = CLI.new(['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        expect { cli.send(:validate_options!) }.not_to raise_error
        expect(cli.instance_variable_get(:@fail_fast_strategies)).to be_nil
      end

      it 'rejects database connection keys in the config file' do
        path = write_config("host: db.example.com\nschema_dir: e2e/sqlite-schema\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        expect { cli.send(:apply_config_file!) }.to raise_error(SystemExit)
          .and output(/'host' is a database connection setting/).to_stderr
      end

      it 'rejects unknown keys in the config file' do
        path = write_config("schmea_dir: e2e/sqlite-schema\n") # deliberate typo
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        expect { cli.send(:apply_config_file!) }.to raise_error(SystemExit)
          .and output(/Unknown config key 'schmea_dir'/).to_stderr
      end

      it 'errors when an explicit --config path does not exist' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '--config=/no/such/config.yml'])
        expect { cli.send(:apply_config_file!) }.to raise_error(SystemExit)
          .and output(/Config file not found/).to_stderr
      end

      it 'auto-loads exwiw.yml from the cwd when --config is omitted' do
        Dir.chdir(@tmpdir) do
          File.write('exwiw.yml', "output_format: copy\n")
          cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3'])
          cli.send(:apply_config_file!)
          expect(cli.instance_variable_get(:@output_format)).to eq('copy')
        end
      end

      it 'auto-loads the exwiw.yaml extension too' do
        Dir.chdir(@tmpdir) do
          File.write('exwiw.yaml', "output_format: copy\n")
          cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3'])
          cli.send(:apply_config_file!)
          expect(cli.instance_variable_get(:@output_format)).to eq('copy')
        end
      end

      it 'ignores export-only config keys for the explain subcommand' do
        # Absolute schema_dir so validate_options! finds a real directory.
        schema = File.expand_path('e2e/sqlite-schema')
        path = write_config("schema_dir: #{schema}\noutput_format: copy\n")
        cli = CLI.new(['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        expect { cli.send(:validate_options!) }.not_to raise_error
        expect(cli.instance_variable_get(:@output_format)).to be_nil
      end

      it 'still rejects an export-only option passed explicitly on the CLI with explain' do
        path = write_config("schema_dir: e2e/sqlite-schema\n")
        cli = CLI.new(['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}", '--output-format=copy'])
        expect { cli.send(:validate_options!) }.to raise_error(SystemExit)
          .and output(/not applicable in 'explain'/).to_stderr
      end
    end
  end
end

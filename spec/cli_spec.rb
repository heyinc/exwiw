require 'spec_helper'
require 'exwiw/cli'
require 'tmpdir'
require 'fileutils'

module Exwiw
  RSpec.describe CLI do
    describe 'subcommand parsing' do
      it 'defaults to "export" when no subcommand is given' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('export')
      end

      it 'recognizes "export" as a subcommand' do
        cli = CLI.new(['export', '--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('export')
      end

      it 'recognizes "explain" as a subcommand' do
        cli = CLI.new(['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('explain')
      end

      it 'does not treat an option-looking argv[0] as a subcommand' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('export')
      end

      it 'does not consume unknown positional arguments as a subcommand' do
        cli = CLI.new(['foo', '--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('export')
      end
    end

    describe 'explain subcommand validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'rejects --output-format with explain' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=scenario/sqlite-schema', '--output-format=copy']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --insert-only with explain' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=scenario/sqlite-schema', '--insert-only']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --output-dir with explain' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=scenario/sqlite-schema', '--output-dir=tmp/x']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --after-insert-hook with explain' do
        argv = ['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3',
                '--schema-dir=scenario/sqlite-schema', '--after-insert-hook=/tmp/some.rb']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects mongodb adapter with explain' do
        argv = ['explain', '--adapter=mongodb', '--host=localhost', '--port=27017',
                '--database=app', '--schema-dir=scenario/mongodb-schema']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/mongodb adapter is not yet supported by 'explain'/).to_stderr
      end
    end

    describe '--ids-field validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'parses --ids-field onto the dump target' do
        cli = CLI.new(['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                       '--schema-dir=scenario/mongodb-schema', '--target-table=users',
                       '--ids=a@example.com', '--ids-field=email'])
        expect(cli.instance_variable_get(:@ids_field)).to eq('email')
      end

      it 'rejects --ids-field without --target-table' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=scenario/mongodb-schema', '--ids-field=email']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--target-table is required when --ids-field is specified/).to_stderr
      end

      it 'rejects --ids-field for non-mongodb adapters' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema',
                '--target-table=users', '--ids=1', '--ids-field=email']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--ids-field is only supported by the mongodb adapter \(use --ids-column\)/).to_stderr
      end
    end

    describe '--ids-column validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'folds --ids-column into the ids field for sql adapters' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3',
                       '--schema-dir=scenario/sqlite-schema', '--target-table=users',
                       '--ids=a@example.com', '--ids-column=email'])
        cli.send(:resolve_target_collection_alias!)
        cli.send(:resolve_ids_column_alias!)
        expect(cli.instance_variable_get(:@ids_field)).to eq('email')
      end

      it 'rejects --ids-column for the mongodb adapter' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=scenario/mongodb-schema', '--target-table=users',
                '--ids=1', '--ids-column=email']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--ids-column is only supported by the sql adapters \(use --ids-field\)/).to_stderr
      end

      it 'rejects specifying both --ids-field and --ids-column' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema',
                '--target-table=users', '--ids=1', '--ids-field=email', '--ids-column=email']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/Specify only one of --ids-field and --ids-column/).to_stderr
      end

      it 'rejects --ids-column without --target-table' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema',
                '--ids-column=email']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--target-table is required when --ids-column is specified/).to_stderr
      end
    end

    describe '--scope-column validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'parses --scope-column into the ivar' do
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3',
                       '--schema-dir=scenario/sqlite-schema', '--scope-column=tenant_id', '--ids=1'])
        expect(cli.instance_variable_get(:@scope_column)).to eq('tenant_id')
      end

      it 'rejects combining --scope-column with --target-table' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema',
                '--scope-column=tenant_id', '--target-table=users', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--scope-column cannot be combined with --target-table/).to_stderr
      end

      it 'rejects combining --scope-column with --ids-column' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema',
                '--scope-column=tenant_id', '--ids-column=email', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--scope-column cannot be combined with --ids-column/).to_stderr
      end

      it 'rejects --scope-column for the mongodb adapter' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=scenario/mongodb-schema', '--scope-column=tenant_id', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--scope-column is only supported by the sql adapters/).to_stderr
      end

      it 'rejects --scope-column without --ids' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema',
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
                       '--schema-dir=scenario/mongodb-schema', '--target-collection=users', '--ids=1'])
        cli.send(:resolve_target_collection_alias!)
        expect(cli.instance_variable_get(:@target_table_name)).to eq('users')
      end

      it 'rejects --target-collection for non-mongodb adapters' do
        argv = ['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema',
                '--target-collection=users', '--ids=1']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--target-collection is only supported by the mongodb adapter/).to_stderr
      end

      it 'rejects specifying both --target-table and --target-collection' do
        argv = ['--adapter=mongodb', '--host=localhost', '--port=27017', '--database=app',
                '--schema-dir=scenario/mongodb-schema', '--target-table=users',
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
        cli = CLI.new(['--adapter=mongodb', '--database=app', '--schema-dir=scenario/mongodb-schema',
                       '--uri=mongodb+srv://u:p@cluster.example.com/app?authSource=admin&tls=true'])
        expect(cli.instance_variable_get(:@connection_uri))
          .to eq('mongodb+srv://u:p@cluster.example.com/app?authSource=admin&tls=true')
      end

      it 'rejects --uri for non-mongodb adapters' do
        argv = ['--adapter=postgresql', '--database=app', '--schema-dir=scenario/postgresql-schema',
                '--uri=mongodb://localhost:27017/app']
        expect { run_cli(argv) }.to raise_error(SystemExit)
          .and output(/--uri is only supported by the mongodb adapter/).to_stderr
      end

      it 'does not require --host/--port/--database when --uri is given' do
        cli = CLI.new(['--adapter=mongodb', '--schema-dir=scenario/mongodb-schema',
                       '--uri=mongodb+srv://u:p@cluster.example.com/app'])
        expect { cli.send(:validate_options!) }.not_to raise_error
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
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema'])
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
                       '--database=app', '--schema-dir=scenario/mysql-schema'])
        cli.send(:validate_options!)
        expect(cli.instance_variable_get(:@database_adapter)).to eq('mysql')
      ensure
        ENV['DATABASE_PASSWORD'] = original
      end

      it 'accepts the sqlite3 alias and folds it into the canonical sqlite name' do
        cli = CLI.new(['--adapter=sqlite3', '--database=tmp/test.sqlite3', '--schema-dir=scenario/sqlite-schema'])
        cli.send(:validate_options!)
        expect(cli.instance_variable_get(:@database_adapter)).to eq('sqlite')
      end

      it 'rejects an unknown adapter with a message listing canonical names and aliases' do
        argv = ['--adapter=oracle', '--host=localhost', '--port=1521', '--user=system',
                '--database=app', '--schema-dir=scenario/sqlite-schema']
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
        path = write_config("schema_dir: scenario/sqlite-schema\noutput_format: insert\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        # Resolved relative to the config file's directory (@tmpdir), not cwd.
        expect(cli.instance_variable_get(:@schema_dir)).to eq(File.expand_path('scenario/sqlite-schema', @tmpdir))
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
        abs = File.expand_path('scenario/sqlite-schema')
        path = write_config("schema_dir: #{abs}\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@schema_dir)).to eq(abs)
      end

      it 'accepts the -c short flag' do
        path = write_config("schema_dir: scenario/sqlite-schema\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', '-c', path])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@schema_dir)).to eq(File.expand_path('scenario/sqlite-schema', @tmpdir))
      end

      it 'lets a CLI option take precedence over the config file' do
        path = write_config("schema_dir: scenario/sqlite-schema\noutput_format: insert\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}", '--output-format=copy'])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@output_format)).to eq('copy')
      end

      it 'accepts adapter from the config file' do
        path = write_config("adapter: sqlite\nschema_dir: scenario/sqlite-schema\n")
        cli = CLI.new(['--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@database_adapter)).to eq('sqlite')
      end

      it 'parses ids given as a YAML list into an array of strings' do
        path = write_config("schema_dir: scenario/sqlite-schema\nids:\n  - 1\n  - 2\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        cli.send(:apply_config_file!)
        expect(cli.instance_variable_get(:@ids)).to eq(['1', '2'])
      end

      it 'rejects database connection keys in the config file' do
        path = write_config("host: db.example.com\nschema_dir: scenario/sqlite-schema\n")
        cli = CLI.new(['--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        expect { cli.send(:apply_config_file!) }.to raise_error(SystemExit)
          .and output(/'host' is a database connection setting/).to_stderr
      end

      it 'rejects unknown keys in the config file' do
        path = write_config("schmea_dir: scenario/sqlite-schema\n") # deliberate typo
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
        schema = File.expand_path('scenario/sqlite-schema')
        path = write_config("schema_dir: #{schema}\noutput_format: copy\n")
        cli = CLI.new(['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}"])
        expect { cli.send(:validate_options!) }.not_to raise_error
        expect(cli.instance_variable_get(:@output_format)).to be_nil
      end

      it 'still rejects an export-only option passed explicitly on the CLI with explain' do
        path = write_config("schema_dir: scenario/sqlite-schema\n")
        cli = CLI.new(['explain', '--adapter=sqlite', '--database=tmp/test.sqlite3', "--config=#{path}", '--output-format=copy'])
        expect { cli.send(:validate_options!) }.to raise_error(SystemExit)
          .and output(/not applicable in 'explain'/).to_stderr
      end
    end
  end
end

require 'spec_helper'
require 'exwiw/cli'

module Exwiw
  RSpec.describe CLI do
    describe 'subcommand parsing' do
      it 'defaults to "dump" when no subcommand is given' do
        cli = CLI.new(['--adapter=sqlite3', '--database=tmp/test.sqlite3', '--config-dir=scenario/sqlite3-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('dump')
      end

      it 'recognizes "dump" as a subcommand' do
        cli = CLI.new(['dump', '--adapter=sqlite3', '--database=tmp/test.sqlite3', '--config-dir=scenario/sqlite3-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('dump')
      end

      it 'recognizes "explain" as a subcommand' do
        cli = CLI.new(['explain', '--adapter=sqlite3', '--database=tmp/test.sqlite3', '--config-dir=scenario/sqlite3-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('explain')
      end

      it 'does not treat an option-looking argv[0] as a subcommand' do
        cli = CLI.new(['--adapter=sqlite3', '--database=tmp/test.sqlite3', '--config-dir=scenario/sqlite3-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('dump')
      end

      it 'does not consume unknown positional arguments as a subcommand' do
        cli = CLI.new(['foo', '--adapter=sqlite3', '--database=tmp/test.sqlite3', '--config-dir=scenario/sqlite3-schema'])
        expect(cli.instance_variable_get(:@subcommand)).to eq('dump')
      end
    end

    describe 'explain subcommand validation' do
      def run_cli(argv)
        CLI.new(argv).run
      end

      it 'rejects --output-format with explain' do
        argv = ['explain', '--adapter=sqlite3', '--database=tmp/test.sqlite3',
                '--config-dir=scenario/sqlite3-schema', '--output-format=copy']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --insert-only with explain' do
        argv = ['explain', '--adapter=sqlite3', '--database=tmp/test.sqlite3',
                '--config-dir=scenario/sqlite3-schema', '--insert-only']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --output-dir with explain' do
        argv = ['explain', '--adapter=sqlite3', '--database=tmp/test.sqlite3',
                '--config-dir=scenario/sqlite3-schema', '--output-dir=tmp/x']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects --after-insert-hook with explain' do
        argv = ['explain', '--adapter=sqlite3', '--database=tmp/test.sqlite3',
                '--config-dir=scenario/sqlite3-schema', '--after-insert-hook=/tmp/some.rb']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/not applicable in 'explain'/).to_stderr
      end

      it 'rejects mongodb adapter with explain' do
        argv = ['explain', '--adapter=mongodb', '--host=localhost', '--port=27017',
                '--database=app', '--config-dir=scenario/mongodb-schema']
        expect { run_cli(argv) }.to raise_error(SystemExit).and output(/mongodb adapter is not yet supported by 'explain'/).to_stderr
      end
    end
  end
end

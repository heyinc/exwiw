# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

module Exwiw
  RSpec.describe ConfigFile do
    around do |example|
      Dir.mktmpdir { |dir| @tmpdir = dir; example.run }
    end

    describe '.schema_dir' do
      it 'reads schema_dir from an explicit config path, resolved relative to the file' do
        path = File.join(@tmpdir, 'exwiw.yml')
        File.write(path, "schema_dir: exwiw/schema\n")

        expect(ConfigFile.schema_dir(path)).to eq(File.join(@tmpdir, 'exwiw/schema'))
      end

      it 'strips a trailing slash like the CLI does' do
        path = File.join(@tmpdir, 'exwiw.yml')
        File.write(path, "schema_dir: schema/\n")

        expect(ConfigFile.schema_dir(path)).to eq(File.join(@tmpdir, 'schema'))
      end

      it 'leaves an absolute schema_dir untouched' do
        abs = File.join(@tmpdir, 'abs-schema')
        path = File.join(@tmpdir, 'exwiw.yml')
        File.write(path, "schema_dir: #{abs}\n")

        expect(ConfigFile.schema_dir(path)).to eq(abs)
      end

      it 'auto-discovers exwiw.yml in the current directory when no path is given' do
        File.write(File.join(@tmpdir, 'exwiw.yml'), "schema_dir: from-yml\n")

        Dir.chdir(@tmpdir) do
          # realpath: macOS resolves the tmpdir symlink (/var -> /private/var)
          # through the cwd that File.expand_path uses.
          expect(ConfigFile.schema_dir).to eq(File.join(Dir.pwd, 'from-yml'))
        end
      end

      it 'auto-discovers the exwiw.yaml extension too' do
        File.write(File.join(@tmpdir, 'exwiw.yaml'), "schema_dir: from-yaml\n")

        Dir.chdir(@tmpdir) do
          expect(ConfigFile.schema_dir).to eq(File.join(Dir.pwd, 'from-yaml'))
        end
      end

      it 'returns nil when no config file is present' do
        Dir.chdir(@tmpdir) { expect(ConfigFile.schema_dir).to be_nil }
      end

      it 'returns nil when the config file does not set schema_dir' do
        path = File.join(@tmpdir, 'exwiw.yml')
        File.write(path, "output_format: insert\n")

        expect(ConfigFile.schema_dir(path)).to be_nil
      end

      it 'returns nil for a non-existent explicit path' do
        expect(ConfigFile.schema_dir(File.join(@tmpdir, 'nope.yml'))).to be_nil
      end

      it 'returns nil for a malformed YAML config instead of raising' do
        path = File.join(@tmpdir, 'exwiw.yml')
        File.write(path, "schema_dir: [unterminated\n")

        expect(ConfigFile.schema_dir(path)).to be_nil
      end
    end

    describe '.profiles' do
      around do |example|
        Dir.mktmpdir do |dir|
          @tmpdir = dir
          example.run
        end
      end

      def config(yaml)
        File.join(@tmpdir, 'exwiw.yml').tap { |path| File.write(path, yaml) }
      end

      it 'returns the declared profiles' do
        expect(ConfigFile.profiles(config("profiles: [dev, ci]\n"))).to eq(%w[dev ci])
      end

      it 'returns none without a config file or a declaration' do
        Dir.chdir(@tmpdir) { expect(ConfigFile.profiles).to eq([]) }
        expect(ConfigFile.profiles(config("schema_dir: s\n"))).to eq([])
      end

      it 'raises on an invalid declaration rather than treating overlays as base files' do
        expect { ConfigFile.profiles(config("profiles: [Dev]\n")) }.to raise_error(ArgumentError, /profile name 'Dev'/)
        expect { ConfigFile.profiles(config("profiles: [dev, dev]\n")) }.to raise_error(ArgumentError, /more than once/)
        expect { ConfigFile.profiles(config("profiles: dev\n")) }.to raise_error(ArgumentError, /must be a list/)
      end

      it 'raises on a config file it cannot read as a mapping' do
        expect { ConfigFile.profiles(config("profiles: [unterminated\n")) }
          .to raise_error(ArgumentError, /Could not parse the config file/)
        expect { ConfigFile.profiles(config("- dev\n")) }.to raise_error(ArgumentError, /must be a YAML mapping/)
        expect(ConfigFile.profiles(config(""))).to eq([])
      end
    end
  end
end

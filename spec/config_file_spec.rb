# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Exwiw::ConfigFile do
  around do |example|
    Dir.mktmpdir { |dir| @tmpdir = dir; example.run }
  end

  def write(name, contents)
    path = File.join(@tmpdir, name)
    File.write(path, contents)
    path
  end

  describe ".find" do
    it "loads an explicit path" do
      path = write("custom.yml", "schema_dir: exwiw/schema\n")
      config = described_class.find(path: path)
      expect(config.path).to eq(path)
    end

    it "raises when an explicit path does not exist" do
      expect { described_class.find(path: "/no/such/config.yml") }
        .to raise_error(ArgumentError, /Config file not found/)
    end

    it "auto-loads exwiw.yml from base_dir when no path is given" do
      write("exwiw.yml", "schema_dir: exwiw/schema\n")
      config = described_class.find(base_dir: @tmpdir)
      expect(config.path).to eq(File.join(@tmpdir, "exwiw.yml"))
    end

    it "auto-loads the exwiw.yaml extension too" do
      write("exwiw.yaml", "schema_dir: exwiw/schema\n")
      config = described_class.find(base_dir: @tmpdir)
      expect(config.path).to eq(File.join(@tmpdir, "exwiw.yaml"))
    end

    it "prefers exwiw.yml over exwiw.yaml when both exist" do
      write("exwiw.yml", "schema_dir: from_yml\n")
      write("exwiw.yaml", "schema_dir: from_yaml\n")
      config = described_class.find(base_dir: @tmpdir)
      expect(config.path).to eq(File.join(@tmpdir, "exwiw.yml"))
    end

    it "returns nil when no config file is present" do
      expect(described_class.find(base_dir: @tmpdir)).to be_nil
    end

    it "treats an empty explicit path like no path (auto-load)" do
      write("exwiw.yml", "schema_dir: exwiw/schema\n")
      config = described_class.find(path: "", base_dir: @tmpdir)
      expect(config.path).to eq(File.join(@tmpdir, "exwiw.yml"))
    end
  end

  describe "#schema_dir" do
    it "resolves a relative schema_dir against the config file's own directory" do
      path = write("exwiw.yml", "schema_dir: exwiw/schema\n")
      expect(described_class.new(path).schema_dir).to eq(File.join(@tmpdir, "exwiw", "schema"))
    end

    it "strips a trailing slash" do
      path = write("exwiw.yml", "schema_dir: exwiw/schema/\n")
      expect(described_class.new(path).schema_dir).to eq(File.join(@tmpdir, "exwiw", "schema"))
    end

    it "leaves an absolute schema_dir untouched" do
      abs = File.expand_path("e2e/sqlite-schema")
      path = write("exwiw.yml", "schema_dir: #{abs}\n")
      expect(described_class.new(path).schema_dir).to eq(abs)
    end

    it "returns nil when schema_dir is absent" do
      path = write("exwiw.yml", "output_format: insert\n")
      expect(described_class.new(path).schema_dir).to be_nil
    end

    it "returns nil for an empty config file" do
      path = write("exwiw.yml", "")
      expect(described_class.new(path).schema_dir).to be_nil
    end
  end

  it "rejects a config file that is not a YAML mapping" do
    path = write("exwiw.yml", "- just\n- a\n- list\n")
    expect { described_class.new(path) }
      .to raise_error(ArgumentError, /must be a YAML mapping/)
  end
end

# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "active_record"
require "sqlite3"

require_relative "../script/database_config"

module Exwiw
  RSpec.describe SchemaCheck do
    before(:all) do
      ActiveRecord::Base.establish_connection(database_config(:sqlite))
      require_relative "../script/models"
    end

    after(:all) do
      ActiveRecord::Base.remove_connection
    end

    let(:schema_dir) { @schema_dir }
    let(:models) { [User] }

    around do |ex|
      Dir.mktmpdir do |dir|
        @schema_dir = dir
        ex.run
      end
    end

    # A config as it looks once every column's masking has been decided, which
    # is the committed state these examples start from.
    def generate_current_config
      SchemaGenerator.new(models: models, output_dir: schema_dir, safe_new_columns: false).generate!
    end

    def config_path(table_name)
      File.join(schema_dir, "#{table_name}.json")
    end

    def rewrite(table_name)
      config = JSON.parse(File.read(config_path(table_name)))
      yield config
      File.write(config_path(table_name), JSON.pretty_generate(config) + "\n")
    end

    def report
      described_class.new(models: models, schema_dir: schema_dir).run
    end

    it "reports nothing when the config matches the application" do
      generate_current_config

      expect(report.values.flatten).to be_empty
      expect(described_class.clean?(report)).to be(true)
    end

    it "reports a column the config does not have yet" do
      generate_current_config
      rewrite("users") { |config| config["columns"].reject! { |c| c["name"] == "email" } }

      expect(report["added_columns"]).to eq(["users.email"])
      expect(report["changed_tables"]).to eq(["users"])
      expect(described_class.clean?(report)).to be(false)
    end

    it "reports a column that no longer exists" do
      generate_current_config
      rewrite("users") { |config| config["columns"] << { "name" => "removed_by_migration" } }

      expect(report["removed_columns"]).to eq(["users.removed_by_migration"])
    end

    it "reports a table whose model is gone" do
      generate_current_config
      FileUtils.cp(config_path("users"), config_path("obsolete"))
      rewrite("obsolete") { |config| config["name"] = "obsolete" }

      expect(report["removed_tables"]).to eq(["obsolete"])
    end

    it "reports a column still waiting for a masking decision" do
      generate_current_config
      rewrite("users") do |config|
        config["columns"].find { |c| c["name"] == "email" }["needs_mask_decision"] = true
      end

      expect(report["needs_mask_decision"]).to eq(["users.email"])
      expect(report["changed_tables"]).to be_empty
      expect(described_class.clean?(report)).to be(false)
    end

    it "leaves the config directory untouched" do
      generate_current_config
      rewrite("users") { |config| config["columns"].reject! { |c| c["name"] == "email" } }
      before = Dir[File.join(schema_dir, "**", "*")].sort.to_h { |path| [path, File.read(path)] }

      report

      after = Dir[File.join(schema_dir, "**", "*")].sort.to_h { |path| [path, File.read(path)] }
      expect(after).to eq(before)
    end
  end
end

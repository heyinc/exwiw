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

    describe "staleness (the drift that would break an export)" do
      it "marks a removed column of an extracted table stale" do
        generate_current_config
        rewrite("users") { |config| config["columns"] << { "name" => "removed_by_migration" } }

        expect(report["stale_columns"]).to eq(["users.removed_by_migration"])
        expect(report["stale_tables"]).to be_empty
        expect(described_class.stale?(report)).to be(true)
      end

      it "marks a removed table stale when its config is extracted" do
        generate_current_config
        FileUtils.cp(config_path("users"), config_path("obsolete"))
        rewrite("obsolete") { |config| config["name"] = "obsolete" }

        expect(report["stale_tables"]).to eq(["obsolete"])
        expect(described_class.stale?(report)).to be(true)
      end

      it "marks a removed rails-managed table stale: it is dumped whole" do
        generate_current_config
        File.write(
          config_path("gone_migrations"),
          JSON.pretty_generate("name" => "gone_migrations", "type" => "rails_managed_schema_migrations") + "\n"
        )

        expect(report["removed_tables"]).to eq(["gone_migrations"])
        expect(report["stale_tables"]).to eq(["gone_migrations"])
        expect(described_class.stale?(report)).to be(true)
      end

      it "does not mark an ignored table stale, however it drifts" do
        generate_current_config
        FileUtils.cp(config_path("users"), config_path("obsolete"))
        rewrite("obsolete") do |config|
          config["name"] = "obsolete"
          config["ignore"] = true
        end

        expect(report["removed_tables"]).to eq(["obsolete"])
        expect(report["stale_tables"]).to be_empty
        expect(described_class.stale?(report)).to be(false)
      end

      it "does not mark an ignored column stale: the SELECT never names it" do
        generate_current_config
        rewrite("users") do |config|
          config["columns"] << { "name" => "removed_by_migration", "ignore" => true }
        end

        expect(report["removed_columns"]).to eq(["users.removed_by_migration"])
        expect(report["stale_columns"]).to be_empty
        expect(described_class.stale?(report)).to be(false)
      end

      it "does not mark additions stale: data is only not extracted yet" do
        generate_current_config
        rewrite("users") { |config| config["columns"].reject! { |c| c["name"] == "email" } }

        expect(report["added_columns"]).to eq(["users.email"])
        expect(described_class.stale?(report)).to be(false)
        expect(described_class.clean?(report)).to be(false)
      end
    end

    it "leaves the config directory untouched" do
      generate_current_config
      rewrite("users") { |config| config["columns"].reject! { |c| c["name"] == "email" } }
      before = Dir[File.join(schema_dir, "**", "*")].sort.to_h { |path| [path, File.read(path)] }

      report

      after = Dir[File.join(schema_dir, "**", "*")].sort.to_h { |path| [path, File.read(path)] }
      expect(after).to eq(before)
    end

    describe "profile overlays" do
      def overlay_report
        described_class.new(models: models, schema_dir: schema_dir, profiles: ["dev"]).run
      end

      def write_overlay(table_name, hash)
        File.write(File.join(schema_dir, "#{table_name}.dev.json"), JSON.pretty_generate(hash) + "\n")
      end

      it "reports nothing for an overlay that matches the base, and never lists it as a table" do
        generate_current_config
        write_overlay("users", { "name" => "users", "columns" => [{ "name" => "email", "replace_with" => "x" }] })

        expect(overlay_report["overlay_stale"]).to eq([])
        expect(overlay_report.values.flatten).to be_empty
        expect(described_class.clean?(overlay_report)).to be(true)
      end

      it "reports an overlay entry for a column the regenerated base drops, as stale" do
        generate_current_config
        rewrite("users") { |config| config["columns"] << { "name" => "legacy_col" } }
        write_overlay("users", { "name" => "users", "columns" => [{ "name" => "legacy_col", "ignore" => true }] })

        expect(overlay_report["overlay_stale"]).to eq(["dev:users.columns.legacy_col"])
        expect(overlay_report["removed_tables"]).to eq([])
        expect(described_class.stale?(overlay_report)).to be(true)
        expect(described_class.clean?(overlay_report)).to be(false)
      end

      it "reports an overlay of a table that is gone" do
        generate_current_config
        FileUtils.cp(config_path("users"), config_path("obsolete"))
        rewrite("obsolete") { |config| config["name"] = "obsolete" }
        write_overlay("obsolete", { "name" => "obsolete", "ignore" => true })

        expect(overlay_report["overlay_stale"]).to eq(["dev:obsolete"])
        expect(overlay_report["removed_tables"]).to eq(["obsolete"])
      end

      it "fails when an overlay does not merge into the committed config" do
        generate_current_config
        write_overlay("users", { "name" => "users", "columns" => [{ "name" => "no_such_column" }] })

        expect { overlay_report }.to raise_error(ArgumentError, /'columns.no_such_column' does not exist in the base config/)
      end

      it "fails when the merged config does not load" do
        generate_current_config
        write_overlay("users", { "name" => "users", "primary_key" => nil })

        expect { overlay_report }.to raise_error(ArgumentError, /profile 'dev'.*requires primary_key/)
      end

      it "omits the overlay report when no profiles are declared" do
        generate_current_config

        expect(report).not_to have_key("overlay_stale")
      end
    end
  end
end

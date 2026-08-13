# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

require_relative "../script/mongoid_models"

module Exwiw
  # The Mongoid half of SchemaCheck: the diff/report side is source-agnostic (it
  # reads JSON config files), so what these examples exercise is the injected
  # regeneration step — `SchemaCheck.mongoid_regenerator`, the very lambda
  # `from_mongoid_application` builds. The models are passed explicitly since
  # there is no Rails application here to eager-load.
  RSpec.describe SchemaCheck, "over a Mongoid schema source" do
    let(:models) { [MongoidDummy::User, MongoidDummy::Shop] }
    let(:schema_dir) { @schema_dir }

    around do |ex|
      Dir.mktmpdir do |dir|
        @schema_dir = dir
        ex.run
      end
    end

    # A config as it looks once every field's masking has been decided, which is
    # the committed state these examples start from.
    def generate_current_config
      MongoidSchemaGenerator.new(models: models, output_dir: schema_dir, safe_new_columns: false).generate!
    end

    def config_path(collection_name)
      File.join(schema_dir, "#{collection_name}.json")
    end

    def rewrite(collection_name)
      config = JSON.parse(File.read(config_path(collection_name)))
      yield config
      File.write(config_path(collection_name), JSON.pretty_generate(config) + "\n")
    end

    def report
      described_class.new(
        schema_dir: schema_dir, regenerator: described_class.mongoid_regenerator(models),
      ).run
    end

    it "reports nothing when the config matches the application" do
      generate_current_config

      expect(report.values.flatten).to be_empty
      expect(described_class.clean?(report)).to be(true)
    end

    it "reports a field the config does not have yet" do
      # `fields` is the MongoDB config's spelling of `columns`; the report reads
      # both, so a MongoDB field shows up under the same `added_columns` key.
      generate_current_config
      rewrite("users") { |config| config["fields"].reject! { |f| f["name"] == "email" } }

      expect(report["added_columns"]).to eq(["users.email"])
      expect(report["changed_tables"]).to eq(["users"])
      expect(described_class.clean?(report)).to be(false)
    end

    it "reports a field that no longer exists on the model" do
      generate_current_config
      rewrite("users") { |config| config["fields"] << { "name" => "removed_from_the_model" } }

      expect(report["removed_columns"]).to eq(["users.removed_from_the_model"])
    end

    it "reports a collection whose model is gone" do
      # Only `tidy!` can detect this (generate! never deletes a config file), so
      # this is what proves the regenerator runs it.
      generate_current_config
      FileUtils.cp(config_path("users"), config_path("obsolete"))
      rewrite("obsolete") { |config| config["name"] = "obsolete" }

      expect(report["removed_tables"]).to eq(["obsolete"])
    end

    it "reports a field still waiting for a masking decision" do
      generate_current_config
      rewrite("users") do |config|
        config["fields"].find { |f| f["name"] == "email" }["needs_mask_decision"] = true
      end

      # The flag is on-disk state the merge preserves, so the regenerated copy
      # carries it too: nothing *changed*, but the decision is still owed.
      expect(report["needs_mask_decision"]).to eq(["users.email"])
      expect(report["changed_tables"]).to be_empty
      expect(described_class.clean?(report)).to be(false)
    end

    it "stays clean for a field the committed config deliberately leaves unmasked" do
      # The regeneration runs in safe mode, so it proposes `masked-{_id}@...` for
      # this field; the merge keeps the committed decision (export it raw). Were
      # that not so, every run of the check would report the whole config as
      # changed and there would be no way to record "this field needs no mask".
      generate_current_config
      rewrite("users") do |config|
        config["fields"].find { |f| f["name"] == "email" }["comment"] = "reviewed: exported raw"
      end

      expect(described_class.clean?(report)).to be(true)
    end

    it "leaves the config directory untouched" do
      generate_current_config
      rewrite("users") { |config| config["fields"].reject! { |f| f["name"] == "email" } }
      before = Dir[File.join(schema_dir, "**", "*")].sort.to_h { |path| [path, File.read(path)] }

      report

      after = Dir[File.join(schema_dir, "**", "*")].sort.to_h { |path| [path, File.read(path)] }
      expect(after).to eq(before)
    end

    it "fails loudly on a construct exwiw cannot represent instead of reporting clean" do
      # skip_unsupported is deliberately off in the regenerator: a model change
      # that introduces an unrepresentable construct must break the check with the
      # generator's actionable message, not quietly become an `ignore: true`
      # config that reports clean while the collection stops being dumped.
      checker = described_class.new(
        schema_dir: schema_dir,
        regenerator: described_class.mongoid_regenerator([MongoidDummy::PolymorphicAddress]),
      )

      expect { checker.run }.to raise_error(
        MongoidSchemaGenerator::UnsupportedEmbedding, /polymorphic `embedded_in :addressable`/,
      )
    end
  end
end

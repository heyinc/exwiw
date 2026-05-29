# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "active_record"
require "sqlite3"

require_relative "../script/database_config"

# Synthetic STI fixtures for edge cases where the real script/models.rb
# can't express the scenario (e.g. belongs_to only on parent, distinct
# belongs_tos on different children). Anonymous Class.new doesn't work
# here because AR reflections call `name.demodulize`.
module Exwiw
  module SchemaGeneratorStiFixtures
    class ParentWithBelongsTo < ::ActiveRecord::Base
      self.table_name = "orders"
      self.inheritance_column = nil
      belongs_to :shop, class_name: "::Shop"
    end

    class ChildOfParentWithBelongsTo < ParentWithBelongsTo
    end

    class ParentNoBelongsTo < ::ActiveRecord::Base
      self.table_name = "orders"
      self.inheritance_column = nil
    end

    class ChildBelongsToShop < ParentNoBelongsTo
      belongs_to :shop, class_name: "::Shop"
    end

    class ChildBelongsToUser < ParentNoBelongsTo
      belongs_to :user, class_name: "::User"
    end
  end

  # Real multi-DB setup: two abstract bases each with their own
  # AR connection, exercising connection_specification_name without
  # any stubbing.
  module SchemaGeneratorMultiDbFixtures
    ANALYTICS_DB_PATH = "tmp/test_analytics.sqlite3"

    class PrimaryAbstract < ::ActiveRecord::Base
      self.abstract_class = true
      establish_connection(adapter: "sqlite3", database: database_config("sqlite3").fetch(:database))
    end

    class AnalyticsAbstract < ::ActiveRecord::Base
      self.abstract_class = true
      establish_connection(adapter: "sqlite3", database: ANALYTICS_DB_PATH)
    end

    class PrimaryModel < PrimaryAbstract
      self.table_name = "shops"
    end

    class AnalyticsModel < AnalyticsAbstract
      self.table_name = "analytics_events"
    end
  end

  RSpec.describe SchemaGenerator do
    before(:all) do
      ActiveRecord::Base.establish_connection(database_config(:sqlite3))
      require_relative "../script/models"
    end

    after(:all) do
      ActiveRecord::Base.remove_connection
    end

    let(:models) { ApplicationRecord.descendants + [Transaction] }
    let(:output_dir) { @output_dir }

    around do |ex|
      Dir.mktmpdir do |dir|
        @output_dir = dir
        ex.run
      end
    end

    describe "#build_tables" do
      let(:tables) { described_class.new(models: models, output_dir: output_dir).build_tables }
      let(:tables_by_name) { tables.each_with_object({}) { |t, h| h[t.name] = t } }

      it "covers all non-abstract tables exactly once" do
        expect(tables_by_name.keys).to contain_exactly(
          "shops", "users", "products", "orders", "order_items",
          "transactions", "reviews", "system_announcements",
          "schema_migrations", "ar_internal_metadata",
        )
      end

      it "extracts the primary key" do
        expect(tables_by_name["shops"].primary_key).to eq("id")
      end

      it "extracts non-polymorphic belongs_tos" do
        belongs_tos = tables_by_name["users"].belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["shops", "shop_id"])
      end

      it "extracts column names" do
        expect(tables_by_name["shops"].column_names).to include("id", "name")
      end

      it "skips polymorphic belongs_to but keeps non-polymorphic peers" do
        belongs_tos = tables_by_name["reviews"].belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["users", "user_id"])
      end
    end

    describe "STI belongs_to aggregation" do
      it "aggregates across STI subclasses when parent comes first" do
        ordered_models = [Transaction, PaymentTransaction, RefundTransaction]
        tables = described_class.new(models: ordered_models, output_dir: output_dir).build_tables
        transactions = tables.find { |t| t.name == "transactions" }

        belongs_tos = transactions.belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["orders", "order_id"])
      end

      it "aggregates across STI subclasses when subclasses come first" do
        ordered_models = [PaymentTransaction, RefundTransaction, Transaction]
        tables = described_class.new(models: ordered_models, output_dir: output_dir).build_tables
        transactions = tables.find { |t| t.name == "transactions" }

        belongs_tos = transactions.belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["orders", "order_id"])
      end

      it "captures a belongs_to defined only on the STI parent (inherited via reflection)" do
        models = [
          SchemaGeneratorStiFixtures::ParentWithBelongsTo,
          SchemaGeneratorStiFixtures::ChildOfParentWithBelongsTo,
        ]
        tables = described_class.new(models: models, output_dir: output_dir).build_tables

        belongs_tos = tables.first.belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["shops", "shop_id"])
      end

      it "retains distinct belongs_tos defined on separate STI children" do
        models = [
          SchemaGeneratorStiFixtures::ParentNoBelongsTo,
          SchemaGeneratorStiFixtures::ChildBelongsToShop,
          SchemaGeneratorStiFixtures::ChildBelongsToUser,
        ]
        tables = described_class.new(models: models, output_dir: output_dir).build_tables

        belongs_tos = tables.first.belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["shops", "shop_id"], ["users", "user_id"])
      end
    end

    describe "multi-database detection" do
      before(:all) do
        FileUtils.mkdir_p(File.dirname(SchemaGeneratorMultiDbFixtures::ANALYTICS_DB_PATH))
        # DIRTY: 後にseedで対応するようにする
        SQLite3::Database.new(SchemaGeneratorMultiDbFixtures::ANALYTICS_DB_PATH).execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS analytics_events (id INTEGER PRIMARY KEY);
        SQL
      end

      it "raises when concrete models point to different connection specifications" do
        models = [
          SchemaGeneratorMultiDbFixtures::PrimaryModel,
          SchemaGeneratorMultiDbFixtures::AnalyticsModel,
        ]
        generator = described_class.new(models: models, output_dir: output_dir)
        expect { generator.build_tables }
          .to raise_error(SchemaGenerator::MultipleDatabasesNotSupportedError, /multiple-database/)
      end

      it "does not raise when all models share the same connection specification" do
        generator = described_class.new(models: [Shop, User], output_dir: output_dir)
        expect { generator.build_tables }.not_to raise_error
      end
    end

    describe "#generate!" do
      it "writes one JSON file per table" do
        described_class.new(models: models, output_dir: output_dir).generate!

        expect(Dir[File.join(output_dir, "*.json")].map { |p| File.basename(p) }).to contain_exactly(
          "shops.json", "users.json", "products.json", "orders.json", "order_items.json",
          "transactions.json", "reviews.json", "system_announcements.json",
          "schema_migrations.json", "ar_internal_metadata.json",
        )
      end

      it "preserves user-customized filter on rerun" do
        existing_path = File.join(output_dir, "shops.json")
        existing = {
          "name" => "shops",
          "primary_key" => "id",
          "filter" => "shops.id > 0",
          "belongs_tos" => [],
          "columns" => [{ "name" => "id" }, { "name" => "name" }],
        }
        File.write(existing_path, JSON.pretty_generate(existing))

        described_class.new(models: [Shop], output_dir: output_dir).generate!

        result = JSON.parse(File.read(existing_path))
        expect(result["filter"]).to eq("shops.id > 0")
      end

      it "matches snapshot fixtures" do
        described_class.new(models: models, output_dir: output_dir).generate!

        fixtures = Dir[File.join("spec/schema_output_snapshots", "*.json")].sort
        expect(fixtures).not_to be_empty, "no snapshot fixtures found under spec/schema_output_snapshots"

        fixtures.each do |fixture_path|
          actual_path = File.join(output_dir, File.basename(fixture_path))
          expect(File).to exist(actual_path), "missing generated file: #{actual_path}"

          actual = JSON.parse(File.read(actual_path))
          expected = JSON.parse(File.read(fixture_path))
          expect(actual).to eq(expected), "snapshot mismatch in #{File.basename(fixture_path)}"
        end
      end
    end
  end
end

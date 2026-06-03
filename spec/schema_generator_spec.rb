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

    # Composite primary key model. `representative.primary_key` returns an Array
    # for these, which exwiw does not support; the generator must mark them
    # ignore:true instead of raising on the TableConfig type check.
    class CompositePkRecord < ::ActiveRecord::Base
      self.table_name = "composite_pk_records"
      self.primary_key = [:organization_id, :location_id]
    end
  end

  # Real Rails multi-DB setup: two abstract bases wired through
  # `connects_to` against named entries in `ActiveRecord::Base.configurations`,
  # exactly as a `database.yml`-backed app would. This makes
  # `connection_db_config.name` return "primary" / "analytics", which is what
  # SchemaGenerator uses to bucket tables into per-database directories.
  module SchemaGeneratorMultiDbFixtures
    PRIMARY_DB_PATH = "tmp/test_multidb_primary.sqlite3"
    ANALYTICS_DB_PATH = "tmp/test_multidb_analytics.sqlite3"

    CONFIGURATIONS = {
      "test" => {
        "primary"   => { "adapter" => "sqlite3", "database" => PRIMARY_DB_PATH },
        "analytics" => { "adapter" => "sqlite3", "database" => ANALYTICS_DB_PATH },
      },
    }.freeze

    module_function

    # `connects_to` resolves against `ActiveRecord::Base.configurations` at
    # class-definition time, so the fixture classes are defined lazily — only
    # after the surrounding example group has set configurations and RAILS_ENV.
    def setup!
      FileUtils.mkdir_p("tmp")
      [PRIMARY_DB_PATH, ANALYTICS_DB_PATH].each { |p| File.delete(p) if File.exist?(p) }

      SQLite3::Database.new(PRIMARY_DB_PATH).execute_batch(<<~SQL)
        CREATE TABLE shops (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE schema_migrations (version TEXT NOT NULL PRIMARY KEY);
      SQL
      # Each database in a Rails multi-DB setup keeps its own migration
      # history, so analytics also gets a schema_migrations table.
      SQLite3::Database.new(ANALYTICS_DB_PATH).execute_batch(<<~SQL)
        CREATE TABLE analytics_events (id INTEGER PRIMARY KEY);
        CREATE TABLE schema_migrations (version TEXT NOT NULL PRIMARY KEY);
      SQL

      define_models!
    end

    def define_models!
      return if const_defined?(:PrimaryModel, false)

      # `connects_to` rejects anonymous classes, so name the class via
      # const_set before wiring the connection.
      primary_abstract = Class.new(::ActiveRecord::Base) { self.abstract_class = true }
      const_set(:PrimaryAbstract, primary_abstract)
      primary_abstract.connects_to(database: { writing: :primary })

      analytics_abstract = Class.new(::ActiveRecord::Base) { self.abstract_class = true }
      const_set(:AnalyticsAbstract, analytics_abstract)
      analytics_abstract.connects_to(database: { writing: :analytics })

      const_set(:PrimaryModel, Class.new(primary_abstract) { self.table_name = "shops" })
      const_set(:AnalyticsModel, Class.new(analytics_abstract) { self.table_name = "analytics_events" })
    end
  end

  RSpec.describe SchemaGenerator do
    before(:all) do
      ActiveRecord::Base.establish_connection(database_config(:sqlite))
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

      it "expands a polymorphic belongs_to into one entry per target table" do
        review = tables_by_name["reviews"]
        non_poly = review.belongs_tos.reject(&:polymorphic?).map { |b| [b.table_name, b.foreign_key] }
        poly = review.belongs_tos.select(&:polymorphic?)
          .map { |b| [b.table_name, b.foreign_key, b.foreign_type, b.type_value] }

        # `reviewable` is registered on both Product and Shop (`has_many :reviews,
        # as: :reviewable`), so a single polymorphic association expands into one
        # belongs_to per target, each carrying its own type_value.
        expect(non_poly).to contain_exactly(["users", "user_id"])
        expect(poly).to contain_exactly(
          ["products", "reviewable_id", "reviewable_type", "Product"],
          ["shops", "reviewable_id", "reviewable_type", "Shop"],
        )
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

    describe "composite primary key" do
      before(:all) do
        ActiveRecord::Base.connection.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS composite_pk_records (
            organization_id INTEGER NOT NULL,
            location_id INTEGER NOT NULL,
            name TEXT,
            PRIMARY KEY (organization_id, location_id)
          )
        SQL
      end

      after(:all) do
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS composite_pk_records")
      end

      let(:table) do
        described_class
          .new(models: [SchemaGeneratorStiFixtures::CompositePkRecord], output_dir: output_dir)
          .build_tables
          .find { |t| t.name == "composite_pk_records" }
      end

      it "emits the table with ignore:true and no primary_key" do
        expect(table.ignore).to eq(true)
        expect(table.primary_key).to be_nil
      end

      it "tags the table with the unsupported_composite_primary_key type" do
        expect(table.type).to eq(TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY)
      end

      it "records that exwiw does not support composite primary keys in the comment" do
        expect(table.comment).to include("does not support composite primary keys")
        expect(table.comment).to include("organization_id", "location_id")
      end

      it "still captures columns" do
        expect(table.column_names).to include("organization_id", "location_id", "name")
      end
    end

    describe "multi-database support" do
      before(:all) do
        @previous_env = ENV["RAILS_ENV"]
        @previous_configs = ActiveRecord::Base.configurations
        ENV["RAILS_ENV"] = "test"
        ActiveRecord::Base.configurations = SchemaGeneratorMultiDbFixtures::CONFIGURATIONS
        SchemaGeneratorMultiDbFixtures.setup!
      end

      after(:all) do
        ActiveRecord::Base.configurations = @previous_configs
        ENV["RAILS_ENV"] = @previous_env
      end

      let(:multidb_models) do
        [
          SchemaGeneratorMultiDbFixtures::PrimaryModel,
          SchemaGeneratorMultiDbFixtures::AnalyticsModel,
        ]
      end

      describe "#build_table_groups" do
        let(:groups) { described_class.new(models: multidb_models, output_dir: output_dir).build_table_groups }

        it "buckets tables by their database config name" do
          expect(groups.keys).to contain_exactly("primary", "analytics")
        end

        it "places each model's table in its own database group" do
          expect(groups["primary"].map(&:name)).to include("shops")
          expect(groups["analytics"].map(&:name)).to include("analytics_events")
        end

        it "emits each database's own rails-managed schema_migrations table" do
          expect(groups["primary"].map(&:name)).to include("schema_migrations")
          expect(groups["analytics"].map(&:name)).to include("schema_migrations")
        end

        it "collapses into a single nil-keyed group for a single-database setup" do
          single = described_class.new(models: [SchemaGeneratorMultiDbFixtures::PrimaryModel], output_dir: output_dir)
          expect(single.build_table_groups.keys).to eq([nil])
        end
      end

      describe "#generate!" do
        it "writes each database's tables into its own subdirectory" do
          described_class.new(models: multidb_models, output_dir: output_dir).generate!

          expect(Dir[File.join(output_dir, "primary", "*.json")].map { |p| File.basename(p) })
            .to contain_exactly("shops.json", "schema_migrations.json")
          expect(Dir[File.join(output_dir, "analytics", "*.json")].map { |p| File.basename(p) })
            .to contain_exactly("analytics_events.json", "schema_migrations.json")
        end
      end

      describe "#tidy!" do
        it "tidies each database's own subdirectory" do
          described_class.new(models: multidb_models, output_dir: output_dir).generate!
          stale_path = File.join(output_dir, "primary", "legacy_things.json")
          File.write(stale_path, JSON.pretty_generate(
            "name" => "legacy_things",
            "primary_key" => "id",
            "belongs_tos" => [],
            "columns" => [{ "name" => "id" }],
          ) + "\n")

          result = described_class.new(models: multidb_models, output_dir: output_dir).tidy!

          expect(File).not_to exist(stale_path)
          expect(File).to exist(File.join(output_dir, "primary", "shops.json"))
          expect(File).to exist(File.join(output_dir, "analytics", "analytics_events.json"))
          expect(result.removed_tables).to contain_exactly("legacy_things")
        end
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

    describe "#tidy!" do
      def write_config(name, hash)
        File.write(File.join(output_dir, "#{name}.json"), JSON.pretty_generate(hash) + "\n")
      end

      it "deletes the config file of a table that no longer exists" do
        described_class.new(models: models, output_dir: output_dir).generate!
        write_config("legacy_things", {
          "name" => "legacy_things",
          "primary_key" => "id",
          "belongs_tos" => [],
          "columns" => [{ "name" => "id" }, { "name" => "value" }],
        })

        result = described_class.new(models: models, output_dir: output_dir).tidy!

        expect(File).not_to exist(File.join(output_dir, "legacy_things.json"))
        expect(File).to exist(File.join(output_dir, "shops.json"))
        expect(result.removed_tables).to contain_exactly("legacy_things")
        expect(result.removed_columns).to be_empty
      end

      it "drops columns that the table no longer has from a surviving config" do
        write_config("shops", {
          "name" => "shops",
          "primary_key" => "id",
          "belongs_tos" => [],
          "columns" => [
            { "name" => "id" },
            { "name" => "name", "replace_with" => "masked" },
            { "name" => "ghost_column" },
          ],
        })

        result = described_class.new(models: [Shop], output_dir: output_dir).tidy!

        written = JSON.parse(File.read(File.join(output_dir, "shops.json")))
        expect(written["columns"].map { |c| c["name"] }).not_to include("ghost_column")
        expect(written["columns"].map { |c| c["name"] }).to include("id", "name")
        expect(result.removed_columns).to eq("shops" => ["ghost_column"])
        expect(result.removed_tables).to be_empty
      end

      it "preserves hand-edited attributes on surviving columns" do
        write_config("shops", {
          "name" => "shops",
          "primary_key" => "id",
          "belongs_tos" => [],
          "columns" => [
            { "name" => "id" },
            { "name" => "name", "replace_with" => "masked", "comment" => "PII" },
            { "name" => "ghost_column" },
          ],
        })

        described_class.new(models: [Shop], output_dir: output_dir).tidy!

        written = JSON.parse(File.read(File.join(output_dir, "shops.json")))
        name_column = written["columns"].find { |c| c["name"] == "name" }
        expect(name_column["replace_with"]).to eq("masked")
        expect(name_column["comment"]).to eq("PII")
      end

      it "reports nothing and leaves files intact when the config already matches the schema" do
        described_class.new(models: models, output_dir: output_dir).generate!
        before = Dir[File.join(output_dir, "*.json")].sort.map { |p| [File.basename(p), File.read(p)] }

        result = described_class.new(models: models, output_dir: output_dir).tidy!

        expect(result).to be_empty
        after = Dir[File.join(output_dir, "*.json")].sort.map { |p| [File.basename(p), File.read(p)] }
        expect(after).to eq(before)
      end

      # tidy reconciles against the live database, not against the models. A
      # table that still exists in the database but has lost (or never had) a
      # model must keep its config; only its genuinely-absent columns are
      # pruned. Reconciling against `build_table_groups` (model-driven) would
      # wrongly delete this config file.
      context "for a table that exists in the database but has no model" do
        before(:all) do
          ActiveRecord::Base.connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS orphan_records (
              id INTEGER PRIMARY KEY,
              kept TEXT
            )
          SQL
        end

        after(:all) do
          ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS orphan_records")
        end

        it "keeps the config and prunes only the columns missing from the database" do
          write_config("orphan_records", {
            "name" => "orphan_records",
            "primary_key" => "id",
            "belongs_tos" => [],
            "columns" => [
              { "name" => "id" },
              { "name" => "kept", "replace_with" => "masked" },
              { "name" => "ghost_column" },
            ],
          })

          # No model maps to orphan_records, so a model-driven reconcile would
          # delete the file. Pass only Shop to make that unambiguous.
          result = described_class.new(models: [Shop], output_dir: output_dir).tidy!

          path = File.join(output_dir, "orphan_records.json")
          expect(File).to exist(path)
          expect(result.removed_tables).to be_empty

          written = JSON.parse(File.read(path))
          column_names = written["columns"].map { |c| c["name"] }
          expect(column_names).to include("id", "kept")
          expect(column_names).not_to include("ghost_column")
          expect(written["columns"].find { |c| c["name"] == "kept" }["replace_with"]).to eq("masked")
          expect(result.removed_columns).to eq("orphan_records" => ["ghost_column"])
        end
      end
    end
  end
end

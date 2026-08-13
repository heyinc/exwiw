# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

require_relative "support/db_fixtures"

module Exwiw
  # Tables the generator is exercised against. `orders` is the interesting one:
  # its `shop_id` is backed by a foreign-key constraint, while `buyer_id` is the
  # kind of relation that exists only in application code — no constraint, so
  # introspection cannot discover it and the config must carry it by hand.
  module DbSchemaGeneratorFixtures
    PREFIX = "gen_fixture"

    MYSQL_DDL = <<~SQL
      CREATE TABLE #{PREFIX}_shops (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(255) NOT NULL
      );
      CREATE TABLE #{PREFIX}_buyers (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        email VARCHAR(255) NOT NULL
      );
      CREATE TABLE #{PREFIX}_orders (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        shop_id BIGINT NOT NULL,
        buyer_id BIGINT NOT NULL,
        memo VARCHAR(255),
        CONSTRAINT #{PREFIX}_orders_shop FOREIGN KEY (shop_id) REFERENCES #{PREFIX}_shops (id)
      );
      CREATE TABLE #{PREFIX}_keyless (
        value VARCHAR(255)
      );
      CREATE TABLE #{PREFIX}_composites (
        organization_id BIGINT NOT NULL,
        location_id BIGINT NOT NULL,
        name VARCHAR(255),
        PRIMARY KEY (organization_id, location_id)
      );
    SQL

    POSTGRESQL_DDL = <<~SQL
      CREATE TABLE #{PREFIX}_shops (
        id BIGSERIAL PRIMARY KEY,
        name CHARACTER VARYING(255) NOT NULL
      );
      CREATE TABLE #{PREFIX}_buyers (
        id BIGSERIAL PRIMARY KEY,
        email CHARACTER VARYING(255) NOT NULL
      );
      CREATE TABLE #{PREFIX}_orders (
        id BIGSERIAL PRIMARY KEY,
        shop_id BIGINT NOT NULL REFERENCES #{PREFIX}_shops (id),
        buyer_id BIGINT NOT NULL,
        memo CHARACTER VARYING(255)
      );
      CREATE TABLE #{PREFIX}_keyless (
        value CHARACTER VARYING(255)
      );
      CREATE TABLE #{PREFIX}_composites (
        organization_id BIGINT NOT NULL,
        location_id BIGINT NOT NULL,
        name CHARACTER VARYING(255),
        PRIMARY KEY (organization_id, location_id)
      );
    SQL

    DROP_SQL = <<~SQL
      DROP TABLE IF EXISTS #{PREFIX}_orders;
      DROP TABLE IF EXISTS #{PREFIX}_keyless;
      DROP TABLE IF EXISTS #{PREFIX}_composites;
      DROP TABLE IF EXISTS #{PREFIX}_buyers;
      DROP TABLE IF EXISTS #{PREFIX}_shops;
    SQL

    module_function

    def setup!(adapter)
      DbFixtures.execute(adapter, DROP_SQL)
      DbFixtures.execute(adapter, adapter.to_s == "mysql" ? MYSQL_DDL : POSTGRESQL_DDL)
    end

    def teardown!(adapter)
      DbFixtures.execute(adapter, DROP_SQL)
    end
  end

  RSpec.describe DbSchemaGenerator do
    shared_examples "a schema generator reading a database" do |adapter|
      prefix = DbSchemaGeneratorFixtures::PREFIX

      before(:all) { DbSchemaGeneratorFixtures.setup!(adapter) }
      after(:all) { DbSchemaGeneratorFixtures.teardown!(adapter) }

      let(:introspector) { DbIntrospector.build(DbFixtures.connection_config(adapter)) }
      let(:output_dir) { @output_dir }

      around do |ex|
        Dir.mktmpdir do |dir|
          @output_dir = dir
          ex.run
        end
      end

      def generate(safe_new_columns: true)
        described_class.new(
          introspector: introspector, output_dir: output_dir, safe_new_columns: safe_new_columns,
        ).generate!
      end

      def tidy
        described_class.new(introspector: introspector, output_dir: output_dir).tidy!
      end

      def config_path(table_name)
        File.join(output_dir, "#{table_name}.json")
      end

      def config_for(table_name)
        JSON.parse(File.read(config_path(table_name)))
      end

      def write_config(table_name, hash)
        File.write(config_path(table_name), JSON.pretty_generate(hash) + "\n")
      end

      describe "#generate!" do
        it "writes one JSON file per table in the database" do
          generate

          written = Dir[File.join(output_dir, "*.json")].map { |path| File.basename(path, ".json") }
          expect(written).to include(
            "#{prefix}_shops", "#{prefix}_buyers", "#{prefix}_orders",
            "#{prefix}_keyless", "#{prefix}_composites",
          )
        end

        it "extracts the primary key and the foreign-key-backed belongs_tos" do
          generate

          config = config_for("#{prefix}_orders")
          expect(config["primary_key"]).to eq("id")
          expect(config["belongs_tos"]).to eq([{ "foreign_key" => "shop_id", "table_name" => "#{prefix}_shops" }])
        end

        it "masks a column with a default its type can hold and flags it for a decision" do
          generate

          memo = config_for("#{prefix}_orders")["columns"].find { |c| c["name"] == "memo" }
          expect(memo).to eq({ "name" => "memo", "replace_with" => "masked-{id}", "needs_mask_decision" => true })
        end

        it "never masks the primary key or a belongs_to's foreign key, which the joins need" do
          generate

          columns = config_for("#{prefix}_orders")["columns"].to_h { |c| [c["name"], c] }
          expect(columns["id"]).to eq({ "name" => "id", "needs_mask_decision" => true })
          expect(columns["shop_id"]).to eq({ "name" => "shop_id", "needs_mask_decision" => true })
        end

        it "emits plain column entries when safe mode is off" do
          generate(safe_new_columns: false)

          expect(config_for("#{prefix}_shops")["columns"])
            .to eq([{ "name" => "id" }, { "name" => "name" }])
        end

        it "emits a composite-primary-key table as unsupported and ignored" do
          generate

          config = config_for("#{prefix}_composites")
          expect(config["type"]).to eq(TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY)
          expect(config["ignore"]).to be(true)
          expect(config["primary_key"]).to be_nil
          expect(config["comment"]).to include("does not support composite primary keys",
                                               "organization_id", "location_id")
          expect(config["columns"].map { |c| c["name"] }).to include("organization_id", "location_id", "name")
        end

        it "emits a table without a primary key as ignored, saying what to add to export it" do
          generate

          config = config_for("#{prefix}_keyless")
          expect(config["ignore"]).to be(true)
          expect(config["primary_key"]).to be_nil
          expect(config["comment"]).to include("no primary key", "`primary_key`", "remove `ignore`")
          expect(config["columns"].map { |c| c["name"] }).to eq(["value"])
        end

        # The two signposts above tell the user to name a primary key by hand,
        # which is only worth doing if the next run keeps it: the database still
        # reports none, so nothing but the config itself records the decision.
        it "keeps a primary key declared by hand on a table the database has none for" do
          generate
          config = config_for("#{prefix}_keyless")
          config.delete("ignore")
          config.delete("comment")
          config["primary_key"] = "value"
          write_config("#{prefix}_keyless", config)

          generate

          regenerated = config_for("#{prefix}_keyless")
          expect(regenerated["primary_key"]).to eq("value")
          expect(regenerated).not_to have_key("ignore")
          # The table is now an ordinary one, so its columns are masked like any
          # other rather than being emitted as bare names.
          expect(regenerated["columns"].map { |c| c["name"] }).to eq(["value"])
        end

        it "keeps a primary key declared by hand on a composite-primary-key table" do
          generate
          config = config_for("#{prefix}_composites")
          config.delete("ignore")
          config.delete("type")
          config.delete("comment")
          config["primary_key"] = "organization_id"
          write_config("#{prefix}_composites", config)

          generate

          regenerated = config_for("#{prefix}_composites")
          expect(regenerated["primary_key"]).to eq("organization_id")
          expect(regenerated).not_to have_key("type")
          expect(regenerated).not_to have_key("ignore")
        end

        it "keeps a masking decision a human already made" do
          generate
          config = config_for("#{prefix}_orders")
          config["columns"] = config["columns"].map do |column|
            case column["name"]
            when "memo" then { "name" => "memo", "replace_with" => "redacted", "comment" => "PII" }
            else column.reject { |key, _| key == "needs_mask_decision" }
            end
          end
          write_config("#{prefix}_orders", config)

          generate

          memo = config_for("#{prefix}_orders")["columns"].find { |c| c["name"] == "memo" }
          expect(memo).to eq({ "name" => "memo", "replace_with" => "redacted", "comment" => "PII" })
        end

        it "leaves a column deliberately unmasked unmasked" do
          generate
          config = config_for("#{prefix}_orders")
          config["columns"] = config["columns"].map { |c| c.slice("name") }
          write_config("#{prefix}_orders", config)

          generate

          memo = config_for("#{prefix}_orders")["columns"].find { |c| c["name"] == "memo" }
          expect(memo).to eq({ "name" => "memo" })
        end

        it "preserves a user-customized filter on rerun" do
          generate
          config = config_for("#{prefix}_shops").merge("filter" => "#{prefix}_shops.id > 0")
          write_config("#{prefix}_shops", config)

          generate

          expect(config_for("#{prefix}_shops")["filter"]).to eq("#{prefix}_shops.id > 0")
        end
      end

      # The regression this generator exists to avoid: a relation that only the
      # application knows about has no constraint to rediscover it from, so
      # regenerating must add to the declared belongs_tos rather than replace
      # them.
      describe "#generate! with a hand-written belongs_to" do
        let(:declared_belongs_to) do
          {
            "table_name" => "#{prefix}_buyers",
            "foreign_key" => "buyer_id",
            "comment" => "declared in the application, no foreign key in the database",
          }
        end

        before do
          write_config("#{prefix}_orders", {
            "name" => "#{prefix}_orders",
            "primary_key" => "id",
            "belongs_tos" => [declared_belongs_to],
            "columns" => %w[id shop_id buyer_id memo].map { |name| { "name" => name } },
          })
        end

        it "keeps the hand-written relation, with its comment, in its on-disk position" do
          generate

          expect(config_for("#{prefix}_orders")["belongs_tos"].first).to eq(declared_belongs_to)
        end

        it "adds the foreign-key-backed relation alongside it" do
          generate

          expect(config_for("#{prefix}_orders")["belongs_tos"]).to eq([
            declared_belongs_to,
            { "foreign_key" => "shop_id", "table_name" => "#{prefix}_shops" },
          ])
        end

        it "does not mask the hand-declared relation's foreign key" do
          generate

          buyer_id = config_for("#{prefix}_orders")["columns"].find { |c| c["name"] == "buyer_id" }
          expect(buyer_id).to eq({ "name" => "buyer_id" })
        end

        it "adds the relation only once, however often it is regenerated" do
          generate
          generate

          expect(config_for("#{prefix}_orders")["belongs_tos"].size).to eq(2)
        end

        it "keeps an ignored relation ignored rather than re-adding it as live" do
          write_config("#{prefix}_orders", {
            "name" => "#{prefix}_orders",
            "primary_key" => "id",
            "belongs_tos" => [{
              "table_name" => "#{prefix}_shops",
              "foreign_key" => "shop_id",
              "ignore" => true,
              "ignore_type" => "unsupported",
            }],
            "columns" => %w[id shop_id buyer_id memo].map { |name| { "name" => name } },
          })

          generate

          belongs_tos = config_for("#{prefix}_orders")["belongs_tos"]
          expect(belongs_tos.size).to eq(1)
          expect(belongs_tos.first).to include("ignore" => true, "ignore_type" => "unsupported")
        end
      end

      describe "#tidy!" do
        it "deletes the config file of a table that no longer exists" do
          generate
          write_config("#{prefix}_legacy", {
            "name" => "#{prefix}_legacy",
            "primary_key" => "id",
            "belongs_tos" => [],
            "columns" => [{ "name" => "id" }],
          })

          result = tidy

          expect(File).not_to exist(config_path("#{prefix}_legacy"))
          expect(File).to exist(config_path("#{prefix}_shops"))
          expect(result.removed_tables).to contain_exactly("#{prefix}_legacy")
        end

        it "drops a column the table no longer has, keeping hand-edited attributes on the rest" do
          write_config("#{prefix}_shops", {
            "name" => "#{prefix}_shops",
            "primary_key" => "id",
            "belongs_tos" => [],
            "columns" => [
              { "name" => "id" },
              { "name" => "name", "replace_with" => "masked", "comment" => "PII" },
              { "name" => "ghost_column" },
            ],
          })

          result = tidy

          columns = config_for("#{prefix}_shops")["columns"]
          expect(columns.map { |c| c["name"] }).to contain_exactly("id", "name")
          expect(columns.find { |c| c["name"] == "name" })
            .to eq({ "name" => "name", "replace_with" => "masked", "comment" => "PII" })
          expect(result.removed_columns).to eq("#{prefix}_shops" => ["ghost_column"])
        end

        # Generation can only add relations, so a belongs_to left pointing at a
        # dropped table would survive forever — and a belongs_to with no target
        # table crashes dependency resolution.
        it "drops a belongs_to whose target table is gone" do
          write_config("#{prefix}_orders", {
            "name" => "#{prefix}_orders",
            "primary_key" => "id",
            "belongs_tos" => [
              { "table_name" => "#{prefix}_shops", "foreign_key" => "shop_id" },
              { "table_name" => "#{prefix}_vanished", "foreign_key" => "vanished_id" },
            ],
            "columns" => [{ "name" => "id" }, { "name" => "shop_id" }],
          })

          result = tidy

          belongs_tos = config_for("#{prefix}_orders")["belongs_tos"]
          expect(belongs_tos.map { |b| b["table_name"] }).to eq(["#{prefix}_shops"])
          expect(result.removed_belongs_tos).to eq("#{prefix}_orders" => ["#{prefix}_vanished"])
        end

        it "keeps an ignored belongs_to whose target is gone, since it records a decision" do
          write_config("#{prefix}_orders", {
            "name" => "#{prefix}_orders",
            "primary_key" => "id",
            "belongs_tos" => [
              { "table_name" => "#{prefix}_vanished", "foreign_key" => "vanished_id", "ignore" => true },
            ],
            "columns" => [{ "name" => "id" }],
          })

          result = tidy

          expect(config_for("#{prefix}_orders")["belongs_tos"].map { |b| b["table_name"] })
            .to eq(["#{prefix}_vanished"])
          expect(result.removed_belongs_tos).to be_empty
        end

        it "reports nothing and leaves the files intact when the config already matches" do
          generate
          before = Dir[File.join(output_dir, "*.json")].sort.map { |path| [path, File.read(path)] }

          result = tidy

          expect(result).to be_empty
          expect(Dir[File.join(output_dir, "*.json")].sort.map { |path| [path, File.read(path)] }).to eq(before)
        end
      end

      # generate -> schema change -> tidy against real DDL, rather than against
      # hand-written config naming tables that never existed.
      describe "reconciling the config after a real schema change" do
        it "deletes the config of a dropped table and prunes a dropped column" do
          generate
          expect(File).to exist(config_path("#{prefix}_buyers"))

          DbFixtures.execute(adapter, "DROP TABLE #{prefix}_buyers")
          DbFixtures.execute(adapter, "ALTER TABLE #{prefix}_shops DROP COLUMN name")
          begin
            result = tidy

            expect(File).not_to exist(config_path("#{prefix}_buyers"))
            expect(config_for("#{prefix}_shops")["columns"].map { |c| c["name"] }).to eq(["id"])
            expect(result.removed_tables).to contain_exactly("#{prefix}_buyers")
            expect(result.removed_columns).to eq("#{prefix}_shops" => ["name"])
          ensure
            DbSchemaGeneratorFixtures.setup!(adapter)
          end
        end
      end
    end

    describe "against mysql" do
      include_examples "a schema generator reading a database", :mysql
    end

    describe "against postgresql" do
      include_examples "a schema generator reading a database", :postgresql
    end
  end
end

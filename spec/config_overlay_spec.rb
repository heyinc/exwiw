# frozen_string_literal: true

require "spec_helper"

module Exwiw
  RSpec.describe ConfigOverlay do
    let(:base) do
      {
        "name" => "users",
        "primary_key" => "id",
        "filter" => "users.active = 1",
        "belongs_tos" => [
          { "table_name" => "shops", "foreign_key" => "shop_id" },
          { "table_name" => "products", "foreign_key" => "item_id", "foreign_type" => "item_type", "type_value" => "Product" },
        ],
        "columns" => [
          { "name" => "id" },
          { "name" => "name", "raw_sql" => "('masked' || users.id)" },
          { "name" => "email", "replace_with" => "masked{id}@example.com", "comment" => "keep" },
          { "name" => "shop_id" },
        ],
        "batch_scope" => { "table" => "shops", "size" => 10 },
      }
    end

    def merge(overlay, klass = TableConfig, base_config = base)
      described_class.merge(klass, base_config, overlay, owner: "overlay users.dev.json")
    end

    describe ".merge" do
      it "replaces scalars and leaves untouched keys as in the base" do
        merged = merge("name" => "users", "filter" => "users.id < 100", "ignore" => true)

        expect(merged).to eq(base.merge("filter" => "users.id < 100", "ignore" => true))
      end

      it "replaces a nested object as a whole" do
        merged = merge("name" => "users", "batch_scope" => { "table" => "shops" })

        expect(merged["batch_scope"]).to eq("table" => "shops")
      end

      it "merges list elements matched by key, keeping the base order" do
        merged = merge("name" => "users", "columns" => [
          { "name" => "shop_id", "comment" => "fk" },
          { "name" => "id", "ignore" => true },
        ])

        expect(merged["columns"].map { |c| c["name"] }).to eq(%w[id name email shop_id])
        expect(merged["columns"][0]).to eq("name" => "id", "ignore" => true)
        expect(merged["columns"][3]).to eq("name" => "shop_id", "comment" => "fk")
      end

      it "matches belongs_tos by table_name, foreign_key, foreign_type and type_value" do
        merged = merge("name" => "users", "belongs_tos" => [
          { "table_name" => "products", "foreign_key" => "item_id", "foreign_type" => "item_type",
            "type_value" => "Product", "ignore" => true },
        ])

        expect(merged["belongs_tos"][1]).to include("ignore" => true)
        expect(merged["belongs_tos"][0]).to eq(base["belongs_tos"][0])
      end

      it "drops the other mask keys when an overlay sets one of them" do
        merged = merge("name" => "users", "columns" => [
          { "name" => "name", "replace_with" => "anonymous" },
          { "name" => "email", "raw_sql" => "'x'" },
        ])

        expect(merged["columns"][1]).to eq("name" => "name", "replace_with" => "anonymous")
        expect(merged["columns"][2]).to eq("name" => "email", "raw_sql" => "'x'", "comment" => "keep")
      end

      it "makes generate replace the base's other mask keys, and the other way round" do
        merged = merge("name" => "users", "columns" => [
          { "name" => "name", "generate" => "random:8" },
          { "name" => "email", "generate" => "random:8" },
        ])

        expect(merged["columns"][1]).to eq("name" => "name", "generate" => "random:8")
        expect(merged["columns"][2]).to eq("name" => "email", "generate" => "random:8", "comment" => "keep")

        generated_base = base.merge("columns" => [{ "name" => "id" }, { "name" => "token", "generate" => "random:8" }])
        merged = merge({ "name" => "users", "columns" => [{ "name" => "token", "replace_with" => "x" }] },
                       TableConfig, generated_base)
        expect(merged["columns"][1]).to eq("name" => "token", "replace_with" => "x")
      end

      it "keeps generate when the overlay only sets a comment" do
        generated_base = base.merge("columns" => [{ "name" => "id" }, { "name" => "token", "generate" => "random:8" }])
        merged = merge({ "name" => "users", "columns" => [{ "name" => "token", "comment" => "c" }] },
                       TableConfig, generated_base)

        expect(merged["columns"][1]).to eq("name" => "token", "generate" => "random:8", "comment" => "c")
      end

      it "removes generate when the overlay sets it to null" do
        generated_base = base.merge("columns" => [{ "name" => "id" }, { "name" => "token", "generate" => "random:8" }])
        merged = merge({ "name" => "users", "columns" => [{ "name" => "token", "generate" => nil }] },
                       TableConfig, generated_base)

        expect(merged["columns"][1]).to eq("name" => "token")
      end

      it "merges generate on a MongoDB field with the mask group" do
        mongo_base = {
          "name" => "users", "primary_key" => "_id", "belongs_tos" => [],
          "fields" => [{ "name" => "_id" }, { "name" => "token", "replace_with" => "x" }],
        }
        merged = merge({ "name" => "users", "fields" => [{ "name" => "token", "generate" => "random:8" }] },
                       MongodbCollectionConfig, mongo_base)

        expect(merged["fields"][1]).to eq("name" => "token", "generate" => "random:8")
      end

      it "removes an optional key set to null" do
        merged = merge("name" => "users", "filter" => nil, "columns" => [{ "name" => "email", "replace_with" => nil }])

        expect(merged).not_to have_key("filter")
        expect(merged["columns"][2]).to eq("name" => "email", "comment" => "keep")
      end

      it "rejects an unknown key" do
        expect { merge("name" => "users", "filtr" => "x") }
          .to raise_error(UnknownConfigKeyError, /Unknown key 'filtr' in overlay users.dev.json/)
      end

      it "rejects a changed or null name" do
        expect { merge("name" => "accounts") }.to raise_error(ArgumentError, /'name' identifies the config/)
        expect { merge("name" => nil) }.to raise_error(ArgumentError, /'name' identifies the config/)
      end

      it "rejects null on a list" do
        expect { merge("name" => "users", "columns" => nil) }
          .to raise_error(ArgumentError, /'columns' is a list and cannot be set to null/)
      end

      it "rejects null on a required key" do
        mongo_base = { "name" => "users", "primary_key" => "_id", "belongs_tos" => [], "fields" => [] }

        expect { merge({ "name" => "users", "primary_key" => nil }, MongodbCollectionConfig, mongo_base) }
          .to raise_error(ArgumentError, /'primary_key' is required and cannot be set to null/)
      end

      it "rejects a list element the base does not have" do
        expect { merge("name" => "users", "columns" => [{ "name" => "legacy" }]) }
          .to raise_error(ArgumentError, /'columns.legacy' does not exist in the base config/)
        expect { merge("name" => "users", "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "owner_id" }]) }
          .to raise_error(ArgumentError, /'belongs_tos\[table_name=shops,foreign_key=owner_id\]' does not exist/)
      end

      it "rejects the same list element twice" do
        expect { merge("name" => "users", "columns" => [{ "name" => "id" }, { "name" => "id" }]) }
          .to raise_error(ArgumentError, /'columns.id' appears more than once/)
      end

      it "rejects a list that is not a list of objects" do
        expect { merge("name" => "users", "columns" => { "name" => "id" }) }
          .to raise_error(ArgumentError, /'columns' must be a list/)
        expect { merge("name" => "users", "columns" => ["id"]) }
          .to raise_error(ArgumentError, /'columns\[0\]' must be a JSON object/)
      end

      it "merges a MongoDB collection's fields with the mask group" do
        mongo_base = {
          "name" => "users",
          "primary_key" => "_id",
          "belongs_tos" => [],
          "fields" => [
            { "name" => "_id" },
            { "name" => "email", "replace_with" => "masked{_id}@example.com" },
          ],
        }
        overlay = {
          "name" => "users",
          "fields" => [{ "name" => "email", "replace_with_fake_data" => { "seed" => "_id", "type" => "email" } }],
        }

        merged = merge(overlay, MongodbCollectionConfig, mongo_base)

        expect(merged["fields"][1]).to eq("name" => "email",
                                          "replace_with_fake_data" => { "seed" => "_id", "type" => "email" })
      end

      it "fails safe on a list attribute without a list annotation" do
        unannotated = Class.new do
          include Serdes

          attribute :name, String, merge: :identity
          attribute :items, array(TableColumn), default: []
        end

        expect { described_class.merge(unannotated, { "name" => "x", "items" => [] }, { "name" => "x", "items" => [] }, owner: "o") }
          .to raise_error(ArgumentError, /without a `merge: \{ list: ... \}` annotation/)
      end
    end

    describe "annotations" do
      [TableConfig, MongodbCollectionConfig].each do |klass|
        it "declares a list key on every list attribute the merge can reach from #{klass}" do
          reachable = described_class.reachable_array_attributes(klass)

          expect(reachable).not_to be_empty
          reachable.each do |owner, attr|
            expect(described_class.list_keys(attr)).not_to be_nil, "#{owner}##{attr.name} has no list key"
          end
        end
      end
    end

    describe ".validate_unique_keys!" do
      it "rejects two list entries with the same key" do
        config = base.merge("belongs_tos" => [base["belongs_tos"][0], base["belongs_tos"][0].merge("comment" => "x")])

        expect { described_class.validate_unique_keys!(TableConfig, config, owner: "users.json") }
          .to raise_error(ArgumentError, /users.json has more than one belongs_tos\[table_name=shops,foreign_key=shop_id\] entry/)
      end

      it "accepts unique keys" do
        expect { described_class.validate_unique_keys!(TableConfig, base, owner: "users.json") }.not_to raise_error
      end
    end

    describe ".prune" do
      it "removes the entries whose key the base no longer has, keeping the rest as written" do
        overlay = {
          "name" => "users",
          "filter" => nil,
          "columns" => [{ "name" => "legacy", "raw_sql" => "'x'" }, { "name" => "email", "replace_with" => "a" }],
          "belongs_tos" => [{ "table_name" => "gone", "foreign_key" => "gone_id", "ignore" => true }],
        }

        pruned, removed = described_class.prune(TableConfig, base, overlay)

        expect(pruned).to eq(
          "name" => "users", "filter" => nil, "columns" => [{ "name" => "email", "replace_with" => "a" }],
        )
        expect(removed).to eq(["belongs_tos[table_name=gone,foreign_key=gone_id]", "columns.legacy"])
      end
    end
  end
end

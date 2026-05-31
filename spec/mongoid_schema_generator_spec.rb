# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

require_relative "../script/mongoid_models"

module Exwiw
  RSpec.describe MongoidSchemaGenerator do
    let(:models) { MongoidDummy::MODELS }
    let(:output_dir) { @output_dir }

    around do |ex|
      Dir.mktmpdir do |dir|
        @output_dir = dir
        ex.run
      end
    end

    describe "#build_collections" do
      let(:collections) { described_class.new(models: models, output_dir: output_dir).build_collections }
      let(:by_name) { collections.each_with_object({}) { |c, h| h[c.name] = c } }

      it "emits one config per model keyed by collection name" do
        expect(by_name.keys).to contain_exactly(
          "shops", "users", "posts", "comments", "products",
          "orders", "order_items", "transactions", "system_announcements",
        )
      end

      it "uses _id as the primary key" do
        expect(by_name["shops"].primary_key).to eq("_id")
      end

      it "extracts field names including the belongs_to foreign keys" do
        expect(by_name["users"].fields.map(&:name)).to include("_id", "name", "email", "shop_id")
      end

      it "extracts non-embedded belongs_tos as table_name/foreign_key pairs" do
        belongs_tos = by_name["orders"].belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["shops", "shop_id"], ["users", "user_id"])
      end

      it "leaves belongs_tos empty for a collection with no relations" do
        expect(by_name["system_announcements"].belongs_tos).to be_empty
      end

      it "marks a single-level embedded collection with embedded_in" do
        posts = by_name["posts"]
        expect(posts.embedded?).to eq(true)
        expect(posts.embedded_in.collection_name).to eq("users")
        expect(posts.embedded_in.path).to eq("posts")
        expect(posts.belongs_tos).to be_empty
      end

      it "flattens a nested embedded chain into a dot-separated path" do
        comments = by_name["comments"]
        expect(comments.embedded_in.collection_name).to eq("users")
        expect(comments.embedded_in.path).to eq("posts.comments")
      end
    end

    describe "#generate!" do
      it "writes one JSON file per collection" do
        described_class.new(models: models, output_dir: output_dir).generate!

        expect(Dir[File.join(output_dir, "*.json")].map { |p| File.basename(p) }).to contain_exactly(
          "shops.json", "users.json", "posts.json", "comments.json", "products.json",
          "orders.json", "order_items.json", "transactions.json", "system_announcements.json",
        )
      end

      it "preserves a user-customized replace_with on a field across regeneration" do
        users_path = File.join(output_dir, "users.json")
        existing = {
          "name" => "users",
          "primary_key" => "_id",
          "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
          "fields" => [
            { "name" => "_id" },
            { "name" => "email", "replace_with" => "masked{_id}@example.com" },
          ],
        }
        File.write(users_path, JSON.pretty_generate(existing))

        described_class.new(models: [MongoidDummy::User], output_dir: output_dir).generate!

        result = JSON.parse(File.read(users_path))
        email_field = result["fields"].find { |f| f["name"] == "email" }
        expect(email_field["replace_with"]).to eq("masked{_id}@example.com")
        # newly introduced fields from the model are still added
        expect(result["fields"].map { |f| f["name"] }).to include("name", "shop_id")
      end

      it "preserves a user-customized skip flag across regeneration" do
        path = File.join(output_dir, "system_announcements.json")
        existing = {
          "name" => "system_announcements",
          "primary_key" => "_id",
          "skip" => true,
          "belongs_tos" => [],
          "fields" => [{ "name" => "_id" }],
        }
        File.write(path, JSON.pretty_generate(existing))

        described_class.new(models: [MongoidDummy::SystemAnnouncement], output_dir: output_dir).generate!

        expect(JSON.parse(File.read(path))["skip"]).to eq(true)
      end
    end
  end
end

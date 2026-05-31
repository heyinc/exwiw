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
          "shops", "users", "posts", "comments", "profiles", "products",
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

      it "derives table_name from the target collection and foreign_key from the association" do
        # Transaction#payer and Transaction#reviewer both point at the User
        # model but under relation names that differ from the class. The
        # generator must NOT use the relation name for either side: table_name
        # comes from the target collection ("users") and foreign_key from the
        # association (custom "paid_by_id"; relation-derived "reviewer_id").
        belongs_tos = by_name["transactions"].belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(
          ["orders", "order_id"],
          ["users", "paid_by_id"],
          ["users", "reviewer_id"],
        )
      end

      it "tracks overridden/relation-derived foreign keys as ordinary fields" do
        expect(by_name["transactions"].fields.map(&:name)).to include("paid_by_id", "reviewer_id")
      end

      it "marks a single-level embedded collection with embedded_in" do
        posts = by_name["posts"]
        expect(posts.embedded?).to eq(true)
        expect(posts.embedded_in.collection_name).to eq("users")
        expect(posts.embedded_in.path).to eq("posts")
        expect(posts.belongs_tos).to be_empty
      end

      it "points a nested embedded config at its immediate parent with a relative path" do
        comments = by_name["comments"]
        # NOT flattened to { "users", "posts.comments" }: MongodbAdapter masks
        # multi-level embeds by recursing through the chain (mask each `posts`
        # subdocument, then its `comments`), so the Comment config must name its
        # immediate parent collection ("posts") and a single-segment path.
        expect(comments.embedded?).to eq(true)
        expect(comments.embedded_in.collection_name).to eq("posts")
        expect(comments.embedded_in.path).to eq("comments")
        expect(comments.belongs_tos).to be_empty
      end

      it "marks an embeds_one collection with embedded_in using the custom store_as key" do
        profiles = by_name["profiles"]
        expect(profiles.embedded?).to eq(true)
        expect(profiles.embedded_in.collection_name).to eq("users")
        # `store_as: "user_profile"` wins over the relation name "profile".
        expect(profiles.embedded_in.path).to eq("user_profile")
        expect(profiles.belongs_tos).to be_empty
      end
    end

    describe "#generate!" do
      it "writes one JSON file per collection" do
        described_class.new(models: models, output_dir: output_dir).generate!

        expect(Dir[File.join(output_dir, "*.json")].map { |p| File.basename(p) }).to contain_exactly(
          "shops.json", "users.json", "posts.json", "comments.json", "profiles.json", "products.json",
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

    # End-to-end check that the *generated* configs are actually consumable by
    # the MongoDB dump path: feed the dummy app's seed documents through
    # MongodbAdapter's masking using nothing but the generated config shapes.
    # This is what guards against the generator and adapter drifting apart on
    # how embedded subdocuments are addressed (e.g. nested `comments` inside the
    # `posts` array).
    describe "generated configs drive MongodbAdapter masking on the seed" do
      let(:seed) { MongoidDummy::SEED }
      let(:logger) { Logger.new(nil) }
      let(:connection_config) do
        ConnectionConfig.new(
          adapter: "mongodb",
          database_name: "exwiw_test",
          host: "127.0.0.1",
          port: 27017,
          user: nil,
          password: nil,
        )
      end
      let(:adapter) { Adapter::MongodbAdapter.new(connection_config, logger) }

      # Generated configs carry no masking by default; inject representative
      # `replace_with` rules so the masking pass has something to do.
      let(:config_by_name) do
        collections = described_class.new(models: models, output_dir: output_dir).build_collections
        by_name = collections.each_with_object({}) { |c, h| h[c.name] = c }

        set_replace_with(by_name.fetch("users"), "name", "masked{_id}")
        set_replace_with(by_name.fetch("posts"), "title", "masked-title-{_id}")
        set_replace_with(by_name.fetch("comments"), "body", "masked-comment-{_id}")
        set_replace_with(by_name.fetch("profiles"), "phone", "masked-phone")

        by_name
      end

      def set_replace_with(config, field_name, template)
        config.fields.find { |f| f.name == field_name }.replace_with = template
      end

      it "masks the user document, its embedded posts, nested comments, and embeds_one profile" do
        dump_target = Exwiw::DumpTarget.new(table_name: "users", ids: [10])
        users_config = config_by_name.fetch("users")
        # Primes @embedded_children_by_parent off the generated config index.
        adapter.build_query(users_config, dump_target, config_by_name)

        user = Marshal.load(Marshal.dump(seed.fetch("users").first))
        jsonl = adapter.to_bulk_insert([user], users_config)
        masked = JSON.parse(jsonl)

        expect(masked["name"]).to eq("masked10")

        post = masked.fetch("posts").first
        expect(post["title"]).to eq("masked-title-100")
        # Nested embeds_many: comments live inside the posts array and are only
        # reachable because the Comment config is embedded_in "posts".
        expect(post.fetch("comments").map { |c| c["body"] }).to eq([
          "masked-comment-1000",
          "masked-comment-1001",
        ])

        # embeds_one with a custom store_as: masked at the "user_profile" key.
        expect(masked.fetch("user_profile")["phone"]).to eq("masked-phone")
      end
    end
  end
end

# frozen_string_literal: true

require 'tempfile'

module Exwiw
  module Adapter
    RSpec.describe MongodbAdapter do
      let(:adapter_name) { 'mongodb' }
      let(:connection_config) do
        ConnectionConfig.new(
          adapter: adapter_name,
          database_name: 'exwiw_test',
          host: ENV.fetch('MONGO_HOST', '127.0.0.1'),
          port: ENV.fetch('MONGO_PORT', 27017).to_i,
          user: nil,
          password: nil,
        )
      end
      let(:logger) { Logger.new(nil) }
      let(:adapter) { described_class.new(connection_config, logger) }

      let(:config_by_name) do
        %w[shops users products orders order_items transactions system_announcements posts]
          .map { |n| send("#{n}_table", adapter_name) }
          .each_with_object({}) { |t, h| h[t.name] = t }
      end

      describe ".table_config_class" do
        it { expect(described_class.table_config_class).to eq(MongodbCollectionConfig) }
      end

      describe "#dumpable?" do
        it "is true for top-level configs" do
          users = config_by_name.fetch("users")
          expect(adapter.dumpable?(users)).to eq(true)
        end

        it "is false for embedded configs" do
          posts = config_by_name.fetch("posts")
          expect(adapter.dumpable?(posts)).to eq(false)
        end
      end

      describe "#validate_as_dump_target!" do
        it "is a no-op for top-level configs" do
          users = config_by_name.fetch("users")
          expect { adapter.validate_as_dump_target!(users) }.not_to raise_error
        end

        it "raises NotImplementedError for embedded configs" do
          posts = config_by_name.fetch("posts")
          expect { adapter.validate_as_dump_target!(posts) }.to raise_error(
            NotImplementedError,
            /embedded MongodbCollectionConfig/,
          )
        end
      end

      describe "#build_query" do
        context "for the dump_target collection itself" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

          it "filters by primary_key with $in" do
            shops = config_by_name.fetch("shops")
            query = adapter.build_query(shops, dump_target, config_by_name)
            expect(query.to_h).to eq(
              collection: "shops",
              primary_key: "_id",
              filter: { "_id" => { "$in" => [1] } },
              projection: { "_id" => 1, "name" => 1, "updated_at" => 1, "created_at" => 1 },
            )
          end
        end

        context "when dump_target.ids_field overrides the filter field" do
          it "filters the target collection by the given field instead of the primary key" do
            # `--ids-field=email` matches --ids against `email`, not `_id`. The
            # primary_key is still reported on the query (it drives downstream
            # foreign-key propagation), but the WHERE filter keys off the
            # overridden field.
            users = config_by_name.fetch("users")
            dump_target = Exwiw::DumpTarget.new(table_name: "users", ids: ["a@example.com"], ids_field: "email")
            query = adapter.build_query(users, dump_target, config_by_name)
            expect(query.primary_key).to eq("_id")
            expect(query.filter).to eq("email" => { "$in" => ["a@example.com"] })
          end

          it "does not coerce the textual --ids against a custom field (unknown stored type)" do
            # Unlike the primary-key path, a custom field's stored type is
            # unknown, so the textual --ids are left as Strings rather than
            # guessed into Integer/ObjectId (which could break matching, e.g. a
            # zero-padded code or a hex string stored as a String).
            users = config_by_name.fetch("users")
            dump_target = Exwiw::DumpTarget.new(table_name: "users", ids: ["7", "5f5e7c1e1c9d440000000001"], ids_field: "legacy_id")
            query = adapter.build_query(users, dump_target, config_by_name)
            expect(query.filter).to eq("legacy_id" => { "$in" => ["7", "5f5e7c1e1c9d440000000001"] })
          end
        end

        context "coercing the textual --ids to the stored _id type" do
          it "coerces a 24-char hex --ids into a BSON::ObjectId so it matches an ObjectId _id" do
            # Mongoid's default `_id` is a BSON::ObjectId. `--ids` arrives as a
            # String, and Mongo compares types strictly, so a plain hex String
            # would never match an ObjectId in the `$in` filter. The adapter must
            # coerce it to BSON::ObjectId.
            shops = config_by_name.fetch("shops")
            dump_target = Exwiw::DumpTarget.new(table_name: "shops", ids: ["5f5e7c1e1c9d440000000001"])
            query = adapter.build_query(shops, dump_target, config_by_name)
            coerced = query.filter.fetch("_id").fetch("$in").first
            expect(coerced).to be_a(BSON::ObjectId)
            expect(coerced.to_s).to eq("5f5e7c1e1c9d440000000001")
          end

          it "coerces an integer-looking --ids to Integer and leaves other strings as-is" do
            shops = config_by_name.fetch("shops")
            dump_target = Exwiw::DumpTarget.new(table_name: "shops", ids: ["42", "abc-123"])
            query = adapter.build_query(shops, dump_target, config_by_name)
            expect(query.filter.fetch("_id").fetch("$in")).to eq([42, "abc-123"])
          end
        end

        context "for a related collection with no upstream state" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

          it "uses an empty filter (extracts everything)" do
            users = config_by_name.fetch("users")
            query = adapter.build_query(users, dump_target, config_by_name)
            expect(query.filter).to eq({})
            expect(query.collection).to eq("users")
            expect(query.primary_key).to eq("_id")
          end

          it "includes embedded child paths in projection" do
            users = config_by_name.fetch("users")
            query = adapter.build_query(users, dump_target, config_by_name)
            expect(query.projection).to include("posts" => 1)
            expect(query.projection).to include("_id" => 1, "name" => 1, "email" => 1, "shop_id" => 1)
          end
        end

        context "for a related collection after upstream state is populated" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

          it "filters by foreign_key with $in using state from previous execute" do
            shops = config_by_name.fetch("shops")
            users = config_by_name.fetch("users")

            shops_query = adapter.build_query(shops, dump_target, config_by_name)
            adapter.execute(shops_query)

            users_query = adapter.build_query(users, dump_target, config_by_name)
            expect(users_query.filter).to eq("shop_id" => { "$in" => [1] })
          end
        end

        context "when called with an embedded config" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

          it "raises NotImplementedError" do
            posts = config_by_name.fetch("posts")
            expect {
              adapter.build_query(posts, dump_target, config_by_name)
            }.to raise_error(NotImplementedError, /embedded/)
          end
        end
      end

      describe "#execute" do
        context "for the dump_target collection" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

          it "returns matching documents" do
            shops = config_by_name.fetch("shops")
            query = adapter.build_query(shops, dump_target, config_by_name)
            results = adapter.execute(query)
            expect(results.size).to eq(1)
            expect(results.first["_id"]).to eq(1)
            expect(results.first["name"]).to eq("Shop 1")
          end
        end

        context "for a related collection after running the dump_target collection" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

          it "limits results via state-driven $in filter" do
            shops = config_by_name.fetch("shops")
            users_t = config_by_name.fetch("users")

            adapter.execute(adapter.build_query(shops, dump_target, config_by_name))
            users = adapter.execute(adapter.build_query(users_t, dump_target, config_by_name))

            expect(users.size).to eq(2)
            expect(users.map { |u| u["shop_id"] }.uniq).to eq([1])
          end
        end
      end

      describe "#to_bulk_insert" do
        let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

        before do
          # Prime @config_by_name on the adapter so `to_bulk_insert` can resolve
          # embedded children. Builds without executing — no DB required.
          shops = config_by_name.fetch("shops")
          adapter.build_query(shops, dump_target, config_by_name)
        end

        it "applies replace_with templates and emits JSONL" do
          users_t = config_by_name.fetch("users")
          adapter.build_query(users_t, dump_target, config_by_name)
          rows = [
            { "_id" => 1, "name" => "User 1", "email" => "user1@example.com", "shop_id" => 1 },
            { "_id" => 2, "name" => "User 2", "email" => "user2@example.com", "shop_id" => 1 },
          ]
          jsonl = adapter.to_bulk_insert(rows, users_t)
          parsed = jsonl.split("\n").map { |l| JSON.parse(l) }

          expect(parsed[0]["name"]).to eq("masked1")
          expect(parsed[0]["email"]).to eq("masked1@example.com")
          expect(parsed[1]["name"]).to eq("masked2")
          expect(parsed[1]["email"]).to eq("masked2@example.com")
        end

        it "applies embedded MongodbCollectionConfig replace_with to subdocument arrays" do
          users_t = config_by_name.fetch("users")
          adapter.build_query(users_t, dump_target, config_by_name)
          rows = [
            {
              "_id" => 1,
              "name" => "User 1",
              "email" => "user1@example.com",
              "shop_id" => 1,
              "posts" => [
                { "_id" => 101, "title" => "First" },
                { "_id" => 102, "title" => "Second" },
              ],
            },
          ]
          jsonl = adapter.to_bulk_insert(rows, users_t)
          parsed = JSON.parse(jsonl)

          expect(parsed["posts"].map { |p| p["title"] }).to eq([
            "masked-title-101",
            "masked-title-102",
          ])
        end

        it "applies embedded masking to a single Hash subdocument when path resolves to a Hash" do
          single = MongodbCollectionConfig.from(
            "name" => "profile",
            "primary_key" => "_id",
            "embedded_in" => { "collection_name" => "users", "path" => "profile" },
            "belongs_tos" => [],
            "fields" => [
              { "name" => "_id" },
              { "name" => "phone", "replace_with" => "masked-phone" },
            ],
          )
          users_t = config_by_name.fetch("users")
          local_config_by_name = config_by_name.merge("profile" => single)

          adapter.build_query(users_t, dump_target, local_config_by_name)
          rows = [
            {
              "_id" => 1,
              "name" => "User 1",
              "email" => "user1@example.com",
              "shop_id" => 1,
              "profile" => { "_id" => 999, "phone" => "+81-90-0000-0000" },
            },
          ]
          jsonl = adapter.to_bulk_insert(rows, users_t)
          parsed = JSON.parse(jsonl)
          expect(parsed["profile"]["phone"]).to eq("masked-phone")
        end

        it "applies embedded masking recursively for multi-level nesting" do
          comments = MongodbCollectionConfig.from(
            "name" => "comments",
            "primary_key" => "_id",
            "embedded_in" => { "collection_name" => "posts", "path" => "comments" },
            "belongs_tos" => [],
            "fields" => [
              { "name" => "_id" },
              { "name" => "body", "replace_with" => "masked-comment-{_id}" },
            ],
          )
          users_t = config_by_name.fetch("users")
          local_config_by_name = config_by_name.merge("comments" => comments)

          adapter.build_query(users_t, dump_target, local_config_by_name)
          rows = [
            {
              "_id" => 1,
              "name" => "User 1",
              "email" => "u1@example.com",
              "shop_id" => 1,
              "posts" => [
                {
                  "_id" => 101,
                  "title" => "First",
                  "comments" => [
                    { "_id" => 9001, "body" => "Hi" },
                    { "_id" => 9002, "body" => "Hello" },
                  ],
                },
              ],
            },
          ]
          jsonl = adapter.to_bulk_insert(rows, users_t)
          parsed = JSON.parse(jsonl)
          comments_emitted = parsed["posts"].first["comments"]
          expect(comments_emitted.map { |c| c["body"] }).to eq([
            "masked-comment-9001",
            "masked-comment-9002",
          ])
          expect(parsed["posts"].first["title"]).to eq("masked-title-101")
        end
      end

      describe "#to_bulk_delete" do
        let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

        it "raises NotImplementedError" do
          shops = config_by_name.fetch("shops")
          query = adapter.build_query(shops, dump_target, config_by_name)
          expect { adapter.to_bulk_delete(query, shops) }.to raise_error(NotImplementedError)
        end
      end

      describe "#output_extension" do
        it { expect(adapter.output_extension).to eq("jsonl") }
      end

      describe "#schema_output_extension" do
        it { expect(adapter.schema_output_extension).to eq("js") }
      end

      describe "#dump_schema" do
        let(:schema_path) { Tempfile.new(['mongodb_schema', '.js']).path }

        it "emits createCollection wrapped in try/catch and createIndex for each non-embedded collection" do
          users = config_by_name.fetch("users")
          shops = config_by_name.fetch("shops")
          posts = config_by_name.fetch("posts") # embedded — must be skipped

          users_indexes = double('users_indexes', to_a: [
            { 'v' => 2, 'key' => { '_id' => 1 }, 'name' => '_id_' },
            { 'v' => 2, 'key' => { 'shop_id' => 1 }, 'name' => 'index_users_on_shop_id' },
            { 'v' => 2, 'key' => { 'email' => 1 }, 'name' => 'unique_email', 'unique' => true, 'ns' => 'should-be-dropped' },
          ])
          shops_indexes = double('shops_indexes', to_a: [
            { 'v' => 2, 'key' => { '_id' => 1 }, 'name' => '_id_' },
          ])
          users_view = double('users_view', indexes: users_indexes)
          shops_view = double('shops_view', indexes: shops_indexes)
          db_stub = double('db')
          allow(db_stub).to receive(:[]).with('users').and_return(users_view)
          allow(db_stub).to receive(:[]).with('shops').and_return(shops_view)
          allow(adapter).to receive(:db).and_return(db_stub)

          adapter.dump_schema([shops, users, posts], schema_path)

          js = File.read(schema_path)
          expect(js).to include('db.createCollection("shops")')
          expect(js).to include('db.createCollection("users")')
          expect(js).not_to include('db.createCollection("posts")') # embedded
          expect(js).to include('e.code !== 48') # NamespaceExists swallowed
          expect(js).to include('db.getCollection("users").createIndex({"shop_id":1}')
          expect(js).to include('"name":"index_users_on_shop_id"')
          expect(js).to include('"unique":true')
          expect(js).not_to include('"ns":') # driver-internal field dropped
          expect(js).not_to include('"_id_"') # auto _id_ index dropped
        end
      end

      describe "#supports_bulk_delete?" do
        it { expect(adapter.supports_bulk_delete?).to eq(false) }
      end
    end
  end
end

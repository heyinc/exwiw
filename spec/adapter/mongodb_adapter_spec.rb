# frozen_string_literal: true

require 'tempfile'
require 'stringio'

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

        context "for a related collection whose parents have produced no state" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

          it "matches nothing rather than dumping the whole collection" do
            # users belongs_to shops, but shops has not been executed yet, so there
            # is no captured parent state to scope by. Falling back to an empty
            # `{}` filter would dump every users row across all scopes, so the
            # adapter constrains the collection to match nothing instead. (In a
            # real run the dump target, shops, is executed first — see the next
            # context, where users is properly scoped by shop_id.)
            users = config_by_name.fetch("users")
            query = adapter.build_query(users, dump_target, config_by_name)
            expect(query.filter).to eq("_id" => { "$in" => [] })
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

        context "for a reference collection with no belongs_to" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }

          it "uses an empty filter (full dump), since it has no foreign keys to scope by" do
            # system_announcements has no belongs_to at all, so it is genuine
            # reference/master data: the empty `{}` filter (full dump) is intended
            # and must not be turned into a match-nothing filter.
            system_announcements = config_by_name.fetch("system_announcements")
            query = adapter.build_query(system_announcements, dump_target, config_by_name)
            expect(query.filter).to eq({})
          end
        end

        context "for a related collection after upstream state is populated" do
          # Shop 1's seeded ObjectId (`_id`); see seed/mongodb.
          let(:shop1_oid) { BSON::ObjectId.from_string("a00100000000000000000001") }
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: ["a00100000000000000000001"]) }

          it "filters by foreign_key with $in using state from previous execute" do
            shops = config_by_name.fetch("shops")
            users = config_by_name.fetch("users")

            shops_query = adapter.build_query(shops, dump_target, config_by_name)
            # #execute streams lazily and publishes the propagation-key state only
            # once the result is consumed (as the Runner does via the chunked
            # write); drain it here so the child query can read that state back.
            adapter.execute(shops_query).to_a

            users_query = adapter.build_query(users, dump_target, config_by_name)
            expect(users_query.filter).to eq("shop_id" => { "$in" => [shop1_oid] })
          end
        end

        context "when a belongs_to references a non-_id parent field (e.g. uuid)" do
          # Repro from the issue: stores.maja_business_entity_id holds
          # maja_business_entities.uuid (a String), not the parent's ObjectId
          # _id. The child belongs_to declares `references: "uuid"` so the FK is
          # propagated off `uuid` rather than `_id`.
          let(:dump_target) do
            Exwiw::DumpTarget.new(table_name: "maja_business_entities", ids: ["be-uuid-1"], ids_field: "uuid")
          end
          let(:business_entities) do
            MongodbCollectionConfig.from(
              "name" => "maja_business_entities",
              "primary_key" => "_id",
              "belongs_tos" => [],
              "fields" => [{ "name" => "_id" }, { "name" => "uuid" }],
            )
          end
          let(:stores) do
            MongodbCollectionConfig.from(
              "name" => "stores",
              "primary_key" => "_id",
              "belongs_tos" => [{
                "table_name" => "maja_business_entities",
                "foreign_key" => "maja_business_entity_id",
                "references" => "uuid",
              }],
              "fields" => [{ "name" => "_id" }, { "name" => "maja_business_entity_id" }],
            )
          end
          let(:local_config_by_name) { { business_entities.name => business_entities, stores.name => stores } }

          it "projects the referenced parent field so #execute can capture it" do
            query = adapter.build_query(business_entities, dump_target, local_config_by_name)
            expect(query.projection).to include("uuid" => 1, "_id" => 1)
          end

          it "propagates the parent's referenced field value into the child's $in filter" do
            # Drive the parent collection through a stubbed db: build_query
            # decides which fields to capture, execute stashes them into @state,
            # and the child's build_query reads them back.
            be_oid = BSON::ObjectId.new
            parent_view = double("view")
            allow(parent_view).to receive(:find).and_return(parent_view)
            allow(parent_view).to receive(:projection).and_return(parent_view)
            allow(parent_view).to receive(:comment).and_return(parent_view)
            # #execute now streams the cursor instead of `.to_a`; the wrapper
            # captures propagation-key state as it iterates `each`.
            allow(parent_view).to receive(:each) { |&blk| blk.call({ "_id" => be_oid, "uuid" => "be-uuid-1" }) }
            db_stub = double("db")
            allow(db_stub).to receive(:[]).with("maja_business_entities").and_return(parent_view)
            allow(adapter).to receive(:db).and_return(db_stub)

            # State is published once the result is consumed (Runner drains it via
            # the chunked write); drain it here so the child query reads it back.
            adapter.execute(adapter.build_query(business_entities, dump_target, local_config_by_name)).to_a

            child_query = adapter.build_query(stores, dump_target, local_config_by_name)
            expect(child_query.filter).to eq("maja_business_entity_id" => { "$in" => ["be-uuid-1"] })
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
        # Shop 1's seeded ObjectId (`_id`); see seed/mongodb.
        let(:shop1_oid) { BSON::ObjectId.from_string("a00100000000000000000001") }

        context "for the dump_target collection" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: ["a00100000000000000000001"]) }

          it "returns matching documents" do
            shops = config_by_name.fetch("shops")
            query = adapter.build_query(shops, dump_target, config_by_name)
            results = adapter.execute(query)
            expect(results.size).to eq(1)
            expect(results.first["_id"]).to eq(shop1_oid)
            expect(results.first["name"]).to eq("Shop 1")
          end
        end

        context "for a related collection after running the dump_target collection" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: ["a00100000000000000000001"]) }

          it "limits results via state-driven $in filter" do
            shops = config_by_name.fetch("shops")
            users_t = config_by_name.fetch("users")

            # Drain the parent result so its propagation-key state is published
            # (the Runner does this via the chunked write) before scoping users.
            adapter.execute(adapter.build_query(shops, dump_target, config_by_name)).to_a
            users = adapter.execute(adapter.build_query(users_t, dump_target, config_by_name))

            expect(users.size).to eq(2)
            expect(users.map { |u| u["shop_id"] }.uniq).to eq([shop1_oid])
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

      describe "#write_bulk_insert" do
        let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }
        let(:users_t) { config_by_name.fetch("users") }

        before do
          # Prime the embedded-children index for both shops (the dump target)
          # and users (the collection being serialized), as the Runner does by
          # calling build_query before each table's write. No DB access.
          adapter.build_query(config_by_name.fetch("shops"), dump_target, config_by_name)
          adapter.build_query(users_t, dump_target, config_by_name)
        end

        # Fresh, independent rows on every call: masking mutates documents in
        # place, so the serial and parallel runs must each start from their own
        # copies (and from identical, fixed ObjectIds) to be comparable. Includes
        # BSON::ObjectId values at the top level and inside embedded posts so the
        # extended-JSON encoding (`{"$oid": ...}`) is exercised through the fork.
        def build_rows(count)
          Array.new(count) do |i|
            n = i + 1
            {
              "_id" => BSON::ObjectId.from_string(format("a001%020d", n)),
              "name" => "User #{n}",
              "email" => "user#{n}@example.com",
              "shop_id" => BSON::ObjectId.from_string("a00100000000000000000001"),
              "posts" => [
                { "_id" => BSON::ObjectId.from_string(format("b001%020d", n)), "title" => "Post #{n}" },
              ],
            }
          end
        end

        it "writes byte-identical output to #to_bulk_insert on the serial (default) path" do
          io = StringIO.new
          adapter.write_bulk_insert(io, build_rows(3), users_t)
          expect(io.string).to eq(adapter.to_bulk_insert(build_rows(3), users_t))
        end

        it "writes byte-identical output to the serial join when forking workers" do
          skip "fork unavailable on this platform" unless ParallelSerializer.fork_capable?

          # Force the fork path on a tiny dataset: workers > 1 and min_batch 1.
          # Per the run notes, keeping the fork-path dataset small (a handful of
          # items) keeps the concurrent-write window microscopic and the example
          # reliably green under RSpec, while still exercising real forked workers.
          allow(adapter).to receive(:parallel_workers).and_return(2)
          allow(adapter).to receive(:parallel_min_batch).and_return(1)

          expected = adapter.to_bulk_insert(build_rows(5), users_t)

          Tempfile.create("write_bulk_insert") do |f|
            adapter.write_bulk_insert(f, build_rows(5), users_t)
            f.flush
            f.rewind
            expect(f.read).to eq(expected)
          end
        end
      end

      describe "#write_inserts" do
        let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: [1]) }
        let(:users_t) { config_by_name.fetch("users") }

        before do
          adapter.build_query(config_by_name.fetch("shops"), dump_target, config_by_name)
          adapter.build_query(users_t, dump_target, config_by_name)
        end

        def rows(count)
          Array.new(count) do |i|
            n = i + 1
            { "_id" => n, "name" => "User #{n}", "email" => "user#{n}@example.com", "shop_id" => 1 }
          end
        end

        it "delegates to the default chunk seam (byte-identical to to_bulk_insert) when cursor-parallel is off" do
          io = StringIO.new
          count = adapter.write_inserts(io, rows(3), users_t)
          expect(io.string).to eq(adapter.to_bulk_insert(rows(3), users_t))
          expect(count).to eq(1) # 3 rows < default chunk size -> one statement
        end

        it "does not take the cursor-parallel path for a non-StreamingResult result, even when enabled" do
          allow(adapter).to receive(:cursor_parallel_enabled?).and_return(true)
          io = StringIO.new
          # A plain Array is not a live StreamingResult, so write_inserts must fall
          # back to the default seam rather than try to re-partition a cursor.
          expect { adapter.write_inserts(io, rows(2), users_t) }.not_to raise_error
          expect(io.string).to eq(adapter.to_bulk_insert(rows(2), users_t))
        end
      end

      describe "#cursor_parallel_enabled?" do
        around do |example|
          saved = ENV["EXWIW_MONGODB_CURSOR_PARALLEL"]
          example.run
        ensure
          if saved.nil?
            ENV.delete("EXWIW_MONGODB_CURSOR_PARALLEL")
          else
            ENV["EXWIW_MONGODB_CURSOR_PARALLEL"] = saved
          end
        end

        it "is false when only one worker is configured, even with the env var set" do
          ENV["EXWIW_MONGODB_CURSOR_PARALLEL"] = "1"
          allow(adapter).to receive(:parallel_workers).and_return(1)
          expect(adapter.send(:cursor_parallel_enabled?)).to eq(false)
        end

        it "is false when workers > 1 but the env var is unset" do
          ENV.delete("EXWIW_MONGODB_CURSOR_PARALLEL")
          allow(adapter).to receive(:parallel_workers).and_return(4)
          expect(adapter.send(:cursor_parallel_enabled?)).to eq(false)
        end

        it "is true when workers > 1 and the env var is truthy" do
          allow(adapter).to receive(:parallel_workers).and_return(4)
          %w[1 true TRUE yes On].each do |val|
            ENV["EXWIW_MONGODB_CURSOR_PARALLEL"] = val
            expect(adapter.send(:cursor_parallel_enabled?)).to eq(true), "expected #{val.inspect} to enable"
          end
        end

        it "is false for a non-truthy env value" do
          allow(adapter).to receive(:parallel_workers).and_return(4)
          ENV["EXWIW_MONGODB_CURSOR_PARALLEL"] = "0"
          expect(adapter.send(:cursor_parallel_enabled?)).to eq(false)
        end

        it "uses the constructor option (CLI --cursor-parallel) ahead of the env var" do
          a = described_class.new(connection_config, logger, parallel_workers: 4, cursor_parallel: true)
          ENV["EXWIW_MONGODB_CURSOR_PARALLEL"] = "0" # env says off, the flag wins
          expect(a.send(:cursor_parallel_enabled?)).to eq(true)
        end

        it "lets an explicit constructor false override a truthy env var" do
          a = described_class.new(connection_config, logger, parallel_workers: 4, cursor_parallel: false)
          ENV["EXWIW_MONGODB_CURSOR_PARALLEL"] = "1"
          expect(a.send(:cursor_parallel_enabled?)).to eq(false)
        end

        it "still requires more than one worker even with the constructor option set" do
          a = described_class.new(connection_config, logger, parallel_workers: 1, cursor_parallel: true)
          expect(a.send(:cursor_parallel_enabled?)).to eq(false)
        end
      end

      describe "#build_client" do
        before { require 'mongo' }

        def adapter_for(config)
          described_class.new(config, Logger.new(nil))
        end

        let(:host_config) do
          ConnectionConfig.new(
            adapter: 'mongodb', host: 'db.example.com', port: 27017,
            database_name: 'app', user: nil, password: nil, uri: nil,
          )
        end

        it "builds a fresh, un-memoized client on every call (the per-fork-worker connection)" do
          a = adapter_for(host_config)
          c1 = double('c1')
          c2 = double('c2')
          allow(Mongo::Client).to receive(:new).and_return(c1, c2)
          expect(a.send(:build_client)).to equal(c1)
          expect(a.send(:build_client)).to equal(c2)
        end

        it "is the single construction path #db memoizes" do
          a = adapter_for(host_config)
          client = double('client')
          expect(Mongo::Client).to receive(:new)
            .with(['db.example.com:27017'], database: 'app')
            .once
            .and_return(client)
          expect(a.send(:db)).to equal(client)
          expect(a.send(:db)).to equal(client) # memoized, not rebuilt
        end
      end

      describe "#parallel_workers" do
        around do |example|
          saved = ENV["EXWIW_MONGODB_PARALLEL_WORKERS"]
          ENV.delete("EXWIW_MONGODB_PARALLEL_WORKERS")
          example.run
        ensure
          if saved.nil?
            ENV.delete("EXWIW_MONGODB_PARALLEL_WORKERS")
          else
            ENV["EXWIW_MONGODB_PARALLEL_WORKERS"] = saved
          end
        end

        it "defaults to 1 (serial) with neither the constructor option nor the env var" do
          expect(described_class.new(connection_config, logger).send(:parallel_workers)).to eq(1)
        end

        it "uses the constructor option threaded in from the CLI flag" do
          a = described_class.new(connection_config, logger, parallel_workers: 4)
          expect(a.send(:parallel_workers)).to eq(4)
        end

        it "falls back to the env var when no constructor option is given" do
          ENV["EXWIW_MONGODB_PARALLEL_WORKERS"] = "3"
          expect(described_class.new(connection_config, logger).send(:parallel_workers)).to eq(3)
        end

        it "lets the constructor option (CLI flag) override the env var" do
          ENV["EXWIW_MONGODB_PARALLEL_WORKERS"] = "8"
          a = described_class.new(connection_config, logger, parallel_workers: 2)
          expect(a.send(:parallel_workers)).to eq(2)
        end
      end

      describe "#default_bulk_insert_chunk_size" do
        it "is the serial default when parallelism is off" do
          expect(adapter.default_bulk_insert_chunk_size).to eq(described_class::DEFAULT_BULK_INSERT_CHUNK_SIZE)
        end

        it "scales the chunk so each forked worker gets a multi-thousand-doc slice" do
          allow(adapter).to receive(:parallel_workers).and_return(4)
          expect(adapter.default_bulk_insert_chunk_size)
            .to eq(4 * described_class::PARALLEL_DOCS_PER_WORKER)
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
          allow(db_stub).to receive(:database).and_return(double('database', collection_names: ['shops', 'users']))
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

        it "creates the collection but emits no indexes for a collection absent from the source DB" do
          users = config_by_name.fetch("users")
          shops = config_by_name.fetch("shops")

          shops_indexes = double('shops_indexes', to_a: [
            { 'v' => 2, 'key' => { '_id' => 1 }, 'name' => '_id_' },
            { 'v' => 2, 'key' => { 'name' => 1 }, 'name' => 'index_shops_on_name' },
          ])
          shops_view = double('shops_view', indexes: shops_indexes)
          db_stub = double('db')
          # 'users' is declared in the schema but does not exist in the source DB.
          allow(db_stub).to receive(:database).and_return(double('database', collection_names: ['shops']))
          allow(db_stub).to receive(:[]).with('shops').and_return(shops_view)
          allow(adapter).to receive(:db).and_return(db_stub)

          expect { adapter.dump_schema([shops, users], schema_path) }.not_to raise_error

          js = File.read(schema_path)
          # Both collections are still created on the target...
          expect(js).to include('db.createCollection("shops")')
          expect(js).to include('db.createCollection("users")')
          # ...but indexes are only emitted for the one that exists in the source.
          expect(js).to include('db.getCollection("shops").createIndex({"name":1}')
          expect(js).not_to include('db.getCollection("users").createIndex')
          # The missing collection is never queried for its indexes.
          expect(db_stub).not_to have_received(:[]).with('users')
        end
      end

      describe "#supports_bulk_delete?" do
        it { expect(adapter.supports_bulk_delete?).to eq(false) }
      end

      describe "#db connection construction" do
        before { require 'mongo' }

        def adapter_for(config)
          described_class.new(config, Logger.new(nil))
        end

        it "passes the connection URI straight to Mongo::Client when uri is set" do
          config = ConnectionConfig.new(
            adapter: 'mongodb',
            uri: 'mongodb+srv://u:p@cluster.example.com/app?authSource=admin&tls=true',
            database_name: nil,
          )
          client = double('client')
          expect(Mongo::Client).to receive(:new)
            .with('mongodb+srv://u:p@cluster.example.com/app?authSource=admin&tls=true')
            .and_return(client)
          expect(adapter_for(config).send(:db)).to eq(client)
        end

        it "passes --database as an override option alongside the URI" do
          config = ConnectionConfig.new(
            adapter: 'mongodb',
            uri: 'mongodb+srv://u:p@cluster.example.com/?authSource=admin',
            database_name: 'app',
          )
          client = double('client')
          expect(Mongo::Client).to receive(:new)
            .with('mongodb+srv://u:p@cluster.example.com/?authSource=admin', database: 'app')
            .and_return(client)
          expect(adapter_for(config).send(:db)).to eq(client)
        end

        it "falls back to host:port addressing when no uri is given" do
          config = ConnectionConfig.new(
            adapter: 'mongodb', host: 'db.example.com', port: 27017,
            database_name: 'app', user: nil, password: nil, uri: nil,
          )
          client = double('client')
          expect(Mongo::Client).to receive(:new)
            .with(['db.example.com:27017'], database: 'app')
            .and_return(client)
          expect(adapter_for(config).send(:db)).to eq(client)
        end
      end
    end
  end
end

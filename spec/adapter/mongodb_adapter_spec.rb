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

          it "leaves timeout_ms nil and omits it from to_h when the collection sets none" do
            shops = config_by_name.fetch("shops")
            query = adapter.build_query(shops, dump_target, config_by_name)
            expect(query.timeout_ms).to be_nil
            expect(query.to_h).not_to have_key(:timeout_ms)
          end

          it "carries the collection's query_timeout_ms onto the query (and into to_h)" do
            shops = config_by_name.fetch("shops")
            shops.query_timeout_ms = 45_000
            query = adapter.build_query(shops, dump_target, config_by_name)
            expect(query.timeout_ms).to eq(45_000)
            expect(query.to_h).to include(timeout_ms: 45_000)
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
            # users' only genuine parent (shops) is the anchor, applied strictly.
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
            # The dump target is stores' only genuine parent -> strict anchor.
            expect(child_query.filter).to eq("maja_business_entity_id" => { "$in" => ["be-uuid-1"] })
          end
        end

        context "when a belongs_to parent is reference data not reachable to the dump target" do
          # `stores` is reachable to the target (`entities` via entity_id) AND
          # also belongs_to `malls`, which has no path back to the target — it is
          # reference data dumped in full. The mall id set is "all malls", which
          # is not a real scope; ANDing it would drop stores with a null mall_id.
          let(:entities) do
            MongodbCollectionConfig.from(
              "name" => "entities", "primary_key" => "_id",
              "belongs_tos" => [], "fields" => [{ "name" => "_id" }],
            )
          end
          let(:malls) do
            MongodbCollectionConfig.from(
              "name" => "malls", "primary_key" => "_id",
              "belongs_tos" => [], "fields" => [{ "name" => "_id" }],
            )
          end
          let(:stores) do
            MongodbCollectionConfig.from(
              "name" => "stores", "primary_key" => "_id",
              "belongs_tos" => [
                { "table_name" => "entities", "foreign_key" => "entity_id" },
                { "table_name" => "malls", "foreign_key" => "mall_id" },
              ],
              "fields" => [{ "name" => "_id" }, { "name" => "entity_id" }, { "name" => "mall_id" }],
            )
          end
          let(:mall_banners) do
            MongodbCollectionConfig.from(
              "name" => "mall_banners", "primary_key" => "_id",
              "belongs_tos" => [{ "table_name" => "malls", "foreign_key" => "mall_id" }],
              "fields" => [{ "name" => "_id" }, { "name" => "mall_id" }],
            )
          end
          # items has a selective genuine anchor (stores -> store_id) plus a second,
          # less selective genuine parent (delivery_configs, also reachable to the
          # target) and a reference parent (malls).
          let(:delivery_configs) do
            MongodbCollectionConfig.from(
              "name" => "delivery_configs", "primary_key" => "_id",
              "belongs_tos" => [{ "table_name" => "stores", "foreign_key" => "store_id" }],
              "fields" => [{ "name" => "_id" }],
            )
          end
          let(:items) do
            MongodbCollectionConfig.from(
              "name" => "items", "primary_key" => "_id",
              "belongs_tos" => [
                { "table_name" => "stores", "foreign_key" => "store_id" },
                { "table_name" => "delivery_configs", "foreign_key" => "delivery_id" },
                { "table_name" => "malls", "foreign_key" => "mall_id" },
              ],
              "fields" => [{ "name" => "_id" }, { "name" => "store_id" }, { "name" => "delivery_id" }, { "name" => "mall_id" }],
            )
          end
          let(:local_config_by_name) do
            [entities, malls, stores, mall_banners, delivery_configs, items]
              .each_with_object({}) { |c, h| h[c.name] = c }
          end
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "entities", ids: ["e1"]) }

          it "scopes by the genuine anchor (strict) and drops the reference-parent constraint" do
            adapter.instance_variable_set(:@state, {
              "entities" => { "_id" => ["e1"] },
              "malls" => { "_id" => %w[m1 m2] },
            })
            query = adapter.build_query(stores, dump_target, local_config_by_name)
            # entity_id is the sole genuine parent -> strict anchor; mall_id (reference) dropped.
            expect(query.filter).to eq("entity_id" => { "$in" => ["e1"] })
          end

          it "applies the most selective genuine parent strictly and the others null-aware" do
            adapter.instance_variable_set(:@state, {
              "stores" => { "_id" => ["s1"] },
              "delivery_configs" => { "_id" => %w[d1 d2 d3] },
              "malls" => { "_id" => %w[m1 m2] },
            })
            query = adapter.build_query(items, dump_target, local_config_by_name)
            # store_id (1 id) is the most selective genuine parent -> strict anchor;
            # delivery_id (3 ids) is null-aware so items with a null delivery_id survive;
            # mall_id (reference) is dropped.
            expect(query.filter).to eq(
              "store_id" => { "$in" => ["s1"] },
              "delivery_id" => { "$in" => [nil, "d1", "d2", "d3"] },
            )
          end

          it "keeps the strict-AND when the collection has no genuine parent at all" do
            # mall_banners is reachable only via malls (reference), so it has no
            # genuine scope: the historical strict $in (no nil) is preserved.
            adapter.instance_variable_set(:@state, { "malls" => { "_id" => %w[m1 m2] } })
            query = adapter.build_query(mall_banners, dump_target, local_config_by_name)
            expect(query.filter).to eq("mall_id" => { "$in" => %w[m1 m2] })
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

        context "for a reverse-scoped collection (reverse_scope)" do
          # `accounts` is a global-identity collection: no belongs_to of its own,
          # referenced by two scoped collections (`articles.author_account_id`,
          # `invitations.invitee_account_id`). It opts into reverse scoping via
          # both arms; the arm columns are captured while the referencers are
          # dumped (see the ordering in DetermineTableProcessingOrder) and the
          # collection is constrained to their union.
          let(:organizations) do
            MongodbCollectionConfig.from(
              "name" => "organizations", "primary_key" => "_id",
              "belongs_tos" => [], "fields" => [{ "name" => "_id" }],
            )
          end
          let(:articles) do
            MongodbCollectionConfig.from(
              "name" => "articles", "primary_key" => "_id",
              "belongs_tos" => [{ "table_name" => "organizations", "foreign_key" => "organization_id" }],
              "fields" => [{ "name" => "_id" }, { "name" => "organization_id" }],
            )
          end
          let(:invitations) do
            MongodbCollectionConfig.from(
              "name" => "invitations", "primary_key" => "_id",
              "belongs_tos" => [{ "table_name" => "organizations", "foreign_key" => "organization_id" }],
              "fields" => [{ "name" => "_id" }, { "name" => "organization_id" }, { "name" => "invitee_account_id" }],
            )
          end
          let(:accounts_reverse_scope) do
            {
              "via" => [
                { "table" => "articles", "column" => "author_account_id" },
                { "table" => "invitations", "column" => "invitee_account_id" },
              ],
            }
          end
          let(:accounts) do
            MongodbCollectionConfig.from(
              "name" => "accounts", "primary_key" => "_id",
              "reverse_scope" => accounts_reverse_scope,
              "belongs_tos" => [], "fields" => [{ "name" => "_id" }],
            )
          end
          let(:local_config_by_name) do
            [organizations, articles, invitations, accounts]
              .each_with_object({}) { |c, h| h[c.name] = c }
          end
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "organizations", ids: ["org1"]) }

          it "captures the via-arm column of a referencer even when it is not a declared field" do
            # articles does not declare author_account_id in `fields`, but the
            # accounts reverse_scope names it as an arm column, so it must be
            # projected and captured while articles streams.
            query = adapter.build_query(articles, dump_target, local_config_by_name)
            expect(query.projection).to include("author_account_id" => 1)
          end

          it "constrains the collection to the union of the captured arm ids, dropping nils and deduping" do
            adapter.instance_variable_set(:@state, {
              "articles" => { "_id" => %w[ar1 ar2 ar3], "author_account_id" => ["acc1", "acc2", nil, "acc2"] },
              "invitations" => { "_id" => %w[in1], "invitee_account_id" => ["acc2", "acc3"] },
            })
            query = adapter.build_query(accounts, dump_target, local_config_by_name)
            expect(query.filter).to eq("_id" => { "$in" => %w[acc1 acc2 acc3] })
          end

          it "flattens an array-valued arm column (one referenced id per element)" do
            adapter.instance_variable_set(:@state, {
              "articles" => { "_id" => %w[ar1], "author_account_id" => [%w[acc1 acc2], nil] },
              "invitations" => { "_id" => [], "invitee_account_id" => [] },
            })
            query = adapter.build_query(accounts, dump_target, local_config_by_name)
            expect(query.filter).to eq("_id" => { "$in" => %w[acc1 acc2] })
          end

          it "matches nothing (not everything) when the arms captured no ids" do
            adapter.instance_variable_set(:@state, {
              "articles" => { "_id" => [], "author_account_id" => [] },
              "invitations" => { "_id" => [], "invitee_account_id" => [] },
            })
            query = adapter.build_query(accounts, dump_target, local_config_by_name)
            expect(query.filter).to eq("_id" => { "$in" => [] })
          end

          it "skips an arm whose referencer has not been dumped, keeping the surviving arms" do
            adapter.instance_variable_set(:@state, {
              "invitations" => { "_id" => %w[in1], "invitee_account_id" => %w[acc3] },
            })
            query = adapter.build_query(accounts, dump_target, local_config_by_name)
            expect(query.filter).to eq("_id" => { "$in" => %w[acc3] })
          end

          it "skips an unscoped arm (referencer with no path to the dump target) with a warning" do
            # `banners` is reference data dumped in full: its captured ids span
            # every scope, so unioning them would silently widen the dump —
            # exactly the arm the SQL adapters skip too.
            banners = MongodbCollectionConfig.from(
              "name" => "banners", "primary_key" => "_id",
              "belongs_tos" => [], "fields" => [{ "name" => "_id" }, { "name" => "account_id" }],
            )
            accounts_config = MongodbCollectionConfig.from(
              "name" => "accounts", "primary_key" => "_id",
              "reverse_scope" => {
                "via" => [
                  { "table" => "banners", "column" => "account_id" },
                  { "table" => "articles", "column" => "author_account_id" },
                ],
              },
              "belongs_tos" => [], "fields" => [{ "name" => "_id" }],
            )
            configs = local_config_by_name.merge("banners" => banners, "accounts" => accounts_config)

            logger = instance_spy(Logger)
            local_adapter = described_class.new(connection_config, logger)
            local_adapter.instance_variable_set(:@state, {
              "banners" => { "_id" => %w[b1], "account_id" => %w[acc9] },
              "articles" => { "_id" => %w[ar1], "author_account_id" => %w[acc1] },
            })

            query = local_adapter.build_query(accounts_config, dump_target, configs)
            expect(query.filter).to eq("_id" => { "$in" => %w[acc1] })
            expect(logger).to have_received(:warn).with(/'banners\.account_id' is not scoped/)
          end

          it "falls back to the historical behavior when no arm survives (full dump for a belongs_to-less collection)" do
            # No referencer has any captured state, so every arm is skipped —
            # mirror the SQL adapters' dump-all fallback for a table with no
            # belongs_to of its own. (With the reverse_scope-aware processing
            # order this only happens when every referencer itself matched
            # nothing AND was skipped, e.g. ignore:true referencers.)
            adapter.instance_variable_set(:@state, {})
            query = adapter.build_query(accounts, dump_target, local_config_by_name)
            expect(query.filter).to eq({})
          end

          it "ignores reverse_scope on a genuinely scoped collection (belongs_to scope wins, as in SQL)" do
            scoped_accounts = MongodbCollectionConfig.from(
              "name" => "accounts", "primary_key" => "_id",
              "reverse_scope" => accounts_reverse_scope,
              "belongs_tos" => [{ "table_name" => "organizations", "foreign_key" => "organization_id" }],
              "fields" => [{ "name" => "_id" }, { "name" => "organization_id" }],
            )
            configs = local_config_by_name.merge("accounts" => scoped_accounts)
            adapter.instance_variable_set(:@state, {
              "organizations" => { "_id" => %w[org1] },
              "articles" => { "_id" => %w[ar1], "author_account_id" => %w[acc1] },
            })
            query = adapter.build_query(scoped_accounts, dump_target, configs)
            expect(query.filter).to eq("organization_id" => { "$in" => %w[org1] })
          end

          it "replaces the reference-parent strict-AND with the reverse filter (SQL parity: reverse scope IS the scope clause)" do
            # accounts also belongs_to `plans` (reference data). SQL emits only
            # the `pk IN (UNION ...)` clause for a reverse-scoped table; the
            # mongodb filter must likewise not AND the reference-parent ids in.
            plans = MongodbCollectionConfig.from(
              "name" => "plans", "primary_key" => "_id",
              "belongs_tos" => [], "fields" => [{ "name" => "_id" }],
            )
            accounts_with_plan = MongodbCollectionConfig.from(
              "name" => "accounts", "primary_key" => "_id",
              "reverse_scope" => accounts_reverse_scope,
              "belongs_tos" => [{ "table_name" => "plans", "foreign_key" => "plan_id" }],
              "fields" => [{ "name" => "_id" }, { "name" => "plan_id" }],
            )
            configs = local_config_by_name.merge("plans" => plans, "accounts" => accounts_with_plan)
            adapter.instance_variable_set(:@state, {
              "plans" => { "_id" => %w[p1 p2] },
              "articles" => { "_id" => %w[ar1], "author_account_id" => %w[acc1] },
            })
            query = adapter.build_query(accounts_with_plan, dump_target, configs)
            expect(query.filter).to eq("_id" => { "$in" => %w[acc1] })
          end

          it "builds a placeholder id filter in explain placeholder mode (real filter shape, no state)" do
            placeholder = BSON::ObjectId.from_string("ffffffffffffffffffffffff")
            adapter.explain_scope_with_placeholders!
            query = adapter.build_query(accounts, dump_target, local_config_by_name)
            expect(query.filter).to eq("_id" => { "$in" => [placeholder] })
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

        context "when the collection sets a per-collection query_timeout_ms" do
          let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: ["a00100000000000000000001"]) }

          it "passes timeout_ms to both the find and the count operations" do
            shops = config_by_name.fetch("shops")
            shops.query_timeout_ms = 12_345
            query = adapter.build_query(shops, dump_target, config_by_name)

            view = double("view")
            allow(view).to receive(:projection).and_return(view)
            allow(view).to receive(:comment).and_return(view)
            allow(view).to receive(:each)
            expect(view).to receive(:count_documents).with({ timeout_ms: 12_345 }).and_return(0)
            collection = double("collection")
            expect(collection).to receive(:find).with(query.filter, { timeout_ms: 12_345 }).and_return(view)
            allow(adapter).to receive(:db).and_return({ "shops" => collection })

            result = adapter.execute(query)
            result.size # triggers count_documents
            result.to_a # triggers the streaming each
          end
        end
      end

      describe "#explain" do
        let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: ["a00100000000000000000001"]) }
        let(:query) { adapter.build_query(config_by_name.fetch("shops"), dump_target, config_by_name) }

        it "returns the queryPlanner plan as JSON and does NOT execute the query (safe default)" do
          parsed = JSON.parse(adapter.explain(query))

          expect(parsed).to have_key("queryPlanner")
          # queryPlanner only plans; without execution there are no runtime stats.
          expect(parsed).not_to have_key("executionStats")
        end

        it "gathers execution stats when verbosity is executionStats" do
          parsed = JSON.parse(adapter.explain(query, verbosity: "executionStats"))

          expect(parsed).to have_key("executionStats")
        end
      end

      describe "#explain_scope_with_placeholders! (explain mode)" do
        let(:dump_target) { Exwiw::DumpTarget.new(table_name: "shops", ids: ["a00100000000000000000001"]) }
        let(:placeholder) { BSON::ObjectId.from_string("ffffffffffffffffffffffff") }

        before { adapter.explain_scope_with_placeholders! }

        it "builds a scoped child's filter on its real foreign key with a placeholder id" do
          users = config_by_name.fetch("users")
          query = adapter.build_query(users, dump_target, config_by_name)

          # Without placeholder mode this child would be the match-nothing
          # `{_id: {$in: []}}` (no parent ids captured); here it is the real
          # foreign-key shape with a dummy value.
          expect(query.filter).to eq("shop_id" => { "$in" => [placeholder] })
        end

        it "reflects the real index usage of the scoped query (users.shop_id is unindexed -> COLLSCAN)" do
          users = config_by_name.fetch("users")
          parsed = JSON.parse(adapter.explain(adapter.build_query(users, dump_target, config_by_name)))

          expect(parsed.fetch("queryPlanner").fetch("winningPlan").to_s).to include("COLLSCAN")
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

        it "preserves a NULL field value instead of masking it" do
          users_t = config_by_name.fetch("users")
          adapter.build_query(users_t, dump_target, config_by_name)
          rows = [
            { "_id" => 1, "name" => nil, "email" => "user1@example.com", "shop_id" => 1 },
          ]
          parsed = JSON.parse(adapter.to_bulk_insert(rows, users_t))

          expect(parsed["name"]).to be_nil
          expect(parsed["email"]).to eq("masked1@example.com")
        end

        it "leaves an absent masked field absent (does not create the key)" do
          users_t = config_by_name.fetch("users")
          adapter.build_query(users_t, dump_target, config_by_name)
          rows = [
            { "_id" => 1, "email" => "user1@example.com", "shop_id" => 1 },
          ]
          parsed = JSON.parse(adapter.to_bulk_insert(rows, users_t))

          expect(parsed).not_to have_key("name")
          expect(parsed["email"]).to eq("masked1@example.com")
        end

        it "preserves a NULL field in an embedded subdocument" do
          users_t = config_by_name.fetch("users")
          adapter.build_query(users_t, dump_target, config_by_name)
          rows = [
            {
              "_id" => 1,
              "name" => "User 1",
              "email" => "user1@example.com",
              "shop_id" => 1,
              "posts" => [
                { "_id" => 101, "title" => nil },
                { "_id" => 102, "title" => "Second" },
              ],
            },
          ]
          parsed = JSON.parse(adapter.to_bulk_insert(rows, users_t))

          expect(parsed["posts"][0]["title"]).to be_nil
          expect(parsed["posts"][1]["title"]).to eq("masked-title-102")
        end

        context "replace_with_fake_data" do
          # A `users` variant whose `name`/`email` carry replace_with_fake_data
          # seeded by `_id`, so the same _id always maps to the same fake value.
          let(:fake_users) do
            MongodbCollectionConfig.from(
              "name" => "users",
              "primary_key" => "_id",
              "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
              "fields" => [
                { "name" => "_id" },
                { "name" => "name", "replace_with_fake_data" => { "seed" => "_id", "type" => "human_name" } },
                { "name" => "email", "replace_with_fake_data" => { "seed" => "_id", "type" => "email" } },
                { "name" => "shop_id" },
              ],
            )
          end

          it "replaces a field with a deterministic fake value seeded by another field" do
            local = config_by_name.merge("users" => fake_users)
            adapter.build_query(fake_users, dump_target, local)
            rows = [
              { "_id" => 1, "name" => "User 1", "email" => "u1@example.com", "shop_id" => 1 },
              { "_id" => 2, "name" => "User 2", "email" => "u2@example.com", "shop_id" => 1 },
              { "_id" => 1, "name" => "Dup", "email" => "dup@example.com", "shop_id" => 1 },
            ]
            parsed = adapter.to_bulk_insert(rows, fake_users).split("\n").map { |l| JSON.parse(l) }

            # Same seed (_id=1) -> identical fake values; different seed differs.
            expect(parsed[0]["name"]).to eq(parsed[2]["name"])
            expect(parsed[0]["name"]).not_to eq(parsed[1]["name"])
            expect(parsed[0]["email"]).to match(/@example\.com\z/)
            expect(parsed[0]["name"]).not_to eq("User 1")
          end

          it "derives the same value as the SQL row transformer for the same seed" do
            local = config_by_name.merge("users" => fake_users)
            adapter.build_query(fake_users, dump_target, local)
            parsed = JSON.parse(adapter.to_bulk_insert([{ "_id" => 42, "name" => "x", "shop_id" => 1 }], fake_users))

            deriver = Exwiw::RowTransformer.build_value_deriver(
              fake_users.fields.find { |f| f.name == "name" }.replace_with_fake_data, "test"
            )
            expect(parsed["name"]).to eq(deriver.call(42))
          end

          it "preserves a NULL target value" do
            local = config_by_name.merge("users" => fake_users)
            adapter.build_query(fake_users, dump_target, local)
            parsed = JSON.parse(adapter.to_bulk_insert([{ "_id" => 1, "name" => nil, "shop_id" => 1 }], fake_users))

            expect(parsed["name"]).to be_nil
          end

          it "applies fake data inside embedded subdocuments" do
            profile = MongodbCollectionConfig.from(
              "name" => "profile",
              "primary_key" => "_id",
              "embedded_in" => { "collection_name" => "users", "path" => "profile" },
              "belongs_tos" => [],
              "fields" => [
                { "name" => "_id" },
                { "name" => "full_name", "replace_with_fake_data" => { "seed" => "_id", "type" => "human_name" } },
              ],
            )
            users_t = config_by_name.fetch("users")
            local = config_by_name.merge("profile" => profile)
            adapter.build_query(users_t, dump_target, local)
            rows = [
              { "_id" => 1, "name" => "User 1", "email" => "u1@example.com", "shop_id" => 1,
                "profile" => { "_id" => 7, "full_name" => "Real Person" } },
            ]
            parsed = JSON.parse(adapter.to_bulk_insert(rows, users_t))

            deriver = Exwiw::RowTransformer.build_value_deriver(
              profile.fields.find { |f| f.name == "full_name" }.replace_with_fake_data, "test"
            )
            expect(parsed["profile"]["full_name"]).to eq(deriver.call(7))
          end

          it "raises at dump time when the seed resolves to an ignore:true field" do
            ignored_seed = MongodbCollectionConfig.from(
              "name" => "users",
              "primary_key" => "_id",
              "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
              "fields" => [
                { "name" => "_id" },
                { "name" => "legacy_id", "ignore" => true },
                { "name" => "name", "replace_with_fake_data" => { "seed" => "legacy_id", "type" => "human_name" } },
                { "name" => "shop_id" },
              ],
            ).reject_ignored_members!
            local = config_by_name.merge("users" => ignored_seed)
            adapter.build_query(ignored_seed, dump_target, local)

            expect { adapter.to_bulk_insert([{ "_id" => 1, "name" => "x", "shop_id" => 1 }], ignored_seed) }
              .to raise_error(ArgumentError, /seed 'legacy_id' does not resolve to an extracted field/)
          end
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

        it "passes the global mongodb_query_timeout_ms as the client-wide CSOT timeout (host:port)" do
          config = ConnectionConfig.new(
            adapter: 'mongodb', host: 'db.example.com', port: 27017,
            database_name: 'app', user: nil, password: nil, uri: nil,
            mongodb_query_timeout_ms: 30_000,
          )
          client = double('client')
          expect(Mongo::Client).to receive(:new)
            .with(['db.example.com:27017'], timeout_ms: 30_000, database: 'app')
            .and_return(client)
          expect(adapter_for(config).send(:db)).to eq(client)
        end

        it "passes the global mongodb_query_timeout_ms alongside the URI" do
          config = ConnectionConfig.new(
            adapter: 'mongodb',
            uri: 'mongodb+srv://u:p@cluster.example.com/app',
            database_name: nil,
            mongodb_query_timeout_ms: 30_000,
          )
          client = double('client')
          expect(Mongo::Client).to receive(:new)
            .with('mongodb+srv://u:p@cluster.example.com/app', timeout_ms: 30_000)
            .and_return(client)
          expect(adapter_for(config).send(:db)).to eq(client)
        end
      end
    end
  end
end

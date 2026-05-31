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

      it "emits one config per collection keyed by collection name" do
        expect(by_name.keys).to contain_exactly(
          "shops", "users", "posts", "comments", "profiles", "contacts", "addresses", "products", "tags",
          "orders", "order_items", "transactions", "events", "reviews", "system_announcements",
        )
      end

      it "uses _id as the primary key" do
        expect(by_name["shops"].primary_key).to eq("_id")
      end

      it "extracts field names including the belongs_to foreign keys" do
        expect(by_name["users"].fields.map(&:name)).to include("_id", "name", "email", "shop_id")
      end

      it "tracks the Mongoid::Timestamps fields as ordinary fields" do
        # `include Mongoid::Timestamps` auto-declares created_at/updated_at as
        # Time (BSON Date) fields. The generator must surface them like any other
        # field so they are projected and (if desired) maskable; the dump path
        # serializes their BSON Date values as MongoDB Extended JSON.
        expect(by_name["users"].fields.map(&:name)).to include("created_at", "updated_at")
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

      it "excludes a polymorphic belongs_to while keeping the regular one" do
        # Review#reviewable is polymorphic (no single target collection), so it
        # cannot be expressed as a BelongsTo the MongodbAdapter can follow and
        # must be dropped. The regular Review#user belongs_to must survive.
        reviews = by_name["reviews"]
        belongs_tos = reviews.belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["users", "user_id"])
      end

      it "still tracks the polymorphic id/type columns as ordinary fields" do
        # Even though the polymorphic association is excluded from belongs_tos,
        # Mongoid auto-declares reviewable_id/reviewable_type as fields, so the
        # generator surfaces them as ordinary (maskable) fields.
        expect(by_name["reviews"].fields.map(&:name)).to include(
          "user_id", "reviewable_id", "reviewable_type",
        )
      end

      it "excludes a has_and_belongs_to_many relation from belongs_tos" do
        # Product <-> Tag is a HABTM. Mongoid stores the related ids as an array
        # field (`tag_ids` / `product_ids`), which exwiw cannot follow as a
        # single-valued BelongsTo, so the relation must be dropped. The regular
        # Product#shop belongs_to must survive; Tag has no single-valued FK.
        product_belongs_tos = by_name["products"].belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(product_belongs_tos).to contain_exactly(["shops", "shop_id"])
        expect(by_name["tags"].belongs_tos).to be_empty
      end

      it "emits an aliased field's storage key, not its Ruby accessor" do
        # Product declares `field :ctry, as: :country`: the document stores the
        # value under `ctry`, while `country` is only the Ruby accessor. exwiw
        # masks/projects by the stored document key, so the generated config must
        # carry `ctry` (what `model.fields.keys` returns) and never `country`.
        field_names = by_name["products"].fields.map(&:name)
        expect(field_names).to include("ctry")
        expect(field_names).not_to include("country")
      end

      it "still tracks the HABTM array foreign-key columns as ordinary fields" do
        # The HABTM relation is dropped, but Mongoid auto-declares the `*_ids`
        # array fields, so the generator surfaces them as ordinary (maskable)
        # fields on both sides.
        expect(by_name["products"].fields.map(&:name)).to include("tag_ids")
        expect(by_name["tags"].fields.map(&:name)).to include("product_ids")
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

      it "drops a referenced belongs_to declared on an embedded document but keeps its FK field" do
        # Comment#author is a referenced belongs_to on an embedded document.
        # MongodbCollectionConfig forbids a non-empty belongs_tos on an embedded
        # config (cross-collection FKs from inside embedded arrays are
        # unsupported), so the generator must drop the association entirely while
        # still surfacing the auto-added `author_id` as an ordinary field.
        comments = by_name["comments"]
        expect(comments.belongs_tos).to be_empty
        expect(comments.fields.map(&:name)).to include("author_id")
      end

      it "marks an embeds_one collection with embedded_in using the custom store_as key" do
        profiles = by_name["profiles"]
        expect(profiles.embedded?).to eq(true)
        expect(profiles.embedded_in.collection_name).to eq("users")
        # `store_as: "user_profile"` wins over the relation name "profile".
        expect(profiles.embedded_in.path).to eq("user_profile")
        expect(profiles.belongs_tos).to be_empty
      end

      it "points an array embedded inside a Hash intermediate at its immediate parent" do
        contacts = by_name["contacts"]
        # Contacts (embeds_many) live inside the embeds_one `user_profile` Hash,
        # so the chain is users -> user_profile (Hash) -> contacts (array). The
        # config names its immediate parent collection ("profiles") and the
        # relative path ("contacts"), regardless of the parent being embedded
        # itself; MongodbAdapter resolves the full chain by recursing.
        expect(contacts.embedded?).to eq(true)
        expect(contacts.embedded_in.collection_name).to eq("profiles")
        expect(contacts.embedded_in.path).to eq("contacts")
        expect(contacts.belongs_tos).to be_empty
      end

      it "points a Hash embedded inside a Hash intermediate at its immediate parent" do
        addresses = by_name["addresses"]
        # Address (embeds_one) lives inside the embeds_one `user_profile` Hash,
        # so the chain is users -> user_profile (Hash) -> address (Hash). Like
        # the array-in-Hash contacts case, the config names its immediate parent
        # collection ("profiles") and the relative path ("address"); the only
        # difference is the leaf is a single Hash, not an array. MongodbAdapter
        # resolves the full chain by recursing through both Hash boundaries.
        expect(addresses.embedded?).to eq(true)
        expect(addresses.embedded_in.collection_name).to eq("profiles")
        expect(addresses.embedded_in.path).to eq("address")
        expect(addresses.belongs_tos).to be_empty
      end

      it "unions fields and belongs_tos of inheritance subclasses sharing a collection" do
        # Event / PurchaseEvent / LoginEvent all store into "events". The single
        # config must aggregate the base's fields plus each subclass's own
        # (`amount`, `ip_address`, `order_id`) and the auto-added `_type`
        # discriminator, and union the base + subclass belongs_tos.
        events = by_name["events"]
        expect(events.embedded?).to eq(false)
        expect(events.fields.map(&:name)).to include(
          "_id", "name", "shop_id", "_type", "amount", "order_id", "ip_address",
        )
        belongs_tos = events.belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["shops", "shop_id"], ["orders", "order_id"])
      end

      it "discovers subclasses via descendants when given only the base model" do
        # `from_rails_application` introspects `Mongoid.models`, which registers
        # ONLY the base class of a hierarchy. Given just Event, the generator
        # must still surface the subclass-only fields/associations (and emit a
        # single "events" config, not one per class).
        collections = described_class.new(models: [MongoidDummy::Event], output_dir: output_dir).build_collections
        expect(collections.map(&:name)).to eq(["events"])

        events = collections.first
        expect(events.fields.map(&:name)).to include("amount", "order_id", "ip_address", "_type")
        belongs_tos = events.belongs_tos.map { |b| [b.table_name, b.foreign_key] }
        expect(belongs_tos).to contain_exactly(["shops", "shop_id"], ["orders", "order_id"])
      end

      it "does not emit a duplicate config when base and subclasses are both passed" do
        collections = described_class.new(
          models: [MongoidDummy::Event, MongoidDummy::PurchaseEvent, MongoidDummy::LoginEvent],
          output_dir: output_dir,
        ).build_collections
        expect(collections.map(&:name)).to eq(["events"])
      end

      it "raises a clear error for a polymorphic embedded_in instead of crashing" do
        # PolymorphicAddress declares `embedded_in :addressable, polymorphic: true`,
        # which has no single embedding parent collection. exwiw's `embedded_in`
        # names exactly one parent, so this is unrepresentable: the generator must
        # raise an actionable ArgumentError rather than let `assoc.klass` blow up
        # with a cryptic "uninitialized constant ...::Addressable" NameError.
        gen = described_class.new(models: [MongoidDummy::PolymorphicAddress], output_dir: output_dir)
        expect { gen.build_collections }.to raise_error(
          ArgumentError, /polymorphic `embedded_in :addressable`/,
        )
      end

      it "raises a clear error for a self-referential cyclic embedded_in instead of silently making it undumpable" do
        # TreeNode uses `recursively_embeds_many`, so it is BOTH a top-level
        # "tree_nodes" document AND embedded inside documents of its own type.
        # exwiw represents a collection as either top-level or embedded, not
        # both; emitting `embedded_in` would mark the whole collection embedded
        # and MongodbAdapter#dumpable? (`!embedded?`) would silently never dump
        # the root nodes. The generator must raise an actionable error instead.
        gen = described_class.new(models: [MongoidDummy::TreeNode], output_dir: output_dir)
        expect { gen.build_collections }.to raise_error(
          ArgumentError, /self-referential \(cyclic\) `embedded_in :parent_tree_node`/,
        )
      end
    end

    describe "#generate!" do
      it "writes one JSON file per collection" do
        described_class.new(models: models, output_dir: output_dir).generate!

        expect(Dir[File.join(output_dir, "*.json")].map { |p| File.basename(p) }).to contain_exactly(
          "shops.json", "users.json", "posts.json", "comments.json", "profiles.json", "contacts.json",
          "addresses.json", "products.json", "tags.json", "orders.json", "order_items.json",
          "transactions.json", "events.json", "reviews.json", "system_announcements.json",
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
        set_replace_with(by_name.fetch("contacts"), "phone", "masked-contact-{_id}")
        set_replace_with(by_name.fetch("addresses"), "city", "masked-city-{_id}")
        # Mask the aliased field by its STORAGE key (`ctry`), the only key the
        # generator emits and the only key present in the document.
        set_replace_with(by_name.fetch("products"), "ctry", "XX")

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
        profile = masked.fetch("user_profile")
        expect(profile["phone"]).to eq("masked-phone")

        # Array nested inside the embeds_one Hash intermediate: contacts live at
        # users.user_profile.contacts and are only reachable because the Contact
        # config is embedded_in "profiles" and the adapter recurses across the
        # Hash boundary into the array.
        expect(profile.fetch("contacts").map { |c| c["phone"] }).to eq([
          "masked-contact-300",
          "masked-contact-301",
        ])

        # Hash nested inside the embeds_one Hash intermediate: address lives at
        # users.user_profile.address and is only reachable because the Address
        # config is embedded_in "profiles" and the adapter recurses across the
        # second Hash boundary (Hash-in-Hash, vs the array-in-Hash contacts).
        address = profile.fetch("address")
        expect(address["city"]).to eq("masked-city-400")
      end

      it "projects the embedded child paths (incl. a custom store_as) so the subdocuments survive to be masked" do
        # The test above feeds the FULL seed document straight into
        # `to_bulk_insert`, bypassing the projection step `execute` performs
        # (`find().projection(build_projection(config))`). A real dump only sees
        # the keys the projection requested, so an embedded child is masked ONLY
        # if its `embedded_in.path` is in the projection. This is the one place
        # the embeds_one's custom `store_as` ("user_profile", not the relation
        # name "profile") has to flow all the way through: if the generator
        # emitted "profile", projection would request a key the document does not
        # have and the profile would silently never be fetched or masked.
        dump_target = Exwiw::DumpTarget.new(table_name: "users", ids: [10])
        users_config = config_by_name.fetch("users")
        query = adapter.build_query(users_config, dump_target, config_by_name)

        # Generated config drives projection of both embedded children: the
        # relation-name path ("posts") and the custom store_as path
        # ("user_profile"), never the relation name "profile".
        expect(query.projection).to include("posts" => 1, "user_profile" => 1)
        expect(query.projection).not_to have_key("profile")

        # Simulate what MongoDB returns: only the projected keys survive.
        full = Marshal.load(Marshal.dump(seed.fetch("users").first))
        projected = full.slice(*query.projection.keys)
        # The embeds_one subdocument is reachable only because projection kept it.
        expect(projected).to have_key("user_profile")

        masked = JSON.parse(adapter.to_bulk_insert([projected], users_config))
        expect(masked.fetch("user_profile")["phone"]).to eq("masked-phone")
        expect(masked.fetch("posts").first["title"]).to eq("masked-title-100")
      end

      it "masks an aliased field by its stored document key, not the accessor" do
        # Product stores `field :ctry, as: :country`. The generated config masks
        # by the stored key `ctry`; the document carries `ctry` (not `country`),
        # so masking must hit it — proving the generator and adapter agree on
        # using the storage key for aliased fields.
        dump_target = Exwiw::DumpTarget.new(table_name: "products", ids: [20])
        products_config = config_by_name.fetch("products")
        adapter.build_query(products_config, dump_target, config_by_name)

        product = Marshal.load(Marshal.dump(seed.fetch("products").first))
        masked = JSON.parse(adapter.to_bulk_insert([product], products_config))

        expect(masked["ctry"]).to eq("XX")
        expect(masked).not_to have_key("country")
      end
    end

    # End-to-end check that the *generated* configs survive realistic MongoDB
    # documents: a real find() returns BSON values (ObjectId `_id`, Time/BSON
    # Date `created_at`/`updated_at`), not the plain Integers/Strings the seed
    # uses for readability. MongodbAdapter#to_bulk_insert masks first, then runs
    # `as_extended_json` so those BSON types serialize as MongoDB Extended JSON
    # ($oid / $date) — the form `mongoimport` round-trips. This proves the
    # generated field set (including the Mongoid::Timestamps columns) flows
    # through that serialization untouched and that masking templates resolve an
    # ObjectId primary key to its hex string.
    describe "generated configs drive MongodbAdapter BSON Extended JSON serialization" do
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
      let(:config_by_name) do
        collections = described_class.new(models: models, output_dir: output_dir).build_collections
        by_name = collections.each_with_object({}) { |c, h| h[c.name] = c }
        by_name.fetch("users").fields.find { |f| f.name == "name" }.replace_with = "masked{_id}"
        by_name.fetch("posts").fields.find { |f| f.name == "title" }.replace_with = "masked-title-{_id}"
        by_name
      end

      it "serializes BSON ObjectId/Date as Extended JSON while masking against the ObjectId _id" do
        users_config = config_by_name.fetch("users")
        dump_target = Exwiw::DumpTarget.new(table_name: "users", ids: [])
        adapter.build_query(users_config, dump_target, config_by_name)

        user_oid = BSON::ObjectId.from_string("5f5e7c1e1c9d440000000001")
        post_oid = BSON::ObjectId.from_string("5f5e7c1e1c9d440000000002")
        # The shape a live `find` returns: BSON types, not the seed's Integers.
        doc = {
          "_id" => user_oid,
          "name" => "Alice",
          "email" => "alice@example.com",
          "shop_id" => 1,
          "created_at" => Time.utc(2026, 5, 31, 12, 0, 0),
          "updated_at" => Time.utc(2026, 5, 31, 12, 0, 0),
          "posts" => [
            { "_id" => post_oid, "title" => "Hello", "created_at" => Time.utc(2026, 1, 1, 0, 0, 0) },
          ],
        }

        masked = JSON.parse(adapter.to_bulk_insert([doc], users_config))

        # ObjectId _id serialized as Extended JSON, and the {_id} template
        # resolved to its hex string before serialization.
        expect(masked["_id"]).to eq("$oid" => "5f5e7c1e1c9d440000000001")
        expect(masked["name"]).to eq("masked5f5e7c1e1c9d440000000001")
        # Mongoid::Timestamps Time values serialized as Extended JSON $date.
        expect(masked["created_at"]).to eq("$date" => "2026-05-31T12:00:00Z")
        expect(masked["updated_at"]).to eq("$date" => "2026-05-31T12:00:00Z")

        # Extended JSON conversion recurses into the masked embedded posts array.
        post = masked.fetch("posts").first
        expect(post["_id"]).to eq("$oid" => "5f5e7c1e1c9d440000000002")
        expect(post["title"]).to eq("masked-title-5f5e7c1e1c9d440000000002")
        expect(post["created_at"]).to eq("$date" => "2026-01-01T00:00:00Z")
      end
    end

    # End-to-end check that the *generated* `belongs_tos` actually drive
    # MongodbAdapter's cross-collection extraction filters — the FK-following
    # heart of exwiw. The masking block above proves embedded subdocuments are
    # reached; this proves *referenced* documents are reached via the foreign
    # keys the generator derived. `@state` (normally filled by `execute`, which
    # needs a live MongoDB) is primed directly so the assertion stays offline.
    describe "generated belongs_tos drive MongodbAdapter cross-collection extraction" do
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
      let(:config_by_name) do
        described_class.new(models: models, output_dir: output_dir)
          .build_collections
          .each_with_object({}) { |c, h| h[c.name] = c }
      end

      it "filters a child collection by the generated foreign_key against upstream ids" do
        # dump_target is a *different* collection, so `users` is reached only via
        # its generated belongs_to (shops/shop_id). Prime the state `execute`
        # would have set after dumping shops.
        adapter.instance_variable_set(:@state, { "shops" => [1] })
        dump_target = Exwiw::DumpTarget.new(table_name: "shops", ids: [1])

        query = adapter.build_query(config_by_name.fetch("users"), dump_target, config_by_name)
        expect(query.filter).to eq("shop_id" => { "$in" => [1] })
      end

      it "coerces an ObjectId-hex --ids against the generated _id primary key" do
        # The generator emits `primary_key: "_id"`, and a real Mongoid `_id` is a
        # BSON::ObjectId. When the dump_target IS this collection, build_query
        # filters by that primary key against the textual `--ids`. Proves the
        # generated config drives the ObjectId coercion so `--ids <hex>` actually
        # matches an ObjectId `_id` (a plain String never would).
        users = config_by_name.fetch("users")
        dump_target = Exwiw::DumpTarget.new(table_name: "users", ids: ["5f5e7c1e1c9d440000000001"])

        query = adapter.build_query(users, dump_target, config_by_name)
        coerced = query.filter.fetch("_id").fetch("$in").first
        expect(coerced).to be_a(BSON::ObjectId)
        expect(coerced.to_s).to eq("5f5e7c1e1c9d440000000001")
      end

      it "emits independent $in filters for two belongs_tos targeting the same collection" do
        # transactions has TWO belongs_to -> users (paid_by_id, reviewer_id) plus
        # one -> orders. Each generated foreign_key must produce its own filter
        # key, the two user-targeting ones both constrained by the single
        # upstream "users" id set — proving the custom/relation-derived FKs the
        # generator emitted extract independently.
        adapter.instance_variable_set(:@state, { "users" => [10], "orders" => [30] })
        dump_target = Exwiw::DumpTarget.new(table_name: "users", ids: [10])

        query = adapter.build_query(config_by_name.fetch("transactions"), dump_target, config_by_name)
        expect(query.filter).to eq(
          "order_id" => { "$in" => [30] },
          "paid_by_id" => { "$in" => [10] },
          "reviewer_id" => { "$in" => [10] },
        )
      end
    end
  end
end

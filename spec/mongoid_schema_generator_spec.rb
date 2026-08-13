# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
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

      it "does not emit references for a belongs_to whose FK points at the parent _id" do
        # A plain `belongs_to` references the parent's default `_id`, so the
        # generator must leave `references` nil — existing configs (and the
        # snapshots) behave exactly as before, with the adapter defaulting the
        # propagation field to the parent primary_key.
        orders = by_name["orders"].belongs_tos
        expect(orders.map(&:references)).to all(be_nil)
      end

      it "emits references for a belongs_to declared with a non-_id primary_key (issue B1)" do
        # Mongoid's `belongs_to :entity, primary_key: :uuid` makes the child's
        # foreign key reference the parent's `uuid`, not its `_id`. The generator
        # must surface that as `references: "uuid"` so MongodbAdapter constrains
        # children by the right field instead of $in-matching uuids against
        # ObjectId `_id` (which matches nothing).
        collections = described_class.new(
          models: [MongoidDummy::UuidReferencingChild], output_dir: output_dir,
        ).build_collections
        child = collections.find { |c| c.name == "uuid_referencing_children" }

        belongs_to = child.belongs_tos.find { |b| b.foreign_key == "entity_id" }
        expect(belongs_to.table_name).to eq("uuid_referenced_parents")
        expect(belongs_to.references).to eq("uuid")
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

      it "annotates an aliased field with its Mongoid accessor via mongoid_field_name" do
        # The storage key (`ctry`) stays the `name`, but the cryptic short key is
        # explained by carrying the Ruby accessor (`country`) as
        # `mongoid_field_name`.
        ctry = by_name["products"].fields.find { |f| f.name == "ctry" }
        expect(ctry.mongoid_field_name).to eq("country")
      end

      it "does not annotate non-aliased fields or belongs_to foreign keys" do
        # Only genuine `field ..., as:` renames get mongoid_field_name. A plain
        # field (`price`) and a belongs_to FK (`shop_id`, whose `shop => shop_id`
        # entry lives in aliased_fields as an association alias) must not.
        fields = by_name["products"].fields.each_with_object({}) { |f, h| h[f.name] = f }
        expect(fields["price"].mongoid_field_name).to be_nil
        expect(fields["shop_id"].mongoid_field_name).to be_nil
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

      it "raises the same clear error for recursively_embeds_one (Hash self-embedding)" do
        # Category uses `recursively_embeds_one`, the embeds_one counterpart of
        # TreeNode: BOTH a top-level "categories" document AND embedded as a Hash
        # inside documents of its own type. Same unrepresentable top-level-AND-
        # embedded shape, so the generator must reject it just like the array
        # (`recursively_embeds_many`) case.
        gen = described_class.new(models: [MongoidDummy::Category], output_dir: output_dir)
        expect { gen.build_collections }.to raise_error(
          ArgumentError, /self-referential \(cyclic\) `embedded_in :parent_category`/,
        )
      end
    end

    describe "#build_collections with skip_unsupported: true" do
      def build(models)
        described_class.new(models: models, output_dir: output_dir, skip_unsupported: true).build_collections
      end

      it "skips an unresolvable belongs_to but keeps its foreign-key field instead of raising" do
        # StaleReferencer#ghost points at a class that does not exist, so
        # `assoc.klass` raises NameError. With skip_unsupported the relation is
        # dropped from belongs_tos while the auto-added `ghost_id` field survives,
        # mirroring how polymorphic / HABTM relations are handled.
        config = nil
        expect { config = build([MongoidDummy::StaleReferencer]).first }
          .to output(/skipping belongs_to ':ghost'/).to_stderr
        expect(config.belongs_tos).to be_empty
        expect(config.fields.map(&:name)).to include("ghost_id")
        expect(config.ignore).to be_nil
      end

      it "emits a polymorphic embedded_in collection as ignore:true with a comment instead of raising" do
        config = nil
        expect { config = build([MongoidDummy::PolymorphicAddress]).first }
          .to output(/polymorphic embedded_in :addressable/).to_stderr
        expect(config.name).to eq("polymorphic_addresses")
        expect(config.ignore).to eq(true)
        expect(config.embedded_in).to be_nil
        expect(config.belongs_tos).to be_empty
        expect(config.comment).to match(/polymorphic embedded_in :addressable/)
      end

      it "emits a self-referential (cyclic) embedded_in collection as ignore:true instead of raising" do
        config = nil
        expect { config = build([MongoidDummy::TreeNode]).first }
          .to output(/self-referential \(cyclic\) embedded_in/).to_stderr
        expect(config.name).to eq("tree_nodes")
        expect(config.ignore).to eq(true)
        expect(config.embedded_in).to be_nil
        expect(config.comment).to match(/cyclic/)
      end

      it "emits an embedded_in collection with an unresolvable parent class as ignore:true instead of raising" do
        config = nil
        expect { config = build([MongoidDummy::OrphanEmbedded]).first }
          .to output(/parent class is unresolvable/).to_stderr
        expect(config.name).to eq("orphan_embeddeds")
        expect(config.ignore).to eq(true)
        expect(config.embedded_in).to be_nil
        expect(config.comment).to match(/unresolvable/)
      end

      it "emits an embedded_in collection with an ambiguous inverse as ignore:true instead of raising" do
        # AmbiguousChild is embedded under two keys in AmbiguousParent without
        # inverse_of, so Mongoid raises AmbiguousRelationship resolving the
        # inverse. exwiw cannot pick the single path, so under skip_unsupported it
        # marks the collection ignore:true rather than aborting.
        config = nil
        expect { config = build([MongoidDummy::AmbiguousChild]).first }
          .to output(%r{ambiguous/unresolvable inverse}).to_stderr
        expect(config.name).to eq("ambiguous_children")
        expect(config.ignore).to eq(true)
        expect(config.embedded_in).to be_nil
        expect(config.comment).to match(/ambiguous/)
      end

      it "still raises by default (skip_unsupported off) on an ambiguous embedded_in inverse" do
        expect {
          described_class.new(models: [MongoidDummy::AmbiguousChild], output_dir: output_dir).build_collections
        }.to raise_error(MongoidSchemaGenerator::UnsupportedEmbedding, /ambiguous or unresolvable/)
      end

      it "still raises by default (skip_unsupported off) on an unresolvable belongs_to" do
        expect {
          described_class.new(models: [MongoidDummy::StaleReferencer], output_dir: output_dir).build_collections
        }.to raise_error(NameError, /uninitialized constant/)
      end

      it "still raises by default (skip_unsupported off) on an unresolvable embedded_in parent" do
        expect {
          described_class.new(models: [MongoidDummy::OrphanEmbedded], output_dir: output_dir).build_collections
        }.to raise_error(MongoidSchemaGenerator::UnsupportedEmbedding, /parent class cannot be resolved/)
      end
    end

    describe "a collection name shared by embedded and top-level models" do
      # SharedNameEntryLog stores into "shared_name_entries" while the embedded
      # SharedNameEntry resolves to the same collection name — the routine
      # collision between a `store_in` and a name an embedded class derives from
      # its own class name. Deciding the whole group is embedded (which one
      # embedded member used to be enough for) emits an `embedded_in`, so
      # MongodbAdapter#dumpable? silently stops dumping the collection's root
      # documents and the top-level model's extraction paths disappear.
      let(:mixed_models) { [MongoidDummy::SharedNameEntry, MongoidDummy::SharedNameEntryLog] }
      let(:path) { File.join(output_dir, "shared_name_entries.json") }

      def generate_mixed(models_to_use = mixed_models, **options)
        # Every run over a mixed group warns; asserting it here doubles as
        # silencing it, so the examples below stay about the emitted config.
        expect {
          described_class.new(models: models_to_use, output_dir: output_dir, **options).generate!
        }.to output(/stored into by both top-level and embedded models/).to_stderr
      end

      it "generates a top-level config from the non-embedded models alone" do
        config = nil
        expect {
          config = described_class.new(models: mixed_models, output_dir: output_dir)
                                  .build_collections
                                  .find { |c| c.name == "shared_name_entries" }
        }.to output(/'shared_name_entries'.*MongoidDummy::SharedNameEntry\b/m).to_stderr

        # No embedded_in, so the collection keeps being dumped in its own right...
        expect(config.embedded?).to eq(false)
        # ...with the top-level model's belongs_to, the extraction path that a
        # forced-empty belongs_tos would have thrown away...
        expect(config.belongs_tos.map { |b| [b.table_name, b.foreign_key] })
          .to contain_exactly(["shops", "shop_id"])
        # ...and only the top-level model's fields: `memo` belongs to the
        # embedded namesake, which this config does not describe.
        expect(config.fields.map(&:name)).to contain_exactly("_id", "title", "shop_id")
      end

      it "warns which collection collided and which embedded class is left uncovered" do
        expect {
          described_class.new(models: mixed_models, output_dir: output_dir).build_collections
        }.to output(
          /collection 'shared_name_entries'.*embedded: MongoidDummy::SharedNameEntry\).*add a config by hand/m,
        ).to_stderr
      end

      it "still emits an embedded config when only embedded models store into the collection" do
        # The collision is what makes the collection top-level; on its own the
        # embedded model is unaffected by any of this.
        config = described_class.new(models: [MongoidDummy::SharedNameEntry], output_dir: output_dir)
                                .build_collections
                                .first

        expect(config.embedded?).to eq(true)
        expect(config.embedded_in.collection_name).to eq("shared_name_entry_holders")
        expect(config.fields.map(&:name)).to contain_exactly("_id", "memo")
      end

      it "keeps generating an embedded config for an embedded family under a plain base class" do
        # ContactPoint holds the fields its variants share and declares no
        # `embedded_in`; HomeContactPoint < ContactPoint declares one. The base is
        # therefore not `embedded?` while storing no root documents either, so the
        # group only LOOKS mixed. Reading the base as a root model would flip the
        # family to a top-level config and delete the `embedded_in` that masks
        # those subdocuments — the same failure as above, in the other direction.
        config = nil
        expect {
          config = described_class.new(
            models: [MongoidDummy::ContactPoint, MongoidDummy::ContactPointOwner], output_dir: output_dir,
          ).build_collections.find { |c| c.name == "contact_points" }
        }.not_to output(/stored into by both top-level and embedded models/).to_stderr

        expect(config.embedded?).to eq(true)
        expect(config.embedded_in.collection_name).to eq("contact_point_owners")
        expect(config.embedded_in.path).to eq("home_contact_point")
        expect(config.belongs_tos).to be_empty
        # The same union, in the same order, the generator emitted before the
        # mixed-group handling existed: the base's fields lead, the subclass
        # appends its own.
        expect(config.fields.map(&:name)).to eq(["_id", "label", "_type", "note"])
      end

      it "builds the top-level config from the root models alone when an embedded family shares the name too" do
        # Three-way: ContactPointLog stores root documents under the name the
        # embedded family already shares. The collection is top-level, but an
        # embedded base's fields describe subdocuments, so only the root model
        # contributes — `label` (base) and `note` (subclass) must not leak in.
        config = nil
        expect {
          config = described_class.new(
            models: [MongoidDummy::ContactPoint, MongoidDummy::ContactPointLog], output_dir: output_dir,
          ).build_collections.find { |c| c.name == "contact_points" }
        }.to output(/stored into by both top-level and embedded models/).to_stderr

        expect(config.embedded?).to eq(false)
        expect(config.belongs_tos.map(&:foreign_key)).to contain_exactly("shop_id")
        expect(config.fields.map(&:name)).to contain_exactly("_id", "title", "shop_id")
      end

      it "preserves a hand-maintained top-level config and regenerates it unchanged" do
        # The acceptance case: a user maintaining this collection by hand could
        # never get the schema check green, because the generated `embedded_in`
        # won the merge on every run. The config must now survive regeneration
        # untouched, and a second run must produce a byte-identical file.
        existing = {
          "name" => "shared_name_entries",
          "primary_key" => "_id",
          "comment" => "Top-level collection; the embedded documents of the same name have their own config.",
          "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
          "fields" => [
            { "name" => "_id" },
            { "name" => "title", "replace_with" => "masked-{_id}", "comment" => "reviewed" },
            { "name" => "shop_id" },
          ],
        }
        File.write(path, JSON.pretty_generate(existing) + "\n")

        generate_mixed
        first_run = File.read(path)
        result = JSON.parse(first_run)

        expect(result).not_to have_key("embedded_in")
        expect(result["comment"]).to match(/Top-level collection/)
        expect(result["fields"].find { |f| f["name"] == "title" })
          .to eq({ "name" => "title", "replace_with" => "masked-{_id}", "comment" => "reviewed" })

        generate_mixed
        expect(File.read(path)).to eq(first_run)
      end
    end

    describe "#generate! honoring an explicit ignore on disk (fail-loud default)" do
      # These run WITHOUT skip_unsupported (the default), proving the generator
      # no longer aborts on a construct the user has already triaged by marking
      # it ignore:true on disk — distinct from skip_unsupported, which blanket-
      # skips *un-annotated* constructs.
      it "preserves a collection-level ignore:true (with ignore_type/comment) and skips introspecting it instead of aborting" do
        path = File.join(output_dir, "polymorphic_addresses.json")
        existing = {
          "name" => "polymorphic_addresses",
          "primary_key" => "_id",
          "ignore" => true,
          "ignore_type" => "unsupported",
          "comment" => "FIXME: polymorphic embedded_in :addressable; define embedded_in by hand.",
          "belongs_tos" => [],
          "fields" => [{ "name" => "_id" }],
        }
        File.write(path, JSON.pretty_generate(existing))

        # PolymorphicAddress would otherwise raise UnsupportedEmbedding here.
        expect {
          described_class.new(models: [MongoidDummy::PolymorphicAddress], output_dir: output_dir).generate!
        }.not_to raise_error

        result = JSON.parse(File.read(path))
        expect(result["ignore"]).to eq(true)
        expect(result["ignore_type"]).to eq("unsupported")
        expect(result["comment"]).to match(/FIXME/)
      end

      it "preserves a belongs_to-level ignore:true (no table_name) and keeps the collection dumpable instead of aborting on the stale relation" do
        path = File.join(output_dir, "stale_referencers.json")
        existing = {
          "name" => "stale_referencers",
          "primary_key" => "_id",
          "belongs_tos" => [
            {
              "foreign_key" => "ghost_id",
              "ignore" => true,
              "ignore_type" => "need_code_fix",
              "comment" => "FIXME: belongs_to :ghost -> Ghost does not exist (dead relation).",
            },
          ],
          "fields" => [{ "name" => "_id" }, { "name" => "ghost_id" }],
        }
        File.write(path, JSON.pretty_generate(existing))

        # StaleReferencer#ghost resolves to a missing class; without the explicit
        # ignore this raises NameError (see the skip_unsupported section above).
        expect {
          described_class.new(models: [MongoidDummy::StaleReferencer], output_dir: output_dir).generate!
        }.not_to raise_error

        result = JSON.parse(File.read(path))
        # The collection itself is NOT ignored — it still dumps.
        expect(result["ignore"]).to be_nil
        # The stale belongs_to is preserved as an ignored entry carrying its
        # ignore_type/comment, with no table_name (the target is gone).
        ghost = result["belongs_tos"].find { |b| b["foreign_key"] == "ghost_id" }
        expect(ghost["ignore"]).to eq(true)
        expect(ghost["ignore_type"]).to eq("need_code_fix")
        expect(ghost).not_to have_key("table_name")
        # ...and its foreign-key column survives as an ordinary field.
        expect(result["fields"].map { |f| f["name"] }).to include("ghost_id")
      end

      it "applies an ignore:true belongs_to only to the relation it names, keeping its foreign-key twin live" do
        # SharedForeignKeyReferencer declares two belongs_to on the SAME foreign
        # key: one to "shops", one reading that value as another collection's
        # `uuid`. A foreign key therefore does not identify a relation, and while
        # the ignored entry was matched by foreign key alone it stood for both:
        # the second relation came back as a copy of the entry, `uniq` collapsed
        # the two, and its edge disappeared from the config.
        path = File.join(output_dir, "shared_foreign_key_referencers.json")
        existing = {
          "name" => "shared_foreign_key_referencers",
          "primary_key" => "_id",
          "belongs_tos" => [
            {
              "table_name" => "shops",
              "foreign_key" => "owner_id",
              "ignore" => true,
              "ignore_type" => "need_code_fix",
              "comment" => "FIXME: the shop edge is not wanted in the export.",
            },
          ],
          "fields" => [{ "name" => "_id" }, { "name" => "owner_id" }],
        }
        File.write(path, JSON.pretty_generate(existing))

        described_class.new(
          models: [MongoidDummy::SharedForeignKeyReferencer], output_dir: output_dir,
        ).generate!

        belongs_tos = JSON.parse(File.read(path))["belongs_tos"]
        # The user's entry survives verbatim...
        expect(belongs_tos).to include(
          "table_name" => "shops",
          "foreign_key" => "owner_id",
          "ignore" => true,
          "ignore_type" => "need_code_fix",
          "comment" => "FIXME: the shop edge is not wanted in the export.",
        )
        # ...while the other relation on the same foreign key is emitted live,
        # with the `references` its `primary_key:` implies.
        expect(belongs_tos).to include(
          "table_name" => "uuid_referenced_parents",
          "foreign_key" => "owner_id",
          "references" => "uuid",
        )
      end

      it "still preserves an ignore:true belongs_to that names no target collection" do
        # The minimal form of the annotation: a stale relation's target is gone,
        # so there is nothing to name. Matching then falls back to the foreign key
        # alone — otherwise a user writing the minimal form would have their
        # decision dropped and the edge resurrected.
        path = File.join(output_dir, "shared_foreign_key_referencers.json")
        existing = {
          "name" => "shared_foreign_key_referencers",
          "primary_key" => "_id",
          "belongs_tos" => [
            { "foreign_key" => "owner_id", "ignore" => true, "comment" => "FIXME: not wanted." },
          ],
          "fields" => [{ "name" => "_id" }, { "name" => "owner_id" }],
        }
        File.write(path, JSON.pretty_generate(existing))

        described_class.new(
          models: [MongoidDummy::SharedForeignKeyReferencer], output_dir: output_dir,
        ).generate!

        belongs_tos = JSON.parse(File.read(path))["belongs_tos"]
        expect(belongs_tos).to eq([
          { "foreign_key" => "owner_id", "ignore" => true, "comment" => "FIXME: not wanted." },
        ])
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

      it "preserves a user-customized ignore flag across regeneration" do
        path = File.join(output_dir, "system_announcements.json")
        existing = {
          "name" => "system_announcements",
          "primary_key" => "_id",
          "ignore" => true,
          "belongs_tos" => [],
          "fields" => [{ "name" => "_id" }],
        }
        File.write(path, JSON.pretty_generate(existing))

        described_class.new(models: [MongoidDummy::SystemAnnouncement], output_dir: output_dir).generate!

        expect(JSON.parse(File.read(path))["ignore"]).to eq(true)
      end

      it "preserves an embedded config's masking and embedded_in across regeneration" do
        # Regenerating an *embedded* collection is a distinct merge path: the
        # existing file is read back through `MongodbCollectionConfig.from`, which
        # runs `validate_embedded!` (an embedded config must carry an empty
        # belongs_tos), and the merge takes `embedded_in` from the freshly
        # generated config. This proves a user's hand-edited `replace_with` on an
        # embedded field survives while the structural `embedded_in`
        # (collection_name "users", path "posts") is re-derived from the model,
        # and that the rewritten file is itself re-readable.
        path = File.join(output_dir, "posts.json")
        existing = {
          "name" => "posts",
          "primary_key" => "_id",
          "belongs_tos" => [],
          "embedded_in" => { "collection_name" => "users", "path" => "posts" },
          "fields" => [
            { "name" => "_id" },
            { "name" => "title", "replace_with" => "masked-title-{_id}" },
            { "name" => "legacy_removed_field", "replace_with" => "should-disappear" },
          ],
        }
        File.write(path, JSON.pretty_generate(existing))

        described_class.new(models: [MongoidDummy::Post], output_dir: output_dir).generate!

        result = JSON.parse(File.read(path))
        # Structural embedded_in is re-derived from the model and kept.
        expect(result["embedded_in"]).to eq("collection_name" => "users", "path" => "posts")
        # An embedded config always carries an empty belongs_tos...
        expect(result["belongs_tos"]).to eq([])
        # ...the user's masking on a surviving field is preserved...
        expect(result["fields"].find { |f| f["name"] == "title" }["replace_with"]).to eq("masked-title-{_id}")
        # ...and a field no longer on the model is dropped.
        expect(result["fields"].map { |f| f["name"] }).not_to include("legacy_removed_field")

        # The rewritten file round-trips back through validate_embedded! (empty
        # belongs_tos), so a follow-up regeneration won't raise.
        reread = MongodbCollectionConfig.from(JSON.parse(File.read(path)))
        expect(reread.embedded?).to eq(true)
      end

      it "preserves bulk_insert_chunk_size and drops fields no longer on the model across regeneration" do
        # The full regeneration contract beyond replace_with/ignore: a
        # user-tuned `bulk_insert_chunk_size` survives, while the field list
        # tracks the model — a field that no longer exists on the model is
        # dropped (not retained as a stale entry) even if it carried a
        # `replace_with`, and surviving fields keep their masking.
        path = File.join(output_dir, "products.json")
        existing = {
          "name" => "products",
          "primary_key" => "_id",
          "bulk_insert_chunk_size" => 250,
          "belongs_tos" => [{ "table_name" => "shops", "foreign_key" => "shop_id" }],
          "fields" => [
            { "name" => "_id" },
            { "name" => "name", "replace_with" => "masked-{_id}" },
            { "name" => "legacy_removed_field", "replace_with" => "should-disappear" },
          ],
        }
        File.write(path, JSON.pretty_generate(existing))

        described_class.new(models: [MongoidDummy::Product], output_dir: output_dir).generate!

        result = JSON.parse(File.read(path))
        expect(result["bulk_insert_chunk_size"]).to eq(250)

        field_names = result["fields"].map { |f| f["name"] }
        # The model field keeps its masking...
        expect(result["fields"].find { |f| f["name"] == "name" }["replace_with"]).to eq("masked-{_id}")
        # ...the stale field (gone from the model) is dropped...
        expect(field_names).not_to include("legacy_removed_field")
        # ...and fields the model declares are present.
        expect(field_names).to include("price", "ctry", "shop_id")
        # ...with the freshly-derived mongoid_field_name re-applied on regen
        # (the hand-edited file above carried none).
        expect(result["fields"].find { |f| f["name"] == "ctry" }["mongoid_field_name"]).to eq("country")
      end

      # Full-output snapshot of every generated config for the dummy app. The
      # per-attribute tests above pin individual contracts; this one freezes the
      # entire emitted JSON so any unintended shape change (field order, a new
      # collection, a dropped belongs_to, an embedded_in path) shows up as a
      # diff. Regenerate after an intentional change with `UPDATE_SNAPSHOTS=1`.
      it "matches the generated-config snapshots" do
        snapshot_dir = File.expand_path("mongoid_schema_output_snapshots", __dir__)

        # Safe mode off, so the snapshots freeze the structural output (fields,
        # belongs_tos, embedded_in) rather than a mask per field; safe mode's
        # emission is pinned by its own examples below.
        described_class.new(models: models, output_dir: output_dir, safe_new_columns: false).generate!
        actual_paths = Dir[File.join(output_dir, "*.json")].sort

        if ENV["UPDATE_SNAPSHOTS"]
          FileUtils.mkdir_p(snapshot_dir)
          FileUtils.rm_f(Dir[File.join(snapshot_dir, "*.json")])
          actual_paths.each do |p|
            FileUtils.cp(p, File.join(snapshot_dir, File.basename(p)))
          end
          skip "snapshots regenerated (#{actual_paths.size} files)"
        end

        snapshot_paths = Dir[File.join(snapshot_dir, "*.json")].sort
        expect(snapshot_paths).not_to be_empty,
          "no snapshots under #{snapshot_dir}. regenerate with UPDATE_SNAPSHOTS=1"

        expect(actual_paths.map { |p| File.basename(p) })
          .to eq(snapshot_paths.map { |p| File.basename(p) })

        snapshot_paths.each do |snapshot_path|
          basename = File.basename(snapshot_path)
          actual = File.read(File.join(output_dir, basename))
          expect(actual).to eq(File.read(snapshot_path)),
            "snapshot mismatch in #{basename}"
        end
      end
    end

    describe "safe mode" do
      def generate_safe(models_to_use = models)
        described_class.new(models: models_to_use, output_dir: output_dir, safe_new_columns: true).generate!
      end

      def config_for(collection_name)
        JSON.parse(File.read(File.join(output_dir, "#{collection_name}.json")))
      end

      def fields_of(collection_name)
        config_for(collection_name)["fields"].to_h { |f| [f["name"], f] }
      end

      it "masks each field with a default its Mongoid type can hold and flags it for a decision" do
        generate_safe([MongoidDummy::TypedDocument])

        expect(config_for("typed_documents")["fields"]).to eq([
          # Structural: the primary key and the belongs_to foreign key are
          # flagged but never masked.
          { "name" => "_id", "needs_mask_decision" => true },
          { "name" => "title", "replace_with" => "masked-{_id}", "needs_mask_decision" => true },
          # A field whose name mentions mail keeps the mask a valid address.
          { "name" => "contact_email", "replace_with" => "masked-{_id}@example.com", "needs_mask_decision" => true },
          { "name" => "count", "replace_with" => 0, "needs_mask_decision" => true },
          { "name" => "ratio", "replace_with" => 0, "needs_mask_decision" => true },
          { "name" => "amount", "replace_with" => 0, "needs_mask_decision" => true },
          # `default: true` wins over the per-type `false`, so masking the flag
          # does not turn the feature off for every document in the dump.
          { "name" => "active", "replace_with" => true, "needs_mask_decision" => true },
          { "name" => "published_on", "replace_with" => "2000-01-01", "needs_mask_decision" => true },
          { "name" => "published_at", "replace_with" => "2000-01-01 00:00:00", "needs_mask_decision" => true },
          # No constant fits a Hash / Array / typeless field, so they are flagged
          # and left unmasked rather than restored as a value the application
          # cannot read.
          { "name" => "payload", "needs_mask_decision" => true },
          { "name" => "labels", "needs_mask_decision" => true },
          { "name" => "anything", "needs_mask_decision" => true },
          # Covered by a unique index: a constant would collapse every document
          # onto one value and break the restore with a duplicate key.
          { "name" => "serial", "needs_mask_decision" => true },
          { "name" => "shop_id", "needs_mask_decision" => true },
        ])
      end

      it "keeps a text mask on a field a unique index covers, since it varies per document" do
        # Shop#name is unique-indexed, but its mask interpolates the primary key,
        # so every restored document still gets a distinct value.
        generate_safe([MongoidDummy::Shop])

        expect(fields_of("shops")["name"]["replace_with"]).to eq("masked-{_id}")
      end

      it "flags the STI discriminator and every subclass foreign key without masking them" do
        # The unioned "events" config carries the auto-added `_type` (which is
        # what tells a PurchaseEvent from a LoginEvent inside the shared
        # collection) plus the base's `shop_id` and the subclass's `order_id`.
        # Masking any of them would break the dump's own lookups.
        generate_safe([MongoidDummy::Event])

        fields = fields_of("events")
        expect(fields.values_at("_type", "shop_id", "order_id")).to eq([
          { "name" => "_type", "needs_mask_decision" => true },
          { "name" => "shop_id", "needs_mask_decision" => true },
          { "name" => "order_id", "needs_mask_decision" => true },
        ])
        # A plain subclass field is still masked like any other.
        expect(fields["ip_address"]["replace_with"]).to eq("masked-{_id}")
      end

      it "flags the foreign key and type of a polymorphic belongs_to the config drops" do
        # Review#reviewable is excluded from belongs_tos (no single target
        # collection), but its auto-added reviewable_id/reviewable_type still
        # identify another collection's document, so masking either would rewrite
        # a live reference. They are structural despite the dropped relation.
        generate_safe([MongoidDummy::Review])

        fields = fields_of("reviews")
        expect(fields["reviewable_id"]).to eq({ "name" => "reviewable_id", "needs_mask_decision" => true })
        expect(fields["reviewable_type"]).to eq({ "name" => "reviewable_type", "needs_mask_decision" => true })
      end

      it "flags the fields of an embedded collection, foreign key included" do
        # An embedded config's belongs_tos are always empty, so its structural
        # fields cannot be read off them: Comment#author_id is dropped as a
        # relation yet still references a users document, and must stay unmasked.
        generate_safe([MongoidDummy::Comment])

        expect(config_for("comments")["fields"]).to eq([
          { "name" => "_id", "needs_mask_decision" => true },
          { "name" => "body", "replace_with" => "masked-{_id}", "needs_mask_decision" => true },
          { "name" => "author_id", "needs_mask_decision" => true },
        ])
      end

      it "leaves the generated config unchanged when off" do
        described_class.new(
          models: [MongoidDummy::Comment], output_dir: output_dir, safe_new_columns: false,
        ).generate!

        expect(config_for("comments")["fields"]).to eq([
          { "name" => "_id" }, { "name" => "body" }, { "name" => "author_id" },
        ])
      end

      it "keeps a decision a human already made and only flags what is new" do
        # The whole point of the flag: it marks the fields nobody has judged yet,
        # so a resolved decision — whichever way it went — must survive every
        # later regeneration untouched.
        generate_safe([MongoidDummy::TypedDocument])
        path = File.join(output_dir, "typed_documents.json")
        resolved = JSON.parse(File.read(path))
        resolved["fields"] = resolved["fields"].map do |field|
          case field["name"]
          when "title" then { "name" => "title", "replace_with" => "masked-{_id}", "comment" => "PII" }
          # Deliberately unmasked: this field is exported raw.
          when "contact_email" then { "name" => "contact_email" }
          else field.reject { |key, _| key == "needs_mask_decision" }
          end
        end
        File.write(path, JSON.pretty_generate(resolved) + "\n")

        generate_safe([MongoidDummy::TypedDocument])

        fields = fields_of("typed_documents")
        expect(fields["title"]).to eq({ "name" => "title", "replace_with" => "masked-{_id}", "comment" => "PII" })
        expect(fields["contact_email"]).to eq({ "name" => "contact_email" })
        expect(fields["count"]).to eq({ "name" => "count", "replace_with" => 0 })
      end
    end

    describe "#tidy!" do
      def write_config(name, hash)
        File.write(File.join(output_dir, "#{name}.json"), JSON.pretty_generate(hash) + "\n")
      end

      it "deletes the config file of a collection no model stores into any more" do
        described_class.new(models: models, output_dir: output_dir).generate!
        write_config("legacy_things", {
          "name" => "legacy_things",
          "primary_key" => "_id",
          "belongs_tos" => [],
          "fields" => [{ "name" => "_id" }, { "name" => "value" }],
        })

        result = described_class.new(models: models, output_dir: output_dir).tidy!

        expect(File).not_to exist(File.join(output_dir, "legacy_things.json"))
        expect(File).to exist(File.join(output_dir, "shops.json"))
        # Embedded collections are part of the same grouping generate! writes
        # from, so their configs are live too and must not be swept away.
        expect(File).to exist(File.join(output_dir, "posts.json"))
        expect(result.removed_tables).to contain_exactly("legacy_things")
        expect(result.removed_columns).to be_empty
      end

      it "keeps the config of a live collection the user has deliberately ignored" do
        # `ignore: true` is a decision about extraction, not a statement that the
        # collection is gone — its model still stores into it, so the config (and
        # the annotation explaining why it is ignored) has to survive.
        described_class.new(models: [MongoidDummy::SystemAnnouncement], output_dir: output_dir).generate!
        path = File.join(output_dir, "system_announcements.json")
        config = JSON.parse(File.read(path))
        config["ignore"] = true
        config["ignore_type"] = "unsupported"
        File.write(path, JSON.pretty_generate(config) + "\n")

        result = described_class.new(models: [MongoidDummy::SystemAnnouncement], output_dir: output_dir).tidy!

        expect(result).to be_empty
        expect(JSON.parse(File.read(path))["ignore_type"]).to eq("unsupported")
      end

      it "identifies a stale file by the collection it declares, not by its filename" do
        # The file name is only how write_files spells the collection name; a
        # hand-placed file can disagree, and what decides is the `name` inside.
        described_class.new(models: [MongoidDummy::Shop], output_dir: output_dir).generate!
        FileUtils.cp(File.join(output_dir, "shops.json"), File.join(output_dir, "renamed.json"))

        result = described_class.new(models: [MongoidDummy::Shop], output_dir: output_dir).tidy!

        # Both files declare the live "shops" collection, so neither is stale.
        expect(result).to be_empty
        expect(File).to exist(File.join(output_dir, "renamed.json"))
      end

      it "keeps a hand-written embedded config whose name matches no collection" do
        # Two embedded classes sharing a collection name leave only one of them
        # generated, so the other is written by hand under a name saying where it
        # lives. That name matches no model by construction, which is exactly why
        # tidy must not read it as dead: the file carries the masking rules for
        # those subdocuments, and deleting it exports them raw.
        described_class.new(models: models, output_dir: output_dir).generate!
        path = File.join(output_dir, "users_billing_addresses.json")
        File.write(path, JSON.pretty_generate(
          "name" => "users_billing_addresses",
          "primary_key" => "_id",
          "belongs_tos" => [],
          "embedded_in" => { "collection_name" => "users", "path" => "billing_address" },
          "fields" => [{ "name" => "_id" }, { "name" => "tel", "replace_with" => "masked" }],
        ) + "\n")

        result = described_class.new(models: models, output_dir: output_dir).tidy!

        expect(result).to be_empty
        expect(File).to exist(path)
      end

      it "leaves a file it cannot parse in place" do
        # Broken JSON says nothing about what the file describes, and the name it
        # would fall back to — the basename — matches no collection precisely
        # when the file is a hand-written embedded config, so deleting it would
        # bypass the guard above for the files that need it most.
        described_class.new(models: models, output_dir: output_dir).generate!
        path = File.join(output_dir, "users_billing_addresses.json")
        File.write(path, "{ not json")

        result = nil
        expect { result = described_class.new(models: models, output_dir: output_dir).tidy! }
          .to output(/not valid JSON/).to_stderr

        expect(result).to be_empty
        expect(File).to exist(path)
      end

      it "reports nothing to remove for a config that matches the models" do
        described_class.new(models: models, output_dir: output_dir).generate!

        expect(described_class.new(models: models, output_dir: output_dir).tidy!).to be_empty
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

      # Safe mode off so the only masking rules in play are the representative
      # ones injected right below — what is under test here is that the generated
      # *structure* addresses every embedded subdocument, not which defaults safe
      # mode proposes.
      let(:config_by_name) do
        collections = described_class.new(
          models: models, output_dir: output_dir, safe_new_columns: false,
        ).build_collections
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
        # Safe mode off: this asserts the untouched BSON values (created_at /
        # updated_at) serialize as Extended JSON, so the only masks are the two
        # injected here.
        collections = described_class.new(
          models: models, output_dir: output_dir, safe_new_columns: false,
        ).build_collections
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

    # End-to-end check that the `{_id}` placeholder safe mode puts into a text
    # mask is one the MongoDB dump path actually interpolates. The generator is
    # only allowed to emit such a template because MongodbAdapter compiles it and
    # renders it per document (see #compile_template / #render_template); if it
    # did not, every masked string field would restore as the literal
    # "masked-{_id}" and collide on any unique index. Nothing else pins that
    # contract from the safe-mode side, so it is asserted end to end here.
    describe "safe mode's default masks drive MongodbAdapter masking" do
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

      it "renders the generated {_id} placeholder per document instead of storing it literally" do
        by_name = described_class.new(
          models: [MongoidDummy::User], output_dir: output_dir, safe_new_columns: true,
        ).build_collections.each_with_object({}) { |c, h| h[c.name] = c }
        users_config = by_name.fetch("users")
        adapter.build_query(users_config, Exwiw::DumpTarget.new(table_name: "users", ids: []), by_name)

        oid = BSON::ObjectId.from_string("5f5e7c1e1c9d440000000001")
        masked = JSON.parse(adapter.to_bulk_insert([{
          "_id" => oid, "name" => "Alice", "email" => "alice@example.com", "shop_id" => 1,
        }], users_config))

        expect(masked["name"]).to eq("masked-5f5e7c1e1c9d440000000001")
        expect(masked["email"]).to eq("masked-5f5e7c1e1c9d440000000001@example.com")
        # Structural fields are exempt from safe mode's masks, so the id the
        # templates resolved against — and the foreign key the extraction follows
        # — are exported as they are.
        expect(masked["_id"]).to eq("$oid" => "5f5e7c1e1c9d440000000001")
        expect(masked["shop_id"]).to eq(1)
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
        # would have set after dumping shops — keyed per captured field (`_id`,
        # the field shop_id references by default).
        adapter.instance_variable_set(:@state, { "shops" => { "_id" => [1] } })
        dump_target = Exwiw::DumpTarget.new(table_name: "shops", ids: [1])

        query = adapter.build_query(config_by_name.fetch("users"), dump_target, config_by_name)
        # shops is users' sole genuine parent -> strict anchor.
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

      it "constrains a child by the parent's referenced non-_id field (generated references)" do
        # `belongs_to :entity, primary_key: :uuid` makes the generator emit
        # `references: "uuid"`. After the parent is dumped, `execute` stashes its
        # uuid values under @state["uuid_referenced_parents"]["uuid"]; the child
        # must $in-match `entity_id` against those uuid strings (issue B1), NOT
        # against the parent's ObjectId `_id`. Built in isolation since the uuid
        # models are intentionally kept out of MODELS/SEED.
        by_name = described_class.new(
          models: [MongoidDummy::UuidReferencingChild], output_dir: output_dir,
        ).build_collections.each_with_object({}) { |c, h| h[c.name] = c }

        adapter.instance_variable_set(
          :@state,
          { "uuid_referenced_parents" => { "_id" => [BSON::ObjectId.new], "uuid" => ["u-1", "u-2"] } },
        )
        dump_target = Exwiw::DumpTarget.new(table_name: "uuid_referenced_parents", ids: ["u-1"])

        query = adapter.build_query(by_name.fetch("uuid_referencing_children"), dump_target, by_name)
        # uuid_referenced_parents is the sole genuine parent -> strict anchor.
        expect(query.filter).to eq("entity_id" => { "$in" => ["u-1", "u-2"] })
      end

      it "emits independent $in filters for two belongs_tos targeting the same collection" do
        # transactions has TWO belongs_to -> users (paid_by_id, reviewer_id) plus
        # one -> orders. Each generated foreign_key must produce its own filter
        # key, the two user-targeting ones both constrained by the single
        # upstream "users" id set — proving the custom/relation-derived FKs the
        # generator emitted extract independently.
        adapter.instance_variable_set(:@state, { "users" => { "_id" => [10] }, "orders" => { "_id" => [30] } })
        dump_target = Exwiw::DumpTarget.new(table_name: "users", ids: [10])

        query = adapter.build_query(config_by_name.fetch("transactions"), dump_target, config_by_name)
        # All three genuine parents produced one id, so the first (order_id) is the
        # strict anchor; the others are applied null-aware (see related_collection_filter).
        expect(query.filter).to eq(
          "order_id" => { "$in" => [30] },
          "paid_by_id" => { "$in" => [nil, 10] },
          "reviewer_id" => { "$in" => [nil, 10] },
        )
      end
    end
  end
end

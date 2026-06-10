# frozen_string_literal: true

# Dummy Mongoid application used to exercise `Exwiw::MongoidSchemaGenerator`.
#
# It intentionally covers every MongoDB-specific feature exwiw considers:
#
# - top-level collections with the `_id` primary key (Shop, User, ...)
# - referenced `belongs_to` associations, whose foreign keys (`shop_id`,
#   `user_id`, ...) become ordinary fields exwiw tracks for FK-based extraction
# - referenced `belongs_to` associations whose relation name differs from the
#   target class and/or override the foreign key (Transaction#payer ->
#   "users"/"paid_by_id", Transaction#reviewer -> "users"/"reviewer_id"),
#   exercising that table_name comes from the target collection and foreign_key
#   from the association, never from the relation name itself
# - a *polymorphic* `belongs_to` (Review#reviewable), which has no single
#   target collection and which the generator must EXCLUDE from the emitted
#   belongs_tos (while keeping the regular Review#user belongs_to and tracking
#   the auto-added reviewable_id/reviewable_type fields)
# - a *referenced* `has_and_belongs_to_many` (Product <-> Tag), whose foreign
#   keys are stored as an ARRAY field (`tag_ids` / `product_ids`) on each side.
#   exwiw follows only single-valued foreign keys (a BelongsTo), so the
#   generator must EXCLUDE the HABTM relation from belongs_tos (it is a
#   `HasAndBelongsToMany`, not a `BelongsTo`) while still tracking the auto-added
#   `*_ids` array column as an ordinary field, like the polymorphic case
# - an *aliased* field (`field :ctry, as: :country` on Product), whose document
#   STORAGE key (`ctry`) differs from its Ruby accessor (`country`). exwiw masks
#   and projects by the stored document key, so the generator must emit the
#   storage key `ctry` (from `model.fields.keys`), never the `country` accessor
# - a collection with no relations at all (SystemAnnouncement)
# - embedded subdocuments via `embeds_many` / `embedded_in` (User embeds Posts)
# - *nested* embedded subdocuments (Post embeds Comments), represented as an
#   embedded chain: the Comment config is `embedded_in` its *immediate* parent
#   "posts" (path "comments"), not flattened to a dot-path under "users" — the
#   form MongodbAdapter walks recursively across the `posts` array
# - a *referenced* `belongs_to` declared on an embedded document
#   (Comment#author -> "users"), which the generator must DROP from the embedded
#   config's belongs_tos (cross-collection FKs from inside embedded arrays are
#   unsupported — MongodbCollectionConfig rejects them) while still tracking the
#   auto-added `author_id` as an ordinary field
# - a single embedded subdocument via `embeds_one` (User embeds one Profile),
#   which the dump path masks as a Hash rather than an array
# - a custom `store_as:` on an embedded relation (Profile is stored under the
#   document key "user_profile", not "profile"), which the generator must use
#   for `embedded_in.path` instead of the relation name
# - an embedded array nested *inside* an embeds_one Hash intermediate
#   (Profile embeds_many Contacts -> users.user_profile.contacts), proving the
#   embedded chain recurses across a Hash boundary into an array, not just
#   array-in-array (posts.comments)
# - a single embedded subdocument (embeds_one) nested *inside* an embeds_one Hash
#   intermediate (Profile embeds_one Address -> users.user_profile.address): the
#   Hash-in-Hash case, proving masking recurses through two consecutive Hash
#   boundaries (not just Hash-then-array like contacts). Together with the cases
#   above this completes the embedding-shape matrix: array-in-array,
#   array-in-Hash, Hash-leaf, and Hash-in-Hash
# - a model inheritance hierarchy whose subclasses share the base's collection
#   (Event / PurchaseEvent / LoginEvent all stored in "events", discriminated
#   by `_type`). Mongoid registers only the base in `Mongoid.models`, so the
#   generator must discover subclasses via `descendants` and union their
#   subclass-only fields and belongs_tos into one "events" config
# - `Mongoid::Timestamps` (`created_at` / `updated_at`), auto-added Time/BSON
#   Date columns the generator tracks as ordinary fields; at dump time their
#   BSON values — like an `ObjectId` `_id` — serialize as MongoDB Extended JSON
#   ($date / $oid). The SEED below uses plain Integer ids/Strings for
#   readability, so the BSON Extended JSON path is exercised with synthetic
#   BSON documents in the generator spec rather than from SEED.
# - indexes (unique / plain / compound), which the dump path introspects from
#   the live database via listIndexes rather than from the generated config
# - a *polymorphic* `embedded_in` (PolymorphicAddress), which has no single
#   embedding parent collection and is therefore UNREPRESENTABLE as an exwiw
#   `embedded_in` config; the generator must raise a clear error rather than
#   crash. It is kept out of `MODELS`/`SEED` and exercised in isolation.
# - a *self-referential / cyclic* embedding via `recursively_embeds_many`
#   (TreeNode) and its embeds_one counterpart `recursively_embeds_one`
#   (Category), which make a collection BOTH top-level AND embedded inside
#   documents of its own type (an array for TreeNode, a Hash for Category).
#   exwiw represents a collection as either top-level or embedded, not both, so
#   this is UNREPRESENTABLE: the generator must raise a clear error rather than
#   emit an `embedded_in` config that would silently make the collection
#   undumpable. Both are kept out of `MODELS`/`SEED`.
#
# Everything lives under the `MongoidDummy` namespace (with explicit
# `store_in collection:` and `class_name:`) so these models can coexist in the
# same test suite as the ActiveRecord dummy models in `script/models.rb`, which
# reuse the same bare class names (Shop, User, Order, ...).
#
# These models are introspected purely from class metadata; loading this file
# does not require a live MongoDB connection.

require "mongoid"

module MongoidDummy
  class Shop
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "shops"

    field :name, type: String

    has_many :users, class_name: "MongoidDummy::User"
    has_many :products, class_name: "MongoidDummy::Product"
    has_many :orders, class_name: "MongoidDummy::Order"

    index({ name: 1 }, unique: true, name: "idx_shops_name")
  end

  class User
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "users"

    field :name, type: String
    field :email, type: String

    belongs_to :shop, class_name: "MongoidDummy::Shop"

    # One-to-many relationship stored as an embedded subdocument array.
    embeds_many :posts, class_name: "MongoidDummy::Post"

    # One-to-one relationship stored as a single embedded subdocument (Hash).
    # `store_as:` overrides the document key, so it lives under "user_profile".
    embeds_one :profile, class_name: "MongoidDummy::Profile", store_as: "user_profile"

    index({ email: 1 }, name: "idx_users_email")
  end

  class Post
    include Mongoid::Document
    store_in collection: "posts"

    field :title, type: String

    embedded_in :user, class_name: "MongoidDummy::User"

    # Nested embedded subdocuments: comments live under users.posts.comments.
    embeds_many :comments, class_name: "MongoidDummy::Comment"
  end

  class Comment
    include Mongoid::Document
    store_in collection: "comments"

    field :body, type: String

    embedded_in :post, class_name: "MongoidDummy::Post"

    # A *referenced* belongs_to declared on an embedded document. Mongoid allows
    # an embedded subdocument to reference a top-level collection and auto-adds
    # the `author_id` foreign-key field. exwiw cannot follow cross-collection
    # foreign keys from inside an embedded array (MongodbCollectionConfig's
    # validate_embedded! rejects a non-empty belongs_tos on an embedded config),
    # so the generator must DROP this association from the emitted belongs_tos
    # while still tracking `author_id` as an ordinary (maskable) field.
    belongs_to :author, class_name: "MongoidDummy::User"
  end

  class Profile
    include Mongoid::Document
    store_in collection: "profiles"

    field :phone, type: String
    field :bio, type: String

    embedded_in :user, class_name: "MongoidDummy::User"

    # Array of subdocuments nested *inside* the embeds_one Hash intermediate
    # (users.user_profile.contacts). This exercises masking that crosses a Hash
    # boundary (the embeds_one profile) into an embedded array — distinct from
    # the array-in-array (posts.comments) and Hash-leaf (user_profile) cases.
    embeds_many :contacts, class_name: "MongoidDummy::Contact"

    # A *single* subdocument (embeds_one) nested inside the embeds_one Hash
    # intermediate (users.user_profile.address). This is the Hash-in-Hash case:
    # the chain is users -> user_profile (Hash) -> address (Hash leaf), distinct
    # from the array-in-Hash (contacts) case above. It proves masking recurses
    # through two consecutive Hash boundaries, not just into an array.
    embeds_one :address, class_name: "MongoidDummy::Address"
  end

  class Contact
    include Mongoid::Document
    store_in collection: "contacts"

    field :phone, type: String
    field :label, type: String

    embedded_in :profile, class_name: "MongoidDummy::Profile"
  end

  # The Hash-in-Hash leaf: a single embedded subdocument (embeds_one) inside the
  # embeds_one `user_profile` Hash, so it lives at users.user_profile.address.
  # The generator must name its immediate parent collection ("profiles") and the
  # relative path ("address"); MongodbAdapter resolves the full chain by
  # recursing across the two Hash boundaries.
  class Address
    include Mongoid::Document
    store_in collection: "addresses"

    field :city, type: String
    field :zip, type: String

    embedded_in :profile, class_name: "MongoidDummy::Profile"
  end

  class Product
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "products"

    field :name, type: String
    field :price, type: Integer

    # An *aliased* field: the Ruby accessor is `country` but the document key
    # stored in MongoDB is the short `ctry` (a common Mongoid optimization,
    # since the key is repeated in every document). `model.fields.keys` yields
    # the STORAGE key, so the generator must emit `ctry` — the key that actually
    # appears in the document and that masking/projection must target — never the
    # `country` accessor alias.
    field :ctry, as: :country, type: String

    belongs_to :shop, class_name: "MongoidDummy::Shop"

    has_many :order_items, class_name: "MongoidDummy::OrderItem"

    # has_and_belongs_to_many: Mongoid stores the related ids as an ARRAY field
    # (`tag_ids`) on this side. exwiw cannot follow an array-valued foreign key
    # as a single BelongsTo, so the generator must drop the HABTM relation from
    # belongs_tos while keeping `tag_ids` as an ordinary field.
    has_and_belongs_to_many :tags, class_name: "MongoidDummy::Tag"
  end

  class Tag
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "tags"

    field :label, type: String

    # The inverse HABTM side; stores `product_ids` as an array field.
    has_and_belongs_to_many :products, class_name: "MongoidDummy::Product"
  end

  class Order
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "orders"

    belongs_to :shop, class_name: "MongoidDummy::Shop"
    belongs_to :user, class_name: "MongoidDummy::User"

    has_many :order_items, class_name: "MongoidDummy::OrderItem"

    index({ shop_id: 1, user_id: 1 }, name: "idx_orders_shop_user")
  end

  class OrderItem
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "order_items"

    field :quantity, type: Integer

    belongs_to :order, class_name: "MongoidDummy::Order"
    belongs_to :product, class_name: "MongoidDummy::Product"
  end

  class Transaction
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "transactions"

    field :kind, type: String
    field :amount, type: Integer

    belongs_to :order, class_name: "MongoidDummy::Order"

    # belongs_to whose relation name (`payer`) differs from the target class
    # (User / "users") AND overrides the foreign key. The generator must derive
    # table_name "users" from the target *collection* (not the relation name)
    # and foreign_key "paid_by_id" from the association's declared key (not the
    # default "payer_id").
    belongs_to :payer, class_name: "MongoidDummy::User", foreign_key: "paid_by_id"

    # belongs_to whose relation name (`reviewer`) differs from the target class
    # (User / "users") with the default foreign key. The generator must derive
    # table_name "users" from the target collection and foreign_key
    # "reviewer_id" from the relation name (not the class name).
    belongs_to :reviewer, class_name: "MongoidDummy::User"
  end

  # Inheritance hierarchy. Mongoid stores every subclass in the *base* model's
  # collection ("events"), distinguished by an auto-added `_type` discriminator
  # field, and registers ONLY the base class in `Mongoid.models`. The generator
  # must therefore discover the subclasses via `descendants` and union their
  # fields/associations into the single "events" collection config:
  #
  # - PurchaseEvent contributes a subclass-only field (`amount`) and a
  #   subclass-only `belongs_to :order` (foreign key "order_id")
  # - LoginEvent contributes its own field (`ip_address`)
  # - the base's `belongs_to :shop` (foreign key "shop_id") and `_type` round
  #   out the unioned field/belongs_to set
  class Event
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "events"

    field :name, type: String

    belongs_to :shop, class_name: "MongoidDummy::Shop"
  end

  class PurchaseEvent < Event
    field :amount, type: Integer

    belongs_to :order, class_name: "MongoidDummy::Order"
  end

  class LoginEvent < Event
    field :ip_address, type: String
  end

  # Polymorphic belongs_to. `reviewable` can point at any model (a Product or
  # an Order here), so it has no single target collection. Mongoid auto-adds
  # `reviewable_id` and `reviewable_type` discriminator fields. exwiw cannot
  # represent a multi-target FK in a single BelongsTo (the MongodbAdapter's
  # build_query keys filters by a single foreign_key/table_name pair and would
  # clobber the shared FK across the expanded targets), so the generator must
  # EXCLUDE polymorphic belongs_tos from the emitted config while still tracking
  # the auto-added `reviewable_id`/`reviewable_type` columns as ordinary fields.
  # The ordinary `belongs_to :user` on the same model must survive.
  class Review
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "reviews"

    field :rating, type: Integer

    belongs_to :user, class_name: "MongoidDummy::User"
    belongs_to :reviewable, polymorphic: true
  end

  class SystemAnnouncement
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "system_announcements"

    field :title, type: String
    field :content, type: String
  end

  # Polymorphic `embedded_in`. A `PolymorphicAddress` can be embedded inside
  # ANY parent type (a Shop or an Order here), so it has no single embedding
  # parent collection. exwiw's `embedded_in` names exactly one parent
  # collection + path, so this shape is UNREPRESENTABLE: the generator must
  # raise a clear, actionable error rather than crash on `assoc.klass` (which
  # raises a cryptic "uninitialized constant ...::Addressable" NameError while
  # trying to resolve the nonexistent single parent class).
  #
  # This model is deliberately kept OUT of `MODELS`/`SEED`: feeding it through
  # `build_collections` aborts the whole run, so the unsupported case is
  # exercised in isolation by the spec instead.
  class PolymorphicAddress
    include Mongoid::Document
    store_in collection: "polymorphic_addresses"

    field :street, type: String

    embedded_in :addressable, polymorphic: true
  end

  # Self-referential / cyclic embedding via `recursively_embeds_many`. Mongoid
  # declares a `cyclic: true` pair — `embeds_many :child_tree_nodes` and
  # `embedded_in :parent_tree_node`, both `class_name: "MongoidDummy::TreeNode"`
  # — so a TreeNode is BOTH a top-level document in "tree_nodes" AND embedded
  # inside documents of its own type (its children). exwiw represents a
  # collection as either top-level (dumpable on its own) or embedded (masked
  # through its parent), NEVER both: emitting `embedded_in` for this would mark
  # the whole "tree_nodes" collection embedded, so `MongodbAdapter#dumpable?`
  # would silently never dump the root nodes. The generator must therefore raise
  # a clear, actionable error rather than emit a config that loses data.
  #
  # Like `PolymorphicAddress`, this model is deliberately kept OUT of
  # `MODELS`/`SEED` (feeding it through `build_collections` aborts the run) and
  # is exercised in isolation by the spec.
  class TreeNode
    include Mongoid::Document
    store_in collection: "tree_nodes"

    field :name, type: String

    recursively_embeds_many
  end

  # The `embeds_one` counterpart of `TreeNode`. `recursively_embeds_one` declares
  # a `cyclic: true` pair — `embeds_one :child_category` and
  # `embedded_in :parent_category`, both pointing at `Category` — so a Category
  # is BOTH a top-level "categories" document AND embedded (as a single Hash
  # subdocument) inside documents of its own type. This is the same
  # unrepresentable top-level-AND-embedded shape as `TreeNode`, only via a Hash
  # rather than an array, so the generator must raise the same clear error. Like
  # `TreeNode` it is kept OUT of `MODELS`/`SEED` and exercised in isolation.
  class Category
    include Mongoid::Document
    store_in collection: "categories"

    field :name, type: String

    recursively_embeds_one
  end

  # A referenced `belongs_to` whose target class does not exist (e.g. pointing at
  # a model removed long ago). Mongoid resolves association classes lazily, so
  # the model itself loads fine; only `assoc.klass` — which the generator calls
  # to derive the target collection — raises a NameError. By default that aborts
  # the run; under `skip_unsupported` the generator skips the relation while
  # still tracking the auto-added `ghost_id` foreign-key field. Kept OUT of
  # `MODELS`/`SEED` and exercised in isolation.
  class StaleReferencer
    include Mongoid::Document
    store_in collection: "stale_referencers"

    field :note, type: String

    # No class_name, so Mongoid infers a `Ghost` class that does not exist
    # (mirroring a real stale `belongs_to :delivery_method` left behind after its
    # model was removed). The auto-added `ghost_id` field still rides along.
    belongs_to :ghost
  end

  # An embedded document whose embedding-parent class does not exist (a renamed /
  # removed parent named by `class_name`). The `embedded_in` association loads
  # lazily, but `assoc.klass` raises a NameError, which `embedded_in_for`
  # surfaces as an UnsupportedEmbedding. By default that aborts the run; under
  # `skip_unsupported` the collection is emitted as `ignore: true`. Kept OUT of
  # `MODELS`/`SEED` and exercised in isolation.
  class OrphanEmbedded
    include Mongoid::Document
    store_in collection: "orphan_embeddeds"

    field :note, type: String

    embedded_in :ghost_parent, class_name: "MongoidDummy::GhostParent"
  end

  # A parent that embeds the SAME child class under multiple document keys
  # without `inverse_of:`, so the child's `embedded_in` has no single resolvable
  # inverse. Mongoid raises `AmbiguousRelationship` when resolving
  # `assoc.inverse`, which `embedded_in_for` surfaces as an UnsupportedEmbedding
  # (exwiw cannot pick which of the several paths the child lives under). Kept
  # OUT of `MODELS`/`SEED` and exercised in isolation.
  class AmbiguousParent
    include Mongoid::Document
    store_in collection: "ambiguous_parents"

    embeds_many :primary_children, class_name: "MongoidDummy::AmbiguousChild"
    embeds_many :secondary_children, class_name: "MongoidDummy::AmbiguousChild"
  end

  class AmbiguousChild
    include Mongoid::Document
    store_in collection: "ambiguous_children"

    field :value, type: String

    embedded_in :ambiguous_parent, class_name: "MongoidDummy::AmbiguousParent"
  end

  # A referenced `belongs_to` whose foreign key points at a *non-_id* field on
  # the parent. `belongs_to :entity, primary_key: :uuid` makes the child store
  # the parent's `uuid` (a String) in `entity_id` rather than the parent's
  # ObjectId `_id`. The generator must surface this as a `references: "uuid"`
  # attribute so MongodbAdapter constrains children by `entity.uuid` instead of
  # `entity._id` (issue B1 — a uuid-`$in` against ObjectId `_id` matches nothing).
  # The parent must exist so `assoc.klass` resolves; both are kept OUT of
  # `MODELS`/`SEED` and exercised in isolation (so the snapshot/collection-count
  # contracts above are unaffected).
  class UuidReferencedParent
    include Mongoid::Document
    store_in collection: "uuid_referenced_parents"

    field :uuid, type: String
  end

  class UuidReferencingChild
    include Mongoid::Document
    store_in collection: "uuid_referencing_children"

    belongs_to :entity, class_name: "MongoidDummy::UuidReferencedParent", primary_key: :uuid
  end

  # All concrete document models in this dummy app, in a deterministic order.
  #
  # Mongoid only registers the *base* class of an inheritance hierarchy in
  # `Mongoid.models` (the source `from_rails_application` introspects), so this
  # list deliberately includes only `Event` and NOT its `PurchaseEvent` /
  # `LoginEvent` subclasses — the generator must discover them via
  # `descendants`.
  MODELS = [
    Shop, User, Post, Comment, Profile, Contact, Address, Product, Tag, Order, OrderItem, Transaction, Event,
    Review, SystemAnnouncement,
  ].freeze

  # Representative seed documents, keyed by collection name. These mirror the
  # physical document shapes the MongoDB adapter sees at dump time, so they
  # double as fixtures for asserting that the *generated* configs line up with
  # the real storage layout:
  #
  # - top-level documents carry their referenced `belongs_to` foreign keys
  #   (`shop_id`, `user_id`, ...) as ordinary fields
  # - `users` documents embed a `posts` array (embeds_many), each post embeds a
  #   `comments` array (nested embeds_many), and a single `user_profile` Hash
  #   (embeds_one with a custom `store_as`) that itself embeds a `contacts`
  #   array (an array nested inside the Hash intermediate) and a single `address`
  #   Hash (a Hash nested inside the Hash intermediate)
  #
  # The embedded subdocuments live *only* inside their parent here (there is no
  # standalone "posts"/"comments"/"profiles" collection), matching how exwiw
  # dumps them: the embedded configs are masked through the parent document at
  # their `embedded_in.path` rather than as their own jsonl.
  SEED = {
    "shops" => [
      { "_id" => 1, "name" => "Acme" },
    ],
    "users" => [
      {
        "_id" => 10,
        "name" => "Alice",
        "email" => "alice@example.com",
        "shop_id" => 1,
        "posts" => [
          {
            "_id" => 100,
            "title" => "Hello world",
            "comments" => [
              # `author_id` is the referenced belongs_to FK auto-added on the
              # embedded Comment; it rides along as an ordinary field even though
              # the generator drops the association itself.
              { "_id" => 1000, "body" => "Nice post", "author_id" => 10 },
              { "_id" => 1001, "body" => "Thanks for sharing", "author_id" => 10 },
            ],
          },
        ],
        "user_profile" => {
          "_id" => 200,
          "phone" => "090-0000-0000",
          "bio" => "hi there",
          "contacts" => [
            { "_id" => 300, "phone" => "080-1111-1111", "label" => "home" },
            { "_id" => 301, "phone" => "070-2222-2222", "label" => "work" },
          ],
          # Single embedded subdocument (embeds_one) inside the user_profile Hash
          # — the Hash-in-Hash leaf at users.user_profile.address.
          "address" => { "_id" => 400, "city" => "Tokyo", "zip" => "100-0001" },
        },
      },
    ],
    "products" => [
      # `tag_ids` is the HABTM array foreign key; it rides along as an ordinary
      # field even though the generator drops the HABTM relation itself.
      # `ctry` is the STORAGE key of the `country` aliased field — the document
      # carries `ctry`, not `country`.
      { "_id" => 20, "name" => "Widget", "price" => 500, "ctry" => "JP", "shop_id" => 1, "tag_ids" => [90, 91] },
    ],
    "tags" => [
      { "_id" => 90, "label" => "sale", "product_ids" => [20] },
      { "_id" => 91, "label" => "new", "product_ids" => [20] },
    ],
    "orders" => [
      { "_id" => 30, "shop_id" => 1, "user_id" => 10 },
    ],
    "order_items" => [
      { "_id" => 40, "quantity" => 2, "order_id" => 30, "product_id" => 20 },
    ],
    "transactions" => [
      { "_id" => 50, "kind" => "charge", "amount" => 1000, "order_id" => 30, "paid_by_id" => 10, "reviewer_id" => 10 },
    ],
    # Inheritance hierarchy: every subclass lives in the same "events"
    # collection, tagged by the `_type` discriminator Mongoid adds.
    "events" => [
      { "_id" => 70, "_type" => "MongoidDummy::PurchaseEvent", "name" => "purchase", "shop_id" => 1, "amount" => 500, "order_id" => 30 },
      { "_id" => 71, "_type" => "MongoidDummy::LoginEvent", "name" => "login", "shop_id" => 1, "ip_address" => "203.0.113.1" },
    ],
    # Polymorphic belongs_to: reviewable_id/reviewable_type identify the target
    # document, while the regular user_id FK is what exwiw actually follows.
    "reviews" => [
      { "_id" => 80, "rating" => 5, "user_id" => 10, "reviewable_id" => 20, "reviewable_type" => "MongoidDummy::Product" },
    ],
    "system_announcements" => [
      { "_id" => 60, "title" => "Maintenance", "content" => "Down at midnight" },
    ],
  }.freeze
end

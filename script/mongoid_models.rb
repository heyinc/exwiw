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
# - a collection with no relations at all (SystemAnnouncement)
# - embedded subdocuments via `embeds_many` / `embedded_in` (User embeds Posts)
# - *nested* embedded subdocuments (Post embeds Comments), represented as an
#   embedded chain: the Comment config is `embedded_in` its *immediate* parent
#   "posts" (path "comments"), not flattened to a dot-path under "users" — the
#   form MongodbAdapter walks recursively across the `posts` array
# - a single embedded subdocument via `embeds_one` (User embeds one Profile),
#   which the dump path masks as a Hash rather than an array
# - a custom `store_as:` on an embedded relation (Profile is stored under the
#   document key "user_profile", not "profile"), which the generator must use
#   for `embedded_in.path` instead of the relation name
# - an embedded array nested *inside* an embeds_one Hash intermediate
#   (Profile embeds_many Contacts -> users.user_profile.contacts), proving the
#   embedded chain recurses across a Hash boundary into an array, not just
#   array-in-array (posts.comments)
# - a model inheritance hierarchy whose subclasses share the base's collection
#   (Event / PurchaseEvent / LoginEvent all stored in "events", discriminated
#   by `_type`). Mongoid registers only the base in `Mongoid.models`, so the
#   generator must discover subclasses via `descendants` and union their
#   subclass-only fields and belongs_tos into one "events" config
# - indexes (unique / plain / compound), which the dump path introspects from
#   the live database via listIndexes rather than from the generated config
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
  end

  class Contact
    include Mongoid::Document
    store_in collection: "contacts"

    field :phone, type: String
    field :label, type: String

    embedded_in :profile, class_name: "MongoidDummy::Profile"
  end

  class Product
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "products"

    field :name, type: String
    field :price, type: Integer

    belongs_to :shop, class_name: "MongoidDummy::Shop"

    has_many :order_items, class_name: "MongoidDummy::OrderItem"
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

  # All concrete document models in this dummy app, in a deterministic order.
  #
  # Mongoid only registers the *base* class of an inheritance hierarchy in
  # `Mongoid.models` (the source `from_rails_application` introspects), so this
  # list deliberately includes only `Event` and NOT its `PurchaseEvent` /
  # `LoginEvent` subclasses — the generator must discover them via
  # `descendants`.
  MODELS = [
    Shop, User, Post, Comment, Profile, Contact, Product, Order, OrderItem, Transaction, Event,
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
  #   array (an array nested inside the Hash intermediate)
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
              { "_id" => 1000, "body" => "Nice post" },
              { "_id" => 1001, "body" => "Thanks for sharing" },
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
        },
      },
    ],
    "products" => [
      { "_id" => 20, "name" => "Widget", "price" => 500, "shop_id" => 1 },
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

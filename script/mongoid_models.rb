# frozen_string_literal: true

# Dummy Mongoid application used to exercise `Exwiw::MongoidSchemaGenerator`.
#
# It intentionally covers every MongoDB-specific feature exwiw considers:
#
# - top-level collections with the `_id` primary key (Shop, User, ...)
# - referenced `belongs_to` associations, whose foreign keys (`shop_id`,
#   `user_id`, ...) become ordinary fields exwiw tracks for FK-based extraction
# - a collection with no relations at all (SystemAnnouncement)
# - embedded subdocuments via `embeds_many` / `embedded_in` (User embeds Posts)
# - *nested* embedded subdocuments (Post embeds Comments), which the generator
#   must flatten into a dot-separated `embedded_in.path` ("posts.comments")
# - a single embedded subdocument via `embeds_one` (User embeds one Profile),
#   which the dump path masks as a Hash rather than an array
# - a custom `store_as:` on an embedded relation (Profile is stored under the
#   document key "user_profile", not "profile"), which the generator must use
#   for `embedded_in.path` instead of the relation name
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
  end

  class SystemAnnouncement
    include Mongoid::Document
    include Mongoid::Timestamps
    store_in collection: "system_announcements"

    field :title, type: String
    field :content, type: String
  end

  # All concrete document models in this dummy app, in a deterministic order.
  MODELS = [
    Shop, User, Post, Comment, Profile, Product, Order, OrderItem, Transaction, SystemAnnouncement,
  ].freeze
end

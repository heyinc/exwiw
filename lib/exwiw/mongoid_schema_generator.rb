# frozen_string_literal: true

require "fileutils"
require "json"

module Exwiw
  # Generates exwiw `MongodbCollectionConfig` files by introspecting Mongoid
  # document models. This is the MongoDB/Mongoid counterpart of
  # `SchemaGenerator` (which targets ActiveRecord); it is intentionally a
  # separate class and rake task because the two ORMs expose entirely
  # different metadata APIs.
  #
  # Introspection relies only on class-level Mongoid metadata
  # (`fields`, `relations`, `collection_name`), so it does not require a live
  # MongoDB connection.
  class MongoidSchemaGenerator
    def self.from_rails_application(output_dir:)
      Rails.application.eager_load!
      new(models: ::Mongoid.models, output_dir: output_dir)
    end

    def initialize(models:, output_dir:)
      @models = models
      @output_dir = output_dir
    end

    def generate!
      collections = build_collections
      write_files(@output_dir, collections)
      collections
    end

    # Returns an array of `MongodbCollectionConfig`, one per concrete model
    # (top-level collections and embedded subdocument configs alike).
    def build_collections
      concrete_models.map { |model| build_collection_for(model) }
    end

    def write_files(dir, collections)
      FileUtils.mkdir_p(dir)

      collections.each do |collection|
        path = File.join(dir, "#{collection.name}.json")
        config_to_write =
          if File.exist?(path)
            MongodbCollectionConfig.from(JSON.parse(File.read(path))).merge(collection)
          else
            collection
          end
        File.write(path, JSON.pretty_generate(config_to_write.to_hash) + "\n")
      end
    end

    private def build_collection_for(model)
      attrs = {
        name: model.collection_name.to_s,
        primary_key: "_id",
        fields: model.fields.keys.map { |name| { name: name } },
      }

      if model.embedded?
        # Cross-collection references from inside an embedded array are not
        # supported (MongodbCollectionConfig rejects them), so embedded configs
        # always carry an empty belongs_tos and instead declare where they live.
        attrs[:belongs_tos] = []
        attrs[:embedded_in] = embedded_in_for(model)
      else
        attrs[:belongs_tos] = aggregate_belongs_tos(model)
      end

      MongodbCollectionConfig.from_symbol_keys(attrs)
    end

    # Mongoid registers internal helper classes (e.g. the discriminator key
    # host) in `Mongoid.models`; those have no usable `collection_name`. Keep
    # only application documents.
    private def concrete_models
      @models.select do |model|
        model.respond_to?(:collection_name) &&
          model.name &&
          !model.name.start_with?("Mongoid::")
      end
    end

    private def aggregate_belongs_tos(model)
      belongs_to_assocs = model.relations.values.select do |assoc|
        assoc.is_a?(::Mongoid::Association::Referenced::BelongsTo)
      end

      # polymorphic belongs_to (`belongs_to :reviewable, polymorphic: true`) は
      # 単一の対象コレクションを持たないため現状未対応。誤った FK を出力しないよう
      # ここでは除外する (将来 ActiveRecord 版と同様に展開する余地を残す)。
      belongs_to_assocs
        .reject(&:polymorphic?)
        .map { |assoc| { table_name: assoc.klass.collection_name.to_s, foreign_key: assoc.foreign_key } }
    end

    # Walks the embedded chain up to the owning top-level collection, building a
    # dot-separated storage path. For `User embeds_many :posts` and
    # `Post embeds_many :comments`, the Comment config resolves to
    # `{ collection_name: "users", path: "posts.comments" }`.
    private def embedded_in_for(model)
      parts = []
      current = model

      loop do
        assoc = embedded_in_association(current)
        parent = assoc.klass
        parent_relation = parent.relations[assoc.inverse.to_s]
        # `store_as` defaults to the relation name and is the actual document
        # key the subdocuments are stored under.
        parts.unshift(parent_relation.store_as)

        if parent.embedded?
          current = parent
        else
          return { collection_name: parent.collection_name.to_s, path: parts.join(".") }
        end
      end
    end

    private def embedded_in_association(model)
      model.relations.values.find do |assoc|
        assoc.is_a?(::Mongoid::Association::Embedded::EmbeddedIn)
      end
    end
  end
end

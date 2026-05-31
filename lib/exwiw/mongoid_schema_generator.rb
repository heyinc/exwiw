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

    # Returns an array of `MongodbCollectionConfig`, one per *collection*
    # (top-level collections and embedded subdocument configs alike).
    #
    # Models are grouped by `collection_name` so an inheritance hierarchy whose
    # subclasses share the base's collection (Mongoid STI, discriminated by the
    # auto-added `_type` field) collapses into a single config that aggregates
    # every class's fields and associations. See `expand_with_descendants`.
    def build_collections
      models = expand_with_descendants(concrete_models)
      models
        .group_by { |model| model.collection_name.to_s }
        .map { |collection_name, group| build_collection_for(collection_name, group) }
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

    # Builds one config for the collection shared by `models` (usually a single
    # model, but an inheritance hierarchy contributes several). Fields and
    # belongs_tos are unioned across the group; processing least-derived first
    # keeps the base's fields leading the list and the output deterministic
    # regardless of input order or sibling subclasses.
    private def build_collection_for(collection_name, models)
      ordered = models.sort_by { |model| [model.fields.size, model.name] }

      attrs = {
        name: collection_name,
        primary_key: "_id",
        fields: aggregate_fields(ordered),
      }

      if ordered.any?(&:embedded?)
        # Cross-collection references from inside an embedded array are not
        # supported (MongodbCollectionConfig rejects them), so embedded configs
        # always carry an empty belongs_tos and instead declare where they live.
        attrs[:belongs_tos] = []
        attrs[:embedded_in] = embedded_in_for(ordered.find(&:embedded?))
      else
        attrs[:belongs_tos] = aggregate_belongs_tos(ordered)
      end

      MongodbCollectionConfig.from_symbol_keys(attrs)
    end

    # Mongoid registers only the base class of an inheritance hierarchy in
    # `Mongoid.models`; subclasses that store into the base's collection
    # (STI-style, distinguished by the auto-added `_type` discriminator) are
    # reachable only via `descendants`, and the base's own metadata does NOT
    # include subclass-only fields or associations. Expand the model set with
    # descendants so each collection's config aggregates every class that
    # stores into it. (A subclass that overrides `store_in` to a different
    # collection naturally falls into its own group via the `collection_name`
    # grouping in `build_collections`.)
    private def expand_with_descendants(models)
      concrete((models + models.flat_map(&:descendants)).uniq)
    end

    # Mongoid registers internal helper classes (e.g. the discriminator key
    # host) in `Mongoid.models`; those have no usable `collection_name`. Keep
    # only application documents.
    private def concrete_models
      concrete(@models)
    end

    private def concrete(models)
      models.select do |model|
        model.respond_to?(:collection_name) &&
          model.name &&
          !model.name.start_with?("Mongoid::")
      end
    end

    # Unions the declared field names across `models`, preserving first-seen
    # order. A subclass's `fields` already includes everything it inherits, so
    # the base's fields lead and each subclass appends only its own.
    private def aggregate_fields(models)
      seen = {}
      models.each_with_object([]) do |model, fields|
        model.fields.keys.each do |name|
          next if seen[name]

          seen[name] = true
          fields << { name: name }
        end
      end
    end

    private def aggregate_belongs_tos(models)
      belongs_to_assocs = models.flat_map do |model|
        model.relations.values.select do |assoc|
          assoc.is_a?(::Mongoid::Association::Referenced::BelongsTo)
        end
      end

      # polymorphic belongs_to (`belongs_to :reviewable, polymorphic: true`) は
      # 単一の対象コレクションを持たないため現状未対応。誤った FK を出力しないよう
      # ここでは除外する (将来 ActiveRecord 版と同様に展開する余地を残す)。
      #
      # 継承階層では基底クラスとサブクラスが同じ belongs_to を二重に持つため uniq する。
      belongs_to_assocs
        .reject(&:polymorphic?)
        .map { |assoc| { table_name: assoc.klass.collection_name.to_s, foreign_key: assoc.foreign_key } }
        .uniq
    end

    # Resolves the `embedded_in` config for an embedded model. Each embedded
    # model points at its *immediate* embedding parent: the parent's collection
    # name plus the single document key (`store_as`, defaulting to the relation
    # name) the subdocuments live under within that parent.
    #
    # Multi-level nesting is represented one link at a time, NOT flattened into
    # a dot-separated path. For `User embeds_many :posts` and
    # `Post embeds_many :comments`, the Post config resolves to
    # `{ collection_name: "users", path: "posts" }` and the Comment config to
    # `{ collection_name: "posts", path: "comments" }`. `MongodbAdapter` walks
    # this chain recursively (masking each `posts` subdocument, then its
    # `comments`), which is the only form that correctly traverses both array
    # (`embeds_many`) and Hash (`embeds_one`) intermediates — a flattened
    # `posts.comments` path would stop at the `posts` array boundary.
    private def embedded_in_for(model)
      assoc = embedded_in_association(model)

      # A polymorphic `embedded_in` (`embedded_in :addressable, polymorphic: true`)
      # can live inside several different parent collections, so it has no single
      # embedding parent and `assoc.klass` would raise a cryptic NameError
      # (uninitialized constant) trying to resolve one. exwiw's `embedded_in`
      # names exactly one parent collection + path, so this shape cannot be
      # represented; fail loudly with an actionable message instead of crashing.
      if assoc.polymorphic?
        raise ArgumentError,
              "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
              "declares a polymorphic `embedded_in :#{assoc.name}`, which has no single embedding " \
              "parent collection and cannot be expressed as an exwiw `embedded_in` config. " \
              "Define the collection's config by hand, or make the relation non-polymorphic."
      end

      parent = assoc.klass

      # A self-referential / cyclic `embedded_in` — Mongoid's
      # `recursively_embeds_many` / `recursively_embeds_one` (which declare a
      # `cyclic: true` `embedded_in`/`embeds_*` pair pointing at the same model),
      # or any hand-rolled self-embedding — makes a collection BOTH a top-level
      # document AND embedded inside documents of its own type. exwiw represents
      # a collection as either top-level (dumpable on its own) or embedded
      # (masked through its parent at `path`), never both: emitting an
      # `embedded_in` here would mark the whole collection embedded, so
      # `MongodbAdapter#dumpable?` (`!embedded?`) would silently never dump the
      # collection's root documents. Fail loudly instead.
      if parent.collection_name.to_s == model.collection_name.to_s
        raise ArgumentError,
              "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
              "declares a self-referential (cyclic) `embedded_in :#{assoc.name}` that embeds the " \
              "collection inside documents of its own type (e.g. `recursively_embeds_many`). " \
              "exwiw represents a collection as either top-level or embedded, not both, so this " \
              "cannot be expressed as an exwiw `embedded_in` config. Define the collection's config " \
              "by hand."
      end

      # `store_as` defaults to the relation name and is the actual document key
      # the subdocuments are stored under inside the immediate parent.
      parent_relation = parent.relations[assoc.inverse.to_s]

      { collection_name: parent.collection_name.to_s, path: parent_relation.store_as }
    end

    private def embedded_in_association(model)
      model.relations.values.find do |assoc|
        assoc.is_a?(::Mongoid::Association::Embedded::EmbeddedIn)
      end
    end
  end
end

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
    # Raised when an embedded collection's `embedded_in` cannot be expressed as
    # an exwiw config (polymorphic embedding, self-referential/cyclic embedding,
    # or an unresolvable embedding-parent class). A subclass of ArgumentError so
    # the historical `raise_error(ArgumentError, ...)` contract is preserved.
    # Under `skip_unsupported` the generator rescues this and emits an
    # `ignore: true` config instead of aborting the whole run.
    class UnsupportedEmbedding < ArgumentError
      # A concise phrase (as opposed to the long, actionable exception message)
      # recorded as the generated config's `comment`.
      attr_reader :reason

      def initialize(message, reason:)
        super(message)
        @reason = reason
      end
    end

    # `skip_unsupported`: when true, the generator does not abort on a construct
    # it cannot represent. It skips an unresolvable `belongs_to` (keeping the
    # foreign-key field) and emits an unrepresentable embedded collection as an
    # `ignore: true` top-level config annotated with a `comment`, warning to
    # stderr in both cases. Off by default, so the historical fail-loud behavior
    # is unchanged unless a caller opts in.
    def self.from_rails_application(output_dir:, skip_unsupported: false)
      Rails.application.eager_load!
      new(models: ::Mongoid.models, output_dir: output_dir, skip_unsupported: skip_unsupported)
    end

    def initialize(models:, output_dir:, skip_unsupported: false)
      @models = models
      @output_dir = output_dir
      @skip_unsupported = skip_unsupported
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
        begin
          attrs[:embedded_in] = embedded_in_for(ordered.find(&:embedded?))
        rescue => e
          # Known-unrepresentable shapes arrive as UnsupportedEmbedding (with a
          # concise reason). Without skip_unsupported, re-raise so the historical
          # fail-loud behavior is preserved. The broad rescue is a deliberate
          # safety net for skip_unsupported (a best-effort bootstrapping mode):
          # any other error while deriving the embedding is turned into an
          # `ignore: true` config too, so a single odd model never aborts the run.
          raise e unless @skip_unsupported

          reason =
            if e.is_a?(UnsupportedEmbedding)
              e.reason
            else
              "raised #{e.class} while deriving embedded_in (#{e.message.lines.first&.strip})"
            end

          # Emit the collection as a top-level config marked `ignore: true` so it
          # is NOT (wrongly) dumped as its own collection, and record why. The
          # user can hand-write its embedded_in config later to dump/mask it.
          warn("exwiw: skip_unsupported: '#{collection_name}' #{reason}; emitting ignore:true (define embedded_in by hand to dump/mask it).")
          attrs[:ignore] = true
          attrs[:comment] = "exwiw could not derive embedded_in (#{reason}); marked ignore:true. Define this collection's embedded_in config by hand to dump/mask it."
        end
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
        accessor_by_storage = aliased_field_accessors(model)
        model.fields.keys.each do |name|
          next if seen[name]

          seen[name] = true
          field = { name: name }
          # When `field :ctry, as: :country` renamed the storage key, surface the
          # Ruby accessor so the short key is not cryptic in the config.
          accessor = accessor_by_storage[name]
          field[:mongoid_field_name] = accessor if accessor
          fields << field
        end
      end
    end

    # Maps a stored document key -> its Mongoid Ruby accessor, but ONLY for
    # genuine `field ..., as:` renames. `Model.aliased_fields` also contains the
    # built-in `id => _id` and one entry per association (e.g. `shop => shop_id`,
    # `profile => user_profile`); those are not field renames, so exclude any
    # accessor that names a relation, the `_id` storage key, or a no-op alias.
    private def aliased_field_accessors(model)
      relation_names = model.relations.keys
      model.aliased_fields.each_with_object({}) do |(accessor, storage), acc|
        next if accessor == storage
        next if storage == "_id"
        next if relation_names.include?(accessor)
        next unless model.fields.key?(storage)

        acc[storage] = accessor
      end
    end

    private def aggregate_belongs_tos(models)
      belongs_to_assocs = models.flat_map do |model|
        model.relations.values.select do |assoc|
          assoc.is_a?(::Mongoid::Association::Referenced::BelongsTo)
        end
      end

      # A polymorphic belongs_to (`belongs_to :reviewable, polymorphic: true`)
      # has no single target collection, so it is not supported yet. Exclude it
      # here to avoid emitting an incorrect FK (leaving room to expand it later,
      # like the ActiveRecord version does).
      #
      # In an inheritance hierarchy the base class and its subclasses carry the
      # same belongs_to twice, so uniq them.
      belongs_to_assocs
        .reject(&:polymorphic?)
        .filter_map { |assoc| belongs_to_for(assoc) }
        .uniq
    end

    # Resolves a referenced belongs_to to a `{ table_name, foreign_key }` pair.
    # `assoc.klass` raises NameError when the association's target class no longer
    # exists (a stale/legacy `belongs_to`, e.g. pointing at a model removed years
    # ago). Under `skip_unsupported` such a relation is skipped with a warning —
    # its foreign-key column is still tracked as an ordinary field by
    # `aggregate_fields`, mirroring how polymorphic / HABTM relations are dropped.
    private def belongs_to_for(assoc)
      { table_name: assoc.klass.collection_name.to_s, foreign_key: assoc.foreign_key }
    rescue NameError, ::Mongoid::Errors::MongoidError => e
      raise e unless @skip_unsupported

      warn("exwiw: skip_unsupported: skipping belongs_to ':#{assoc.name}' that could not be resolved (#{e.class}: #{e.message.lines.first&.strip}); its foreign key '#{assoc.foreign_key}' is still kept as a field.")
      nil
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
        raise UnsupportedEmbedding.new(
          "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
          "declares a polymorphic `embedded_in :#{assoc.name}`, which has no single embedding " \
          "parent collection and cannot be expressed as an exwiw `embedded_in` config. " \
          "Define the collection's config by hand, or make the relation non-polymorphic.",
          reason: "has a polymorphic embedded_in :#{assoc.name}",
        )
      end

      parent =
        begin
          assoc.klass
        rescue NameError => e
          # The embedding-parent class named by `class_name` (or inferred from
          # the relation) does not exist — a stale/renamed parent. exwiw cannot
          # name a parent collection it cannot resolve.
          raise UnsupportedEmbedding.new(
            "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
            "declares `embedded_in :#{assoc.name}` whose parent class cannot be resolved " \
            "(#{e.message.lines.first&.strip}). Fix the association's class_name, or define the " \
            "collection's config by hand.",
            reason: "has an embedded_in :#{assoc.name} whose parent class is unresolvable",
          )
        end

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
        raise UnsupportedEmbedding.new(
          "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
          "declares a self-referential (cyclic) `embedded_in :#{assoc.name}` that embeds the " \
          "collection inside documents of its own type (e.g. `recursively_embeds_many` / " \
          "`recursively_embeds_one`). " \
          "exwiw represents a collection as either top-level or embedded, not both, so this " \
          "cannot be expressed as an exwiw `embedded_in` config. Define the collection's config " \
          "by hand.",
          reason: "has a self-referential (cyclic) embedded_in :#{assoc.name}",
        )
      end

      # `store_as` defaults to the relation name and is the actual document key
      # the subdocuments are stored under inside the immediate parent.
      parent_relation =
        begin
          parent.relations[assoc.inverse.to_s]
        rescue ::Mongoid::Errors::MongoidError, NameError => e
          # e.g. AmbiguousRelationship: the embedded class is embedded under
          # several document keys in the parent (or otherwise has no single
          # resolvable inverse), so exwiw cannot pick the one path it lives under.
          raise UnsupportedEmbedding.new(
            "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
            "declares `embedded_in :#{assoc.name}` whose inverse on '#{parent.name}' is ambiguous " \
            "or unresolvable (#{e.class}: #{e.message.lines.first&.strip}). Add an `inverse_of:` to " \
            "disambiguate, or define the collection's config by hand.",
            reason: "has an embedded_in :#{assoc.name} with an ambiguous/unresolvable inverse",
          )
        end

      unless parent_relation
        # `assoc.inverse` resolved to a name that is not an association on the
        # parent (or to nothing), so there is no document key to embed under.
        raise UnsupportedEmbedding.new(
          "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
          "declares `embedded_in :#{assoc.name}` but its inverse relation could not be located on " \
          "'#{parent.name}' (the embedding document key is indeterminable). Add an `inverse_of:`, or " \
          "define the collection's config by hand.",
          reason: "has an embedded_in :#{assoc.name} whose inverse relation could not be located",
        )
      end

      { collection_name: parent.collection_name.to_s, path: parent_relation.store_as }
    end

    private def embedded_in_association(model)
      model.relations.values.find do |assoc|
        assoc.is_a?(::Mongoid::Association::Embedded::EmbeddedIn)
      end
    end
  end
end

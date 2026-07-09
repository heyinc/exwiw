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
      collections = build_collections(existing_configs_by_name(@output_dir))
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
    #
    # `existing_by_name` maps a collection name to its config already on disk, so
    # the build can honor an explicit `ignore: true` (collection- or
    # belongs_to-level) without re-introspecting it — and thus without aborting
    # on a construct the user has deliberately ignored. Empty (the default) when
    # called directly without an output dir, in which case nothing is honored.
    def build_collections(existing_by_name = {})
      models = expand_with_descendants(concrete_models)
      embedding_index = build_embedding_index(models)
      models
        .group_by { |model| model.collection_name.to_s }
        .flat_map do |collection_name, group|
          build_configs_for(collection_name, group, existing_by_name, embedding_index)
        end
    end

    # Returns the config(s) for one collection group. Usually a single config;
    # an embedded class embedded at two or more distinct (parent, path)
    # occurrences yields one config per occurrence (see
    # #build_multi_occurrence_configs). Every other shape — top-level
    # collections, and embedded collections with a single or zero discoverable
    # occurrence — keeps the exact historical single-config behavior, so
    # existing file names, snapshots, and the fail-loud error handling for
    # unrepresentable embeddings are unchanged.
    private def build_configs_for(collection_name, models, existing_by_name, embedding_index)
      occurrences = embedding_index[collection_name]

      if models.any?(&:embedded?) && occurrences.size >= 2
        build_multi_occurrence_configs(collection_name, models, occurrences, existing_by_name)
      else
        [build_collection_for(collection_name, models, existing_by_name[collection_name])]
      end
    end

    # Loads the configs already on disk so the generator can honor an explicit
    # `ignore: true` without re-introspecting (and thus without aborting on a
    # construct the user has deliberately ignored). A file that cannot be read or
    # parsed is skipped — a fresh run simply has none, and write_files surfaces
    # genuine problems when it later merges/rewrites.
    private def existing_configs_by_name(dir)
      return {} unless dir && File.directory?(dir)

      Dir[File.join(dir, "*.json")].each_with_object({}) do |path, acc|
        config = MongodbCollectionConfig.from(JSON.parse(File.read(path)))
        acc[config.name] = config
      rescue JSON::ParserError, ArgumentError
        next
      end
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
    private def build_collection_for(collection_name, models, existing = nil)
      # An explicit on-disk `ignore: true` means the user has triaged this
      # collection and asked exwiw to leave it alone: preserve their config
      # (ignore_type / comment intact) and skip introspection entirely, so a
      # construct exwiw cannot represent never aborts a run the user has already
      # accounted for. (A collection is never dumped while ignored, so its
      # fields/structure need not track the model.)
      return existing if existing&.ignore

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
        attrs[:belongs_tos] = aggregate_belongs_tos(ordered, existing)
      end

      MongodbCollectionConfig.from_symbol_keys(attrs)
    end

    # Emit one embedded config per (parent collection, document path) occurrence
    # of an embedded class that is embedded at two or more distinct places (e.g.
    # a shared `Address` value object embedded at both `orders/billing_address`
    # and `shipments/address`). The generator otherwise groups models by
    # collection name and would emit a SINGLE config bound to one `embedded_in`,
    # leaving the other occurrences with no config — so per-field masking
    # (`replace_with` / `ignore`) declared for that class applies at only one
    # location while the rest dump raw. The runtime already applies every
    # embedded config keyed by (embedded_in.collection_name, path)
    # independently, so emitting one config per occurrence closes the gap.
    #
    # Backward compatibility: the occurrence matching the class's declared
    # `embedded_in` keeps the collection's own name (so a config that was
    # previously single-occurrence keeps its file name and `embedded_in` on the
    # next regen, and only NEW files are added for the extra occurrences); each
    # additional occurrence gets a name disambiguated by its parent collection
    # and path so the files never collide. Each occurrence merges independently
    # against its own on-disk file in #write_files, preserving hand-edited masks
    # per occurrence across regeneration.
    private def build_multi_occurrence_configs(collection_name, models, occurrences, existing_by_name)
      ordered = models.sort_by { |model| [model.fields.size, model.name] }
      fields = aggregate_fields(ordered)

      sorted = occurrences.sort_by { |occurrence| [occurrence[:collection_name], occurrence[:path]] }
      primary = primary_occurrence(models, sorted)

      sorted.map do |occurrence|
        config_name =
          occurrence == primary ? collection_name : disambiguated_name(collection_name, occurrence)
        build_embedded_occurrence_config(config_name, fields, occurrence, existing_by_name[config_name])
      end
    end

    # The occurrence that keeps the collection's own (undisambiguated) name. It
    # is the one matching the class's declared `embedded_in` (so an existing
    # single-occurrence config is never renamed when a second occurrence
    # appears). When the declared `embedded_in` cannot be resolved to a single
    # occurrence (e.g. a polymorphic embedded_in, which #embedded_in_for raises
    # on) there is no pre-existing config to preserve, so the deterministically
    # first sorted occurrence is used.
    private def primary_occurrence(models, sorted_occurrences)
      declared =
        begin
          embedded_in_for(models.find(&:embedded?))
        rescue StandardError
          nil
        end

      if declared
        match = sorted_occurrences.find do |occurrence|
          occurrence[:collection_name] == declared[:collection_name] && occurrence[:path] == declared[:path]
        end
        return match if match
      end

      sorted_occurrences.first
    end

    # A collision-free config name for a non-primary occurrence, derived from the
    # embedded collection name plus the occurrence's parent collection and path
    # (dots in a multi-segment path flattened to underscores). Only the file name
    # / config identity changes; the runtime addresses the subdocuments purely by
    # `embedded_in.collection_name` + `path`, never by this name.
    private def disambiguated_name(collection_name, occurrence)
      "#{collection_name}__#{occurrence[:collection_name]}__#{occurrence[:path].tr('.', '_')}"
    end

    private def build_embedded_occurrence_config(config_name, fields, occurrence, existing)
      # Honor an explicit on-disk ignore per occurrence, exactly as
      # #build_collection_for does for the single-config case.
      return existing if existing&.ignore

      MongodbCollectionConfig.from_symbol_keys(
        name: config_name,
        primary_key: "_id",
        belongs_tos: [],
        embedded_in: { collection_name: occurrence[:collection_name], path: occurrence[:path] },
        fields: fields,
      )
    end

    # Maps an embedded collection name -> every (parent collection, document
    # path) occurrence it is embedded at, discovered by scanning ALL models'
    # `embeds_one` / `embeds_many` relations (the inverse of a single child's
    # `embedded_in`). Scanning the parents is what lets the generator represent a
    # class embedded at several distinct paths: the immediate embedding model's
    # collection_name is the parent (matching how a single-occurrence embedded
    # config names its immediate parent) and `store_as` is the path. STI
    # base+subclass pairs can surface the same relation twice, so duplicate
    # occurrences are collapsed. A relation whose target class no longer resolves
    # is skipped rather than aborting the whole index.
    private def build_embedding_index(models)
      index = Hash.new { |hash, key| hash[key] = [] }

      models.each do |model|
        model.relations.each_value do |rel|
          next unless rel.is_a?(::Mongoid::Association::Embedded::EmbedsMany) ||
                      rel.is_a?(::Mongoid::Association::Embedded::EmbedsOne)

          child_collection = embedded_child_collection_name(rel)
          next unless child_collection

          occurrence = { collection_name: model.collection_name.to_s, path: rel.store_as }
          occurrences = index[child_collection]
          occurrences << occurrence unless occurrences.include?(occurrence)
        end
      end

      index
    end

    private def embedded_child_collection_name(rel)
      rel.klass.collection_name.to_s
    rescue NameError, ::Mongoid::Errors::MongoidError
      nil
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

    private def aggregate_belongs_tos(models, existing = nil)
      ignored_by_fk = ignored_belongs_tos_by_foreign_key(existing)

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
        .filter_map { |assoc| belongs_to_for(assoc, ignored_by_fk) }
        .uniq
    end

    # Maps foreign_key -> the on-disk `ignore: true` belongs_to entry, so a
    # relation the user has explicitly ignored is preserved verbatim instead of
    # re-resolved (which, for a stale relation whose target class is gone, would
    # otherwise abort the run).
    private def ignored_belongs_tos_by_foreign_key(existing)
      return {} unless existing

      existing.belongs_tos.select(&:ignore).each_with_object({}) do |bt, acc|
        acc[bt.foreign_key] = bt
      end
    end

    # Resolves a referenced belongs_to to a `{ table_name, foreign_key }` pair
    # (plus `references` when the FK points at a non-`_id` parent field).
    # `assoc.klass` raises NameError when the association's target class no longer
    # exists (a stale/legacy `belongs_to`, e.g. pointing at a model removed years
    # ago). Under `skip_unsupported` such a relation is skipped with a warning —
    # its foreign-key column is still tracked as an ordinary field by
    # `aggregate_fields`, mirroring how polymorphic / HABTM relations are dropped.
    #
    # `ignored_by_fk` carries the on-disk `ignore: true` belongs_to entries: when
    # this relation's foreign key is among them, the user has explicitly ignored
    # it, so preserve their entry verbatim (its `ignore_type` / `comment`) without
    # resolving the — possibly gone — target. The relation is dropped from
    # extraction at load (`#reject_ignored_members!`) while its FK column stays a
    # field, and the run never aborts on a relation already triaged.
    private def belongs_to_for(assoc, ignored_by_fk = {})
      if (ignored = ignored_by_fk[assoc.foreign_key])
        return preserve_ignored_belongs_to(ignored)
      end

      result = { table_name: assoc.klass.collection_name.to_s, foreign_key: assoc.foreign_key }
      # Mongoid's `belongs_to ..., primary_key: :uuid` makes the child's foreign
      # key reference that parent field rather than the parent's `_id`. Surface
      # it as `references` so MongodbAdapter constrains children by the right
      # field (issue B1). Omit it for the default `_id` (the parent primary_key
      # the generator emits) so existing configs/snapshots are unchanged. SQL
      # adapters ignore `references`; only MongodbAdapter consumes it.
      reference_field = assoc.primary_key.to_s
      result[:references] = reference_field unless reference_field == "_id"
      result
    rescue NameError, ::Mongoid::Errors::MongoidError => e
      raise e unless @skip_unsupported

      warn("exwiw: skip_unsupported: skipping belongs_to ':#{assoc.name}' that could not be resolved (#{e.class}: #{e.message.lines.first&.strip}); its foreign key '#{assoc.foreign_key}' is still kept as a field.")
      nil
    end

    # Re-emits a user's on-disk ignored belongs_to as a symbol-keyed hash (the
    # shape `build_collection_for` feeds to `from_symbol_keys`), carrying its
    # `ignore` / `ignore_type` / `comment` (and `table_name` / `references` when
    # present) so the annotation survives regeneration untouched.
    private def preserve_ignored_belongs_to(bt)
      {
        table_name: bt.table_name,
        foreign_key: bt.foreign_key,
        references: bt.references,
        ignore: true,
        ignore_type: bt.ignore_type,
        comment: bt.comment,
      }.compact
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

      # Resolve the document key (`store_as`, defaulting to the relation name)
      # the subdocuments live under inside the parent.
      parent_relation = embedding_relation_in(parent, assoc, model)

      unless parent_relation
        # No embeds_one / embeds_many on the parent stores this collection, so
        # there is no document key to embed under.
        raise UnsupportedEmbedding.new(
          "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
          "declares `embedded_in :#{assoc.name}` but no embeds_one/embeds_many on '#{parent.name}' " \
          "stores this collection (the embedding document key is indeterminable). Add an `inverse_of:`, or " \
          "define the collection's config by hand.",
          reason: "has an embedded_in :#{assoc.name} whose inverse relation could not be located",
        )
      end

      { collection_name: parent.collection_name.to_s, path: parent_relation.store_as }
    end

    # Locates the parent's `embeds_one` / `embeds_many` association that stores
    # this embedded collection — i.e. the document key the subdocuments live
    # under. Mongoid's computed `assoc.inverse` is preferred when it resolves
    # cleanly, but it is frequently `nil` (no explicit `inverse_of:` and Mongoid
    # declines to infer one) or raises `AmbiguousRelationship`; in those cases
    # fall back to matching the parent's embedding relations by the collection
    # they store. This resolves the common single-embedding case that
    # `assoc.inverse` cannot (e.g. an `embeds_one :force_logout` / `embedded_in
    # :customer` pair with no inverse_of). Returns the relation, `nil` when none
    # stores this collection, and raises `UnsupportedEmbedding` when several
    # distinct keys do (genuinely ambiguous — exwiw cannot pick one).
    private def embedding_relation_in(parent, assoc, model)
      inverse_name =
        begin
          assoc.inverse
        rescue ::Mongoid::Errors::MongoidError, NameError
          nil
        end

      if inverse_name
        rel = parent.relations[inverse_name.to_s]
        return rel if rel
      end

      candidates = parent.relations.values.select do |rel|
        (rel.is_a?(::Mongoid::Association::Embedded::EmbedsMany) ||
          rel.is_a?(::Mongoid::Association::Embedded::EmbedsOne)) &&
          embeds_collection?(rel, model)
      end
      paths = candidates.map(&:store_as).uniq

      if paths.size > 1
        # The same collection is embedded under several document keys in the
        # parent, so `embedded_in :#{assoc.name}` has no single resolvable path.
        raise UnsupportedEmbedding.new(
          "MongoidSchemaGenerator: '#{model.name}' (collection '#{model.collection_name}') " \
          "is embedded under multiple document keys (#{paths.join(', ')}) in '#{parent.name}', so its " \
          "`embedded_in :#{assoc.name}` is ambiguous or unresolvable — exwiw cannot pick the single path " \
          "it lives under. Add an `inverse_of:` to disambiguate, or define the collection's config by hand.",
          reason: "has an embedded_in :#{assoc.name} with an ambiguous/unresolvable inverse",
        )
      end

      candidates.first
    end

    # True when `rel` (an embeds_one / embeds_many on the parent) stores the same
    # collection as `model`. Comparing collection names (rather than class
    # identity) also matches an STI subclass embedded through a relation declared
    # against its base class, since both share the base's collection. A sibling
    # embedding relation whose target class no longer resolves is treated as a
    # non-match rather than blowing up the whole derivation.
    private def embeds_collection?(rel, model)
      rel.klass.collection_name.to_s == model.collection_name.to_s
    rescue NameError, ::Mongoid::Errors::MongoidError
      false
    end

    private def embedded_in_association(model)
      model.relations.values.find do |assoc|
        assoc.is_a?(::Mongoid::Association::Embedded::EmbeddedIn)
      end
    end
  end
end

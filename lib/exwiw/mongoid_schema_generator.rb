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

    # Every generated collection is keyed by the MongoDB document id. Named so
    # the value the configs carry and the value `DefaultMask` interpolates into a
    # text mask (`masked-{_id}`) provably come from one place.
    PRIMARY_KEY = "_id"

    # Mongoid field types (`Model.fields[name].type`, a Ruby class) mapped to the
    # type symbols `DefaultMask.for` understands, so safe mode can reuse the very
    # same default masks the ActiveRecord generator emits.
    #
    # Keyed by class NAME rather than by the class itself: this constant is
    # evaluated when exwiw is loaded, which happens in processes that never load
    # Mongoid (the CLI), so naming `Mongoid::Boolean` here would raise. A name
    # comparison also sidesteps `DateTime < Date` — an ancestry test would have to
    # order its branches, while exact names cannot be confused for one another.
    #
    # Everything absent from this map (Hash, Array, Object — which is also what a
    # typeless/dynamic field reports — BSON types, Mongoid::StringifiedSymbol, ...)
    # deliberately gets NO default mask: a constant that does not fit the field
    # would be restored as a value the application cannot read, which is worse
    # than exporting the field while its `needs_mask_decision` flag keeps the
    # change from being merged.
    MASKABLE_FIELD_TYPES = {
      "String" => :string,
      "Integer" => :integer,
      "Float" => :float,
      "BigDecimal" => :decimal,
      "Mongoid::Boolean" => :boolean,
      "Time" => :datetime,
      "DateTime" => :datetime,
      "ActiveSupport::TimeWithZone" => :datetime,
      "Date" => :date,
    }.freeze

    # `skip_unsupported`: when true, the generator does not abort on a construct
    # it cannot represent. It skips an unresolvable `belongs_to` (keeping the
    # foreign-key field) and emits an unrepresentable embedded collection as an
    # `ignore: true` top-level config annotated with a `comment`, warning to
    # stderr in both cases. Off by default, so the historical fail-loud behavior
    # is unchanged unless a caller opts in.
    #
    # `safe_new_columns` mirrors `SchemaGenerator`; see #initialize.
    def self.from_rails_application(output_dir:, skip_unsupported: false, safe_new_columns: true)
      Rails.application.eager_load!
      new(
        models: ::Mongoid.models,
        output_dir: output_dir,
        skip_unsupported: skip_unsupported,
        safe_new_columns: safe_new_columns,
      )
    end

    # `safe_new_columns` (the default) emits every field masked — as far as its
    # Mongoid type allows, see MASKABLE_FIELD_TYPES and DefaultMask — and flagged
    # `needs_mask_decision: true`. MongodbCollectionConfig#merge lets an existing
    # entry win, so in practice only fields a model change has just added keep
    # that treatment. Pass false to bootstrap a config, where every field is new
    # and flagging all of them at once is noise.
    def initialize(models:, output_dir:, skip_unsupported: false, safe_new_columns: true)
      @models = models
      @output_dir = output_dir
      @skip_unsupported = skip_unsupported
      @safe_new_columns = safe_new_columns
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
      models_by_collection_name.map do |collection_name, group|
        build_collection_for(collection_name, group, existing_by_name[collection_name])
      end
    end

    # Reconcile the config files already on disk against the models, deleting the
    # config of a collection no model stores into any more. This is the
    # counterpart of `generate!`, which adds and updates config files but can
    # never delete one: a collection whose model was removed leaves a config that
    # would otherwise be dumped forever.
    #
    # Fields are deliberately NOT touched: `generate!`'s #merge already drives the
    # field list from the model, so a field the model lost is dropped there.
    #
    # Unlike `SchemaGenerator#tidy!`, the source of truth is the model set, not a
    # live connection. MongoDB has no schema to read: a collection exists only
    # once a document is written to it, so "still in the database" is not a
    # question that can be answered before a dump, and introspection here is
    # class-level (see this class's preamble) and needs no connection at all. The
    # name set therefore comes from exactly the grouping `generate!` writes files
    # from (`models_by_collection_name`, descendants expanded and embedded models
    # included), so the two can never disagree about which files are live.
    #
    # A config declaring `embedded_in` is never deleted, whatever its name — see
    # #hand_written_embedded_config?.
    #
    # Returns a `SchemaGenerator::TidyResult` — reused rather than duplicated,
    # since a removal report is the same shape whatever the ORM — describing the
    # removals so callers (e.g. the rake task) can report them. Its
    # `removed_columns` stays empty, for the reason above.
    def tidy!
      result = SchemaGenerator::TidyResult.new
      return result unless @output_dir && File.directory?(@output_dir)

      live_names = models_by_collection_name.keys

      Dir[File.join(@output_dir, "*.json")].sort.each do |path|
        config = read_raw_config(path)
        name = declared_name(config, path)
        next if live_names.include?(name)
        next if hand_written_embedded_config?(config)

        File.delete(path)
        result.add_removed_table(name)
      end

      result
    end

    # Whether a config on disk describes an embedded collection this generator
    # could not have written, and whose liveness it therefore cannot judge.
    #
    # `generate!` writes one config per *collection name*, so when two embedded
    # classes share a collection name — which they routinely do, since an embedded
    # class's collection name is derived from the class name alone (`Address`
    # embedded under two different parents is `addresses` both times) — only one
    # of them is emitted. The other can only be expressed by hand, under a name
    # that says where it lives (`orders_deliveries_addresses`) rather than naming
    # a collection. Such a name matches no model by construction, so "no model
    # stores into it" is not evidence that it is dead: it is evidence that the
    # config exists precisely because generation cannot reach it.
    #
    # Deleting one is silent and expensive — an embedded config carries the
    # masking rules applied to those subdocuments, so removing it exports them
    # raw, and nothing else in the pipeline notices. So an `embedded_in` config
    # is kept whatever its name; a genuinely dead one is removed by hand, which is
    # also how it arrived.
    private def hand_written_embedded_config?(config)
      config.is_a?(Hash) && !config["embedded_in"].nil?
    end

    # The collection -> models grouping both `build_collections` and `tidy!` work
    # from: every model that stores into a collection, keyed by that collection's
    # name. Models are grouped by `collection_name` so an STI hierarchy collapses
    # into one entry (see `build_collections`), and `expand_with_descendants`
    # supplies the subclasses Mongoid does not register.
    #
    # Shared so the two operations can never disagree about which collections
    # exist: `tidy!` deletes exactly the config files `generate!` would not write.
    private def models_by_collection_name
      expand_with_descendants(concrete_models).group_by { |model| model.collection_name.to_s }
    end

    # A config file on disk as plain JSON, rather than through
    # `MongodbCollectionConfig.from` on purpose: a stale file is exactly the one
    # that may no longer satisfy the current validations (an unknown key, a
    # belongs_to whose target is gone), and tidy has to be able to delete such a
    # file rather than abort on it. Unparseable JSON reads as no config at all.
    private def read_raw_config(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    # The collection a config declares itself to be. Without a readable `name` it
    # falls back to the file's basename, which is the name `write_files` gives it.
    private def declared_name(config, path)
      (config.is_a?(Hash) && config["name"]) || File.basename(path, ".json")
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
        primary_key: PRIMARY_KEY,
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
      structural = structural_field_names(models)
      unique = unique_field_names(models)

      seen = {}
      models.each_with_object([]) do |model, fields|
        accessor_by_storage = aliased_field_accessors(model)
        model.fields.each do |name, definition|
          next if seen[name]

          seen[name] = true
          field = { name: name }
          # When `field :ctry, as: :country` renamed the storage key, surface the
          # Ruby accessor so the short key is not cryptic in the config.
          accessor = accessor_by_storage[name]
          field[:mongoid_field_name] = accessor if accessor
          fields << field.merge(safe_mode_attributes(name, definition, structural, unique))
        end
      end
    end

    # The safe-mode additions to a field entry: the `needs_mask_decision` flag,
    # plus a default `replace_with` where a safe one exists. Empty when safe mode
    # is off, so the emitted config is byte-identical to the historical output.
    #
    # A structural field is flagged but never masked: masking it would break the
    # very lookups the dump is assembled from (see #structural_field_names).
    private def safe_mode_attributes(name, definition, structural, unique)
      return {} unless @safe_new_columns

      attrs = { needs_mask_decision: true }
      return attrs if structural.include?(name)

      mask = default_mask_for(name, definition, unique.include?(name))
      mask.nil? ? attrs : attrs.merge(replace_with: mask)
    end

    # The default mask for one field, or nil when no safe constant fits its
    # Mongoid type (see MASKABLE_FIELD_TYPES).
    #
    # `limit: nil` because MongoDB stores no per-field length: the length checks
    # DefaultMask applies to a `varchar(n)` have nothing to read here, and any
    # string the mask renders is storable. `unique` comes from the model's index
    # declarations, so a constant is never emitted for a field a unique index
    # would then collide on across every restored document.
    #
    # NOTE the mask a date/time field gets is DefaultMask's fixed *string*
    # constant, which replaces a BSON Date with a String and so changes the
    # field's BSON type. That is deliberate at this stage: the value is only a
    # proposal, and it rides on `needs_mask_decision` precisely so a human either
    # keeps it knowingly, replaces it, or drops it before the config is merged.
    private def default_mask_for(name, definition, unique)
      type = MASKABLE_FIELD_TYPES[mongoid_type_name(definition)]
      return nil if type.nil?

      DefaultMask.for(
        name: name,
        type: type,
        limit: nil,
        primary_key: PRIMARY_KEY,
        unique: unique,
        column_default: field_default(definition),
      )
    end

    # `Model.fields[name].type` is a Ruby class; an anonymous one (or a field
    # object that does not expose a type at all) has no name to look up, which
    # MASKABLE_FIELD_TYPES answers with "no default mask".
    private def mongoid_type_name(definition)
      type = definition.type if definition.respond_to?(:type)
      type.name if type.is_a?(Module)
    end

    # The field's declared `default:`, handed to DefaultMask so a field with a
    # default of its own is masked with that value rather than the per-type
    # constant (see DefaultMask.constant_mask). Mongoid also accepts a *lambda*
    # default (`default: -> { Time.now }`), which is not a constant at all;
    # DefaultMask's scalar_default answers such a value with nil, so it falls
    # through to the per-type constant on its own.
    private def field_default(definition)
      definition.default_val if definition.respond_to?(:default_val)
    end

    # The fields safe mode flags but must never mask, because the dump is
    # assembled by looking documents up through them:
    #
    # - the primary key `_id`, which every belongs_to and every `--ids` filter
    #   resolves against (and which the text masks interpolate to stay unique),
    # - the STI discriminator (`Model.discriminator_key`, `_type` by default),
    #   which is what tells one class's documents from another's inside the
    #   shared collection, and
    # - every `belongs_to` foreign key declared by any model of this collection.
    #
    # The foreign keys are taken from the MODELS, not from the emitted
    # `belongs_tos`, so the ones the generator deliberately drops are covered
    # too: a polymorphic belongs_to (excluded because it has no single target
    # collection) and a referenced belongs_to on an embedded document (excluded
    # because an embedded config carries none) still store a reference some other
    # collection's documents are found by, and masking it would silently rewrite
    # that reference. A polymorphic relation's type field (`reviewable_type`)
    # is exempt for the same reason, mirroring how the ActiveRecord generator
    # treats a belongs_to's `foreign_type`.
    private def structural_field_names(models)
      names = [PRIMARY_KEY]

      models.each do |model|
        names << model.discriminator_key.to_s if model.respond_to?(:discriminator_key)
        model.relations.each_value do |assoc|
          next unless assoc.is_a?(::Mongoid::Association::Referenced::BelongsTo)

          names << assoc.foreign_key.to_s
          names << assoc.inverse_type.to_s if assoc.polymorphic? && assoc.inverse_type
        end
      end

      names.uniq
    end

    # The fields covered by a unique index declared on any model of this
    # collection (`index({ email: 1 }, unique: true)`), so DefaultMask withholds
    # any mask that does not vary per document — a constant would collapse every
    # document onto one value and break the restore with a duplicate key. Every
    # field of a compound unique index counts, mirroring the ActiveRecord
    # generator's "any column of a unique index".
    #
    # Index declarations are class-level Mongoid metadata (they are what
    # `db/mongoid.rake`'s create_indexes would build), so this needs no
    # connection — unlike the ActiveRecord generator, which reads the live
    # database and has to cope with that failing. An index created out of band
    # and never declared on the model is therefore invisible here; declaring it
    # is what makes exwiw (and Mongoid itself) aware of it.
    private def unique_field_names(models)
      models.flat_map do |model|
        next [] unless model.respond_to?(:index_specifications)

        model.index_specifications
             .select { |spec| spec.options[:unique] }
             .flat_map { |spec| spec.key.keys.map(&:to_s) }
      end.uniq
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
      ignored = ignored_belongs_tos(existing)

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
        .filter_map { |assoc| belongs_to_for(assoc, ignored) }
        .uniq
    end

    # The on-disk `ignore: true` belongs_to entries, so a relation the user has
    # explicitly ignored is preserved verbatim instead of re-resolved (which, for
    # a stale relation whose target class is gone, would otherwise abort the run).
    #
    # Kept as a list rather than indexed by foreign key: a foreign key does not
    # identify a relation on its own (see #ignored_belongs_to_for).
    private def ignored_belongs_tos(existing)
      return [] unless existing

      existing.belongs_tos.select(&:ignore)
    end

    # The on-disk ignored entry that stands for `assoc`, or nil when none does.
    #
    # `target_collection` is the association's resolved target, or nil when it
    # could not be resolved, and that distinction is what the match is keyed on:
    #
    # - Resolved: the entry has to agree on BOTH the target collection and the
    #   foreign key. Two belongs_tos of one collection can legitimately share a
    #   foreign key — a relation to one collection plus a second relation to
    #   another declared with `primary_key:`, scoping by the same stored value —
    #   and matching on the foreign key alone let one ignored entry stand for both
    #   of them. The second relation was then re-emitted as a copy of that entry,
    #   `uniq` collapsed the two, and its edge silently vanished from the config.
    #   An entry naming a different target must therefore not swallow this
    #   relation; with none matching, the relation is generated normally.
    # - Unresolved: there is no target to compare, which is precisely the case
    #   this mechanism exists for (a stale relation whose class is gone, whose
    #   entry usually carries no `table_name` either), so fall back to matching on
    #   the foreign key alone.
    #
    # An entry with no `table_name` still matches a resolved relation on the
    # foreign key alone, as a fallback after the exact match: omitting the target
    # is allowed only on an ignored entry, and dropping the user's decision
    # because they wrote the minimal form would resurrect an edge they had
    # deliberately cut. Two foreign-key-sharing relations with one such entry
    # between them remain genuinely indistinguishable — writing the `table_name`
    # is what tells exwiw which of them is meant.
    private def ignored_belongs_to_for(assoc, target_collection, ignored)
      foreign_key = assoc.foreign_key
      return ignored.find { |bt| bt.foreign_key == foreign_key } if target_collection.nil?

      ignored.find { |bt| bt.foreign_key == foreign_key && bt.table_name == target_collection } ||
        ignored.find { |bt| bt.foreign_key == foreign_key && bt.table_name.nil? }
    end

    # The collection a referenced belongs_to targets, as `[collection_name, nil]`
    # — or `[nil, error]` when the association's target class no longer exists (a
    # stale/legacy `belongs_to`, e.g. pointing at a model removed years ago), so
    # `assoc.klass` raised. The error is carried rather than raised because
    # resolution is attempted BEFORE the on-disk ignored entries are consulted (to
    # match one against the right relation), and a relation the user has already
    # triaged must not abort the run; `belongs_to_for` raises it only once no
    # entry stands for the relation.
    private def resolve_target_collection(assoc)
      [assoc.klass.collection_name.to_s, nil]
    rescue NameError, ::Mongoid::Errors::MongoidError => e
      [nil, e]
    end

    # Resolves a referenced belongs_to to a `{ table_name, foreign_key }` pair
    # (plus `references` when the FK points at a non-`_id` parent field).
    # `assoc.klass` raises NameError when the association's target class no longer
    # exists (a stale/legacy `belongs_to`, e.g. pointing at a model removed years
    # ago). Under `skip_unsupported` such a relation is skipped with a warning —
    # its foreign-key column is still tracked as an ordinary field by
    # `aggregate_fields`, mirroring how polymorphic / HABTM relations are dropped.
    #
    # `ignored` carries the on-disk `ignore: true` belongs_to entries: when one of
    # them stands for this relation (see #ignored_belongs_to_for), the user has
    # explicitly ignored it, so preserve their entry verbatim (its `ignore_type` /
    # `comment`) rather than emitting a freshly derived one. The relation is
    # dropped from extraction at load (`#reject_ignored_members!`) while its FK
    # column stays a field, and the run never aborts on a relation already
    # triaged: resolving the — possibly gone — target is attempted first, but its
    # failure is only raised once no entry stands for the relation.
    private def belongs_to_for(assoc, ignored = [])
      target_collection, resolution_error = resolve_target_collection(assoc)

      if (entry = ignored_belongs_to_for(assoc, target_collection, ignored))
        return preserve_ignored_belongs_to(entry)
      end

      if resolution_error
        raise resolution_error unless @skip_unsupported

        warn("exwiw: skip_unsupported: skipping belongs_to ':#{assoc.name}' that could not be resolved (#{resolution_error.class}: #{resolution_error.message.lines.first&.strip}); its foreign key '#{assoc.foreign_key}' is still kept as a field.")
        return nil
      end

      result = { table_name: target_collection, foreign_key: assoc.foreign_key }
      # Mongoid's `belongs_to ..., primary_key: :uuid` makes the child's foreign
      # key reference that parent field rather than the parent's `_id`. Surface
      # it as `references` so MongodbAdapter constrains children by the right
      # field (issue B1). Omit it for the default `_id` (the parent primary_key
      # the generator emits) so existing configs/snapshots are unchanged. SQL
      # adapters ignore `references`; only MongodbAdapter consumes it.
      reference_field = assoc.primary_key.to_s
      result[:references] = reference_field unless reference_field == "_id"
      result
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

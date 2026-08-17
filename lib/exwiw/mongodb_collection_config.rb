# frozen_string_literal: true

module Exwiw
  class MongodbCollectionConfig
    include Serdes

    # MongoDB-native names. Intentionally re-declared instead of inheriting
    # from TableConfig — Serdes does not propagate attribute declarations
    # across class boundaries.
    attribute :name, String
    attribute :primary_key, String
    attribute :filter, optional(String), skip_serializing_if_nil: true
    attribute :belongs_tos, array(BelongsTo)
    attribute :fields, array(MongodbField)
    attribute :bulk_insert_chunk_size, optional(Integer), skip_serializing_if_nil: true
    # Per-collection server-enforced query timeout in milliseconds (CSOT). Applied
    # to this collection's find (whole cursor lifetime), count, and an executing
    # explain; overrides the global ConnectionConfig#mongodb_query_timeout_ms. Use
    # it to give a known-large collection more headroom than the global default
    # (or, conversely, to cap one that tends to run away). User-maintained — the
    # generator never emits it, so #merge carries it forward across regeneration.
    attribute :query_timeout_ms, optional(Integer), skip_serializing_if_nil: true
    attribute :ignore, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true
    # Free-form note. Purely informational — exwiw never reads it — and preserved
    # across `MongoidSchemaGenerator` regeneration like the field / belongs_to
    # `comment`. The generator also emits one when, under `skip_unsupported`, it
    # marks an unrepresentable collection `ignore: true`, to record why extraction
    # was skipped.
    attribute :comment, optional(String), skip_serializing_if_nil: true
    # Free-form tag recording *why* this collection is ignored (e.g.
    # "need_code_fix" for an application-side bug, "unsupported" for a shape
    # exwiw cannot express). exwiw never interprets or emits it; informational
    # and preserved across regeneration like `comment`.
    attribute :ignore_type, optional(String), skip_serializing_if_nil: true

    # Marks this config as physically embedded inside another collection's
    # documents. When set, this config is not processed as a standalone dump
    # unit; its masking rules are applied to the parent's subdocuments at
    # `path`.
    attribute :embedded_in, optional(EmbeddedIn), skip_serializing_if_nil: true

    # `reverse_scope` opts a collection into multi-referencer reverse scoping,
    # mirroring the SQL TableConfig key (see Exwiw::ReverseScope): a
    # global-identity collection referenced by many scoped collections is
    # constrained to the union of the ids those referencers actually point at,
    # instead of being dumped in full. Unlike the SQL adapters (which emit a
    # UNION subquery), the mongodb adapter captures each `via` arm's column
    # values at runtime while the referencer collection streams, so the
    # reverse-scoped collection must be processed AFTER its referencers — see
    # DetermineTableProcessingOrder (runtime_reverse_scope) and
    # MongodbAdapter#reverse_scope_filter. User-configured and never emitted by
    # MongoidSchemaGenerator; preserved across regeneration (see #merge).
    attribute :reverse_scope, Serdes::OptionalType.new(ReverseScope), skip_serializing_if_nil: true

    def self.from(obj)
      # Reject unknown keys before deserializing: Serdes silently drops them,
      # which would turn a typo'd key — or a key only the SQL adapters support,
      # like a field-level `raw_sql` — into a silent no-op (see
      # Exwiw::StrictKeys). `comment` is a declared attribute here and on the
      # nested belongs_to/field entries, so free-form notes stay accepted.
      if obj.is_a?(Hash)
        collection_name = obj["name"] || obj[:name]
        StrictKeys.validate!(self, obj, owner: "collection '#{collection_name}'")
      end

      instance = super
      instance.__send__(:validate_embedded!)
      instance.__send__(:validate_belongs_tos!)
      instance.__send__(:validate_fake_data!)
      instance
    end

    def self.from_symbol_keys(hash)
      from(JSON.parse(hash.to_json))
    end

    def embedded?
      !embedded_in.nil?
    end

    # The names of the fields flagged `ignore:true`, kept answerable after
    # #reject_ignored_members! has dropped the entries: an embedded config's
    # subdocuments arrive inside the parent's document, so masking is the only
    # place they can be removed (see MongodbAdapter#build_mask_plan).
    def ignored_field_names
      @ignored_field_names ||= fields.select(&:ignore).map(&:name)
    end

    # Drop the belongs_tos/fields flagged `ignore:true` so they are excluded from
    # extraction. The config files on disk keep these entries; this is applied to
    # the runtime config right after it is loaded (see Runner#load_table_config).
    def reject_ignored_members!
      self.belongs_tos = belongs_tos.reject(&:ignore)
      ignored, kept = fields.partition(&:ignore)
      @ignored_field_names = ignored.map(&:name)
      self.fields = kept
      self
    end

    # Merge an auto-generated config (`passed`) into this user-maintained one so
    # that `MongoidSchemaGenerator` regenerations preserve hand-edited values.
    #
    # - structural facts come from the freshly generated config: primary_key,
    #   belongs_tos, embedded_in.
    # - user customizations are kept from the receiver: filter, ignore,
    #   bulk_insert_chunk_size, query_timeout_ms, and each field's
    #   `replace_with` / `replace_with_fake_data` masking rule.
    # - generated fields drive the field list (so added/removed fields track the
    #   model), but for a field the receiver already has, its masking decision
    #   wins outright — including the parts of it left unset.
    def merge(passed)
      return passed if passed.to_hash == to_hash

      MongodbCollectionConfig.new.tap do |merged|
        merged.name = name
        merged.primary_key = passed.primary_key
        merged.filter = filter
        merged.bulk_insert_chunk_size = bulk_insert_chunk_size
        merged.query_timeout_ms = query_timeout_ms
        merged.ignore = ignore
        merged.ignore_type = ignore_type
        # A freshly generated comment (e.g. the skip_unsupported marker) wins so
        # it stays accurate; otherwise a hand-added note on a normal collection
        # is kept.
        merged.comment = passed.comment || comment
        merged.embedded_in = passed.embedded_in
        # User-owned, never regenerated: carry over from the existing config.
        merged.reverse_scope = reverse_scope

        # Structural facts of each belongs_to come from the freshly generated
        # config (including a generator-derived `references`), but the user-owned
        # `comment`/`ignore` — and a hand-edited `references`, which overrides the
        # generated one — carry over when the same relation still exists.
        receiver_belongs_to_by_identity = belongs_tos.each_with_object({}) { |bt, h| h[bt.identity] = bt }
        merged.belongs_tos = passed.belongs_tos.map do |pbt|
          receiver_bt = receiver_belongs_to_by_identity[pbt.identity]
          if receiver_bt
            pbt.comment = receiver_bt.comment if receiver_bt.comment
            pbt.ignore = receiver_bt.ignore unless receiver_bt.ignore.nil?
            pbt.ignore_type = receiver_bt.ignore_type if receiver_bt.ignore_type
            pbt.references = receiver_bt.references if receiver_bt.references
          end
          pbt
        end

        # Take each field from the freshly generated config (so structural facts
        # like `mongoid_field_name` track the model), but once the field already
        # exists in the receiver, EVERY masking-decision attribute comes from the
        # receiver — even when it is unset.
        #
        # "Even when unset" is the whole point: what these attributes record is a
        # human's decision about the field, and an absent value is a decision too
        # ("export this raw", "the flag is resolved"). Keeping the generated value
        # where the receiver has none was equivalent to "receiver wins" only while
        # the generator emitted no masks at all; under safe mode
        # (MongoidSchemaGenerator's `safe_new_columns`) it would put a default mask
        # back on a field somebody had deliberately unmasked, and silently mask it
        # again on every regeneration.
        receiver_field_by_name = fields.each_with_object({}) { |f, h| h[f.name] = f }
        merged.fields = passed.fields.map do |pf|
          receiver = receiver_field_by_name[pf.name]
          next pf unless receiver

          pf.replace_with = receiver.replace_with
          pf.replace_with_fake_data = receiver.replace_with_fake_data
          pf.comment = receiver.comment
          pf.ignore = receiver.ignore
          pf.needs_mask_decision = receiver.needs_mask_decision
          pf
        end
      end
    end

    # Ruby-side masking validation, mirroring TableConfig#validate_ruby_side_masking!
    # for the SQL adapters: `replace_with_fake_data` is exclusive with
    # `replace_with` on the same field, the type must be supported, and the seed
    # must name a field of this collection (bare or `name.`-qualified) or its
    # primary key. Deliberately static (no faker require, no pool build) so
    # schema regeneration never triggers value generation; the seed is resolved
    # again against the effective (post-ignore) fields at dump time in
    # MongodbAdapter#build_mask_plan.
    private def validate_fake_data!
      fields.each do |field|
        fake_data = field.replace_with_fake_data
        next unless fake_data

        unless field.replace_with.nil?
          raise ArgumentError,
                "MongodbCollectionConfig '#{name}' field '#{field.name}': replace_with and " \
                "replace_with_fake_data cannot be combined; use only one."
        end

        supported_types = RowTransformer::PERSON_TYPES.keys + RowTransformer::FAKE_TYPES.keys
        unless supported_types.include?(fake_data.type)
          raise ArgumentError,
                "MongodbCollectionConfig '#{name}' field '#{field.name}': unknown " \
                "replace_with_fake_data type '#{fake_data.type}' (supported: #{supported_types.join(', ')})."
        end

        seed_field = fake_data.seed.delete_prefix("#{name}.")
        if seed_field.include?(".") || (seed_field != primary_key && fields.none? { |f| f.name == seed_field })
          raise ArgumentError,
                "MongodbCollectionConfig '#{name}' field '#{field.name}': replace_with_fake_data " \
                "seed '#{fake_data.seed}' does not name a field of this collection " \
                "(use 'field' or '#{name}.field')."
        end
      end
    end

    private def validate_embedded!
      return unless embedded?

      if reverse_scope
        raise ArgumentError,
              "MongodbCollectionConfig '#{name}' is embedded_in '#{embedded_in.collection_name}'; " \
              "reverse_scope must not be defined (an embedded config is never dumped on its own)."
      end
      return if belongs_tos.empty?

      raise ArgumentError,
            "MongodbCollectionConfig '#{name}' is embedded_in '#{embedded_in.collection_name}'; " \
            "belongs_tos must be empty (cross-collection refs from inside embedded arrays " \
            "are not supported)."
    end

    # `table_name` is optional only so an *ignored* relation (a stale belongs_to
    # whose target collection no longer exists) can be recorded without one. A
    # belongs_to that still participates in extraction must name its target.
    private def validate_belongs_tos!
      offender = belongs_tos.find { |bt| bt.table_name.nil? && !bt.ignore }
      return unless offender

      raise ArgumentError,
            "MongodbCollectionConfig '#{name}' has a belongs_to (foreign_key " \
            "'#{offender.foreign_key}') with no table_name; only an `ignore: true` belongs_to " \
            "may omit it."
    end
  end
end

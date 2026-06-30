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

    def self.from(obj)
      instance = super
      instance.__send__(:validate_embedded!)
      instance.__send__(:validate_belongs_tos!)
      instance
    end

    def self.from_symbol_keys(hash)
      from(JSON.parse(hash.to_json))
    end

    def embedded?
      !embedded_in.nil?
    end

    # Drop the belongs_tos/fields flagged `ignore:true` so they are excluded from
    # extraction. The config files on disk keep these entries; this is applied to
    # the runtime config right after it is loaded (see Runner#load_table_config).
    def reject_ignored_members!
      self.belongs_tos = belongs_tos.reject(&:ignore)
      self.fields = fields.reject(&:ignore)
      self
    end

    # Merge an auto-generated config (`passed`) into this user-maintained one so
    # that `MongoidSchemaGenerator` regenerations preserve hand-edited values.
    #
    # - structural facts come from the freshly generated config: primary_key,
    #   belongs_tos, embedded_in.
    # - user customizations are kept from the receiver: filter, ignore,
    #   bulk_insert_chunk_size, query_timeout_ms, and each field's `replace_with`
    #   masking rule.
    # - generated fields drive the field list (so added/removed fields track the
    #   model), but a matching receiver field wins to retain its masking.
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
        # like `mongoid_field_name` track the model) but carry over the user's
        # hand-edited `replace_with`/`comment`/`ignore` when the field still exists.
        receiver_field_by_name = fields.each_with_object({}) { |f, h| h[f.name] = f }
        merged.fields = passed.fields.map do |pf|
          receiver = receiver_field_by_name[pf.name]
          if receiver
            pf.replace_with = receiver.replace_with if receiver.replace_with
            pf.comment = receiver.comment if receiver.comment
            pf.ignore = receiver.ignore unless receiver.ignore.nil?
          end
          pf
        end
      end
    end

    private def validate_embedded!
      return unless embedded?
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

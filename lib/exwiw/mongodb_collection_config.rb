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
    attribute :skip, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true

    # Marks this config as physically embedded inside another collection's
    # documents. When set, this config is not processed as a standalone dump
    # unit; its masking rules are applied to the parent's subdocuments at
    # `path`.
    attribute :embedded_in, optional(EmbeddedIn), skip_serializing_if_nil: true

    def self.from(obj)
      instance = super
      instance.__send__(:validate_embedded!)
      instance
    end

    def self.from_symbol_keys(hash)
      from(JSON.parse(hash.to_json))
    end

    def embedded?
      !embedded_in.nil?
    end

    # Merge an auto-generated config (`passed`) into this user-maintained one so
    # that `MongoidSchemaGenerator` regenerations preserve hand-edited values.
    #
    # - structural facts come from the freshly generated config: primary_key,
    #   belongs_tos, embedded_in.
    # - user customizations are kept from the receiver: filter, skip,
    #   bulk_insert_chunk_size, and each field's `replace_with` masking rule.
    # - generated fields drive the field list (so added/removed fields track the
    #   model), but a matching receiver field wins to retain its masking.
    def merge(passed)
      return passed if passed.to_hash == to_hash

      MongodbCollectionConfig.new.tap do |merged|
        merged.name = name
        merged.primary_key = passed.primary_key
        merged.filter = filter
        merged.belongs_tos = passed.belongs_tos
        merged.bulk_insert_chunk_size = bulk_insert_chunk_size
        merged.skip = skip
        merged.embedded_in = passed.embedded_in

        # Take each field from the freshly generated config (so structural facts
        # like `mongoid_field_name` track the model) but carry over the user's
        # hand-edited `replace_with` masking when the field still exists.
        receiver_field_by_name = fields.each_with_object({}) { |f, h| h[f.name] = f }
        merged.fields = passed.fields.map do |pf|
          receiver = receiver_field_by_name[pf.name]
          pf.replace_with = receiver.replace_with if receiver&.replace_with
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
  end
end

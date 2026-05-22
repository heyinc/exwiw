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

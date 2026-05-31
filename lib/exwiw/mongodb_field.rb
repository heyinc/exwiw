# frozen_string_literal: true

module Exwiw
  class MongodbField
    include Serdes

    attribute :name, String
    attribute :replace_with, optional(String), skip_serializing_if_nil: true
    # The Mongoid model's Ruby accessor when the stored document key (`name`)
    # was renamed via `field :ctry, as: :country`. Purely informational — exwiw
    # masks/projects by `name` (the storage key) — but surfacing the accessor
    # keeps an otherwise cryptic short key understandable in the config.
    attribute :mongoid_field_name, optional(String), skip_serializing_if_nil: true
    # User-owned fields preserved across schema regeneration (see
    # MongodbCollectionConfig#merge). `ignore:true` drops the field from extraction
    # once the config is loaded (see MongodbCollectionConfig#reject_ignored_members!).
    attribute :comment, optional(String), skip_serializing_if_nil: true
    attribute :ignore, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true

    def self.from_symbol_keys(hash)
      from(hash.transform_keys(&:to_s))
    end

    def to_hash
      super.compact
    end
  end
end

# frozen_string_literal: true

module Exwiw
  class MongodbField
    include Serdes

    attribute :name, String
    attribute :replace_with, Serdes::OptionalType.new(MaskValue.new), skip_serializing_if_nil: true
    # Ruby-process-side masking: replace the value with a deterministic fake
    # value derived from a seed field (see FakeData / RowTransformer). Unlike the
    # SQL adapters — where replace_with runs in the database and fake data needs
    # a separate streaming transform — the MongoDB adapter already masks
    # document-side, so this is applied inside the collection's mask plan
    # (MongodbAdapter#apply_mask_plan!), after `replace_with`.
    attribute :replace_with_fake_data, Serdes::OptionalType.new(FakeData), skip_serializing_if_nil: true
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

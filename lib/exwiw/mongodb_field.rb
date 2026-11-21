# frozen_string_literal: true

module Exwiw
  class MongodbField
    include Serdes

    attribute :name, String, merge: :identity
    # See TableColumn: the masking modes form one exclusive group for overlays.
    attribute :replace_with, Serdes::OptionalType.new(MaskValue.new), skip_serializing_if_nil: true,
                             merge: { exclusive: :mask }
    # Ruby-process-side masking: replace the value with a deterministic fake
    # value derived from a seed field (see FakeData / RowTransformer). Unlike the
    # SQL adapters — where replace_with runs in the database and fake data needs
    # a separate streaming transform — the MongoDB adapter already masks
    # document-side, so this is applied inside the collection's mask plan
    # (MongodbAdapter#apply_mask_plan!), after `replace_with`.
    attribute :replace_with_fake_data, Serdes::OptionalType.new(FakeData), skip_serializing_if_nil: true,
                                       merge: { exclusive: :mask }
    # SQL: NULL. MongoDB: the key is removed (`$unset`).
    attribute :unset, Serdes::OptionalType.new(TrueFlag.new), skip_serializing_if_nil: true, merge: { exclusive: :mask }
    attribute :replace_with_random, Serdes::OptionalType.new(RandomMask.new), skip_serializing_if_nil: true,
                                    merge: { exclusive: :mask }
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
    # Exempts this credential-looking field masked to a guessable value from the guessable_credentials check (see
    # MaskRules.unaccepted_credentials).
    attribute :allow_guessable_credential, Serdes::OptionalType.new(TrueFlag.new), skip_serializing_if_nil: true
    # Declares that this field is exported unmasked on purpose, though its name looks sensitive (see
    # MaskRules.unmasked_sensitive). Part of the mask group, so an overlay can un-mask a field or mask it again.
    attribute :allow_unmasked, Serdes::OptionalType.new(TrueFlag.new), skip_serializing_if_nil: true,
                               merge: { exclusive: :mask }
    # See TableColumn#needs_mask_decision.
    attribute :needs_mask_decision,
              Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)),
              skip_serializing_if_nil: true

    def self.from_symbol_keys(hash)
      from(hash.transform_keys(&:to_s))
    end

    def to_hash
      super.compact
    end

    # @return [Boolean] whether a mask is declared
    def mask_declared?
      !replace_with.nil? || !replace_with_fake_data.nil? || !replace_with_random.nil? || unset == true
    end

    # @return [Boolean] whether the mask leaves nothing to guess
    def safe_for_credential?
      !replace_with_random.nil? || unset == true
    end
  end
end

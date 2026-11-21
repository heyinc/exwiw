# frozen_string_literal: true

module Exwiw
  class TableColumn
    include Serdes

    attribute :name, String, merge: :identity
    # The masking modes form one exclusive group for overlays: raw_sql silently
    # wins over replace_with, so an overlay setting one must drop the others.
    attribute :replace_with, Serdes::OptionalType.new(MaskValue.new), skip_serializing_if_nil: true,
                             merge: { exclusive: :mask }
    attribute :raw_sql, optional(String), skip_serializing_if_nil: true, merge: { exclusive: :mask }
    # Ruby-process-side masking modes, applied to the fetched rows by
    # RowTransformer (SQL adapters only) — unlike replace_with/raw_sql, which
    # compile into the SELECT and run in the database.
    attribute :map, optional(String), skip_serializing_if_nil: true, merge: { exclusive: :mask }
    attribute :replace_with_fake_data, Serdes::OptionalType.new(FakeData), skip_serializing_if_nil: true,
                                       merge: { exclusive: :mask }
    # SQL: NULL. MongoDB: the key is removed (`$unset`).
    attribute :unset, Serdes::OptionalType.new(TrueFlag.new), skip_serializing_if_nil: true, merge: { exclusive: :mask }
    attribute :replace_with_random, Serdes::OptionalType.new(RandomMask.new), skip_serializing_if_nil: true,
                                    merge: { exclusive: :mask }
    # User-owned fields preserved across schema regeneration (see
    # TableConfig#merge). `ignore:true` drops the column from extraction (SELECT /
    # INSERT) once the config is loaded (see TableConfig#reject_ignored_members!).
    attribute :comment, optional(String), skip_serializing_if_nil: true
    attribute :ignore, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true
    # Exempts this credential-looking column masked to a guessable value from the guessable_credentials check (see
    # MaskRules.unaccepted_credentials).
    attribute :allow_guessable_credential, Serdes::OptionalType.new(TrueFlag.new), skip_serializing_if_nil: true
    # Declares that this column is exported unmasked on purpose, though its name looks sensitive (see
    # MaskRules.unmasked_sensitive). Part of the mask group, so an overlay can un-mask a column or mask it again.
    attribute :allow_unmasked, Serdes::OptionalType.new(TrueFlag.new), skip_serializing_if_nil: true,
                               merge: { exclusive: :mask }
    # Marks a column whose masking nobody has decided on yet. Extraction never
    # reads it; `schema:generate` emits it and `schema:check` reports it, so CI
    # can require the decision.
    attribute :needs_mask_decision,
              Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)),
              skip_serializing_if_nil: true

    def self.from_symbol_keys(hash)
      from(hash.transform_keys(&:to_s))
    end

    def to_hash
      super.compact # drop unusing option
    end

    # @return [Boolean] whether a mask is declared
    def mask_declared?
      !!(raw_sql || !replace_with.nil? || map || replace_with_fake_data || replace_with_random || unset)
    end

    # @return [Boolean] whether the mask leaves nothing to guess
    def safe_for_credential?
      !!(unset || replace_with_random)
    end
  end
end

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
    # User-owned fields preserved across schema regeneration (see
    # TableConfig#merge). `ignore:true` drops the column from extraction (SELECT /
    # INSERT) once the config is loaded (see TableConfig#reject_ignored_members!).
    attribute :comment, optional(String), skip_serializing_if_nil: true
    attribute :ignore, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true
    # `mask-update` only: accepts a mask other than NULL or a random raw_sql on a credential-looking column (see
    # MaskUpdateRunner.check_credential_columns!).
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
  end
end

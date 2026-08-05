# frozen_string_literal: true

module Exwiw
  class TableColumn
    include Serdes

    attribute :name, String
    attribute :replace_with, Serdes::OptionalType.new(MaskValue.new), skip_serializing_if_nil: true
    attribute :raw_sql, optional(String), skip_serializing_if_nil: true
    # Ruby-process-side masking modes, applied to the fetched rows by
    # RowTransformer (SQL adapters only) — unlike replace_with/raw_sql, which
    # compile into the SELECT and run in the database.
    attribute :map, optional(String), skip_serializing_if_nil: true
    attribute :replace_with_fake_data, Serdes::OptionalType.new(FakeData), skip_serializing_if_nil: true
    # User-owned fields preserved across schema regeneration (see
    # TableConfig#merge). `ignore:true` drops the column from extraction (SELECT /
    # INSERT) once the config is loaded (see TableConfig#reject_ignored_members!).
    attribute :comment, optional(String), skip_serializing_if_nil: true
    attribute :ignore, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true
    # Marks a column whose masking has not been decided by a human yet: emitted
    # by `schema:generate` in safe mode together with a default mask, and
    # reported by `schema:check` so CI can require the decision. Extraction never
    # reads it — the masking is whatever `replace_with` says.
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

# frozen_string_literal: true

module Exwiw
  class BelongsTo
    include Serdes

    attribute :foreign_key, String
    attribute :table_name, String
    # Set only for a polymorphic association. `foreign_type` is the name of the
    # column storing the type (e.g. `reviewable_type`), and `type_value` is the
    # value held in that column (e.g. `"Product"`). Both are nil for a
    # non-polymorphic belongs_to.
    attribute :foreign_type, optional(String), skip_serializing_if_nil: true
    attribute :type_value, optional(String), skip_serializing_if_nil: true
    # User-owned fields. The schema generators never emit them, but a user can
    # add them by hand and they survive regeneration (see TableConfig#merge /
    # MongodbCollectionConfig#merge). `ignore:true` drops the relation from
    # extraction once the config is loaded (see #reject_ignored_members!).
    attribute :comment, optional(String), skip_serializing_if_nil: true
    attribute :ignore, Serdes::OptionalType.new(Serdes::ConcreteType.new(Boolean)), skip_serializing_if_nil: true

    def self.from_symbol_keys(hash)
      from(hash.transform_keys(&:to_s))
    end

    def polymorphic?
      !foreign_type.nil?
    end

    # Structural identity used to match a freshly generated belongs_to against a
    # user-maintained one during merge. `comment`/`ignore` are user-owned and so
    # are intentionally excluded.
    def identity
      [table_name, foreign_key, foreign_type, type_value]
    end

    def to_hash
      super.compact
    end
  end
end

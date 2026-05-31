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

    def self.from_symbol_keys(hash)
      from(hash.transform_keys(&:to_s))
    end

    def polymorphic?
      !foreign_type.nil?
    end

    def to_hash
      super.compact
    end
  end
end

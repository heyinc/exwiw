# frozen_string_literal: true

module Exwiw
  # Serdes type for a `replace_with` value: a template String with `{column}`
  # placeholders, rendered as text, or a non-String JSON scalar used verbatim so
  # a column that is not text keeps its type (in MongoDB, its BSON type).
  class MaskValue < Serdes::TypeBase
    PERMITTED = [String, Integer, Float].freeze

    # What counts as a `{column}` placeholder in a template. An empty brace pair
    # names no column and is therefore not one, which is what lets `{}` be an
    # empty-JSON mask. Shared so the adapters that parse a template and the
    # generator that has to avoid emitting one cannot drift apart.
    PLACEHOLDER = /\{[^{}]+\}/

    def permit?(value)
      value == true || value == false || PERMITTED.any? { |type| value.is_a?(type) }
    end

    # Whether `value` is used verbatim rather than rendered as a template.
    def self.scalar?(value)
      !value.is_a?(String) && !value.nil?
    end

    def to_s
      "mask_value"
    end
  end
end

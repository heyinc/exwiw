# frozen_string_literal: true

module Exwiw
  # Serdes type for a `replace_with` value: a template String with `{column}`
  # placeholders, rendered as text, or a non-String JSON scalar used verbatim so
  # a column that is not text keeps its type (in MongoDB, its BSON type).
  class MaskValue < Serdes::TypeBase
    PERMITTED = [String, Integer, Float].freeze

    # What counts as a `{column}` placeholder: an empty brace pair names no
    # column, which is what lets `{}` be an empty-JSON mask. One definition,
    # shared by the adapters that parse a template and the generator that must
    # avoid emitting one — keep it capture-free, since the splitter's `scan`
    # reads whole matches.
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

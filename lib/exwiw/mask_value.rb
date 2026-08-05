# frozen_string_literal: true

module Exwiw
  # Serdes type for a `replace_with` value: either a template String (with
  # `{column}` placeholders) or a non-String JSON scalar used verbatim.
  #
  # A String is rendered into the dump as text — the right shape for a
  # varchar/text column, but the wrong one for an integer/boolean/date column,
  # where a masked value has to keep the column's type (a JSON document field
  # would even change its BSON type). Those columns therefore take the scalar
  # form (`"replace_with": 0`), which is emitted as a typed literal instead of
  # being template-rendered.
  class MaskValue < Serdes::TypeBase
    PERMITTED = [String, Integer, Float].freeze

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

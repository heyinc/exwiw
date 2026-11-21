# frozen_string_literal: true

module Exwiw
  # Serdes type for a flag that is `true` or absent: `false` is rejected because, as a non-null member of an overlay's
  # exclusive mask group, it would silently drop the base's mask while reading as the stricter setting.
  class TrueFlag < Serdes::TypeBase
    # @param value [Object]
    # @return [Boolean]
    def permit?(value)
      value == true
    end

    # @return [String]
    def to_s
      "true (remove the key, or set it to null in an overlay, to unset it)"
    end
  end
end

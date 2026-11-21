# frozen_string_literal: true

require "securerandom"

module Exwiw
  # Serdes type for a `replace_with_random` value, `"hex:<bytes>"`: that many random bytes as lowercase hex.
  class RandomMask < Serdes::TypeBase
    FORMAT = /\Ahex:(?<bytes>[1-9]\d*)\z/

    # Fewer bytes are guessable; more are just wasteful.
    BYTES_RANGE = (16..1024)

    # @param value [Object]
    # @return [Boolean]
    def permit?(value)
      value.is_a?(String) && !(match = FORMAT.match(value)).nil? && BYTES_RANGE.cover?(match[:bytes].to_i)
    end

    # @return [String]
    def to_s
      "\"hex:<bytes>\" (bytes #{BYTES_RANGE.min} to #{BYTES_RANGE.max})"
    end

    # @param value [String] a permitted value
    # @return [Proc] returns a fresh random value on each call
    def self.generator(value)
      bytes = FORMAT.match(value)[:bytes].to_i
      -> { SecureRandom.hex(bytes) }
    end
  end
end

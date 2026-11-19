# frozen_string_literal: true

require "securerandom"

module Exwiw
  # The value of a column's `generate` masking key: `"<kind>:<argument>"`, which
  # replaces the value with a new random one on every call. `random:<len>` is the
  # only kind so far; a kind is added to KINDS with the parsing of its argument.
  class Generator
    FORMAT = /\A(?<kind>[a-z_]+):(?<argument>.*)\z/m

    MIN_LENGTH = 1
    MAX_LENGTH = 256

    # kind => parser of the argument String; returns the attributes, nil when the argument is invalid.
    KINDS = {
      random: lambda do |argument|
        next nil unless argument.match?(/\A\d+\z/)

        length = Integer(argument, 10)
        { length: length } if length.between?(MIN_LENGTH, MAX_LENGTH)
      end,
    }.freeze
    private_constant :KINDS

    # @param spec [String] e.g. "random:16"
    # @return [Exwiw::Generator]
    # @raise [ArgumentError] if the format does not match; the message has the value and the expected format
    def self.parse(spec)
      match = FORMAT.match(spec) if spec.is_a?(String)
      parser = match && KINDS[match[:kind].to_sym]
      attributes = parser&.call(match[:argument])
      unless attributes
        raise ArgumentError,
              "invalid generate value #{spec.inspect}; expected \"random:<length>\" " \
              "where <length> is an integer from #{MIN_LENGTH} to #{MAX_LENGTH}."
      end

      new(match[:kind].to_sym, **attributes)
    end

    # @return [Symbol] the kind (only :random so far)
    attr_reader :kind
    # @return [Integer] the number of characters generated
    attr_reader :length

    def initialize(kind, length:)
      @kind = kind
      @length = length
      freeze
    end

    # @return [String] a string of [A-Za-z0-9] from SecureRandom, different on every call
    def call
      SecureRandom.alphanumeric(length)
    end
  end
end

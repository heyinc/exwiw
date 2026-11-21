# frozen_string_literal: true

module Exwiw
  # The `check:` section of the config file: which static checks `schema check` runs on the committed config, and
  # against which profiles. Shared by the CLI and the rake tasks.
  #
  #   check:
  #     integrity: {}                  # on unless `false`
  #     guessable_credentials: true    # off unless set
  #     unmasked_sensitive:            # off unless set
  #       patterns: ['(^|_)kana(_|$)'] # added to MaskRules::DEFAULT_MASK_PATTERNS
  #       profiles: [base, dev]        # base + every declared profile when omitted
  class CheckConfig
    CHECKS = %w[integrity guessable_credentials unmasked_sensitive].freeze
    DEFAULTS = { "integrity" => true, "guessable_credentials" => false, "unmasked_sensitive" => false }.freeze
    OPTIONS = {
      "integrity" => %w[profiles], "guessable_credentials" => %w[profiles], "unmasked_sensitive" => %w[profiles patterns],
    }.freeze

    # The reserved profile name for the base config, with no overlay merged in.
    BASE_PROFILE = "base"

    # @return [Hash{String => Array<String, nil>}] each enabled check's profiles (nil is the base config)
    attr_reader :profiles_by_check

    # @return [Array<Regexp>] the built-in mask patterns followed by the configured ones
    attr_reader :mask_patterns

    # @param value [Object] the raw `check` value (nil when absent)
    # @param profiles [Array<String>] the declared profiles
    # @param source [String] the config file, for error messages
    # @return [Exwiw::CheckConfig]
    # @raise [ArgumentError] when `value` is not a valid `check` section
    def self.parse(value, profiles: [], source: "the config file")
      value = {} if value.nil?
      raise ArgumentError, "'check' must be a mapping of #{CHECKS.join(', ')} (got #{value.inspect}) in #{source}" unless value.is_a?(Hash)

      unknown = value.keys - CHECKS
      unless unknown.empty?
        raise ArgumentError, "unknown check(s) #{unknown.join(', ')} under 'check' in #{source} (known: #{CHECKS.join(', ')})"
      end

      profiles_by_check = {}
      patterns = []
      CHECKS.each do |check|
        options = item_options(check, value.fetch(check, DEFAULTS.fetch(check)), source)
        next if options.nil?

        profiles_by_check[check] = item_profiles(check, options["profiles"], profiles, source, options.key?("profiles"))
        patterns = item_patterns(options["patterns"], source) if options.key?("patterns")
      end
      new(profiles_by_check: profiles_by_check, mask_patterns: MaskRules::DEFAULT_MASK_PATTERNS + patterns)
    end

    # The checks a config file without `check:` runs.
    #
    # @param profiles [Array<String>] the declared profiles
    # @return [Exwiw::CheckConfig]
    def self.default(profiles: [])
      parse(nil, profiles: profiles)
    end

    # @param profiles_by_check [Hash{String => Array<String, nil>}]
    # @param mask_patterns [Array<Regexp>]
    def initialize(profiles_by_check:, mask_patterns: MaskRules::DEFAULT_MASK_PATTERNS)
      @profiles_by_check = profiles_by_check.freeze
      @mask_patterns = mask_patterns.freeze
    end

    # @return [Array<String>] the enabled checks, in CHECKS order
    def enabled
      CHECKS.select { |check| @profiles_by_check.key?(check) }
    end

    # @param check [String]
    # @return [Boolean]
    def enabled?(check)
      @profiles_by_check.key?(check)
    end

    # @return [Array<String, nil>] every profile some enabled check runs against (nil is the base config)
    def profiles
      @profiles_by_check.values.flatten.uniq
    end

    # @return [Hash{String => Object}, nil] the item's options, or nil when it is disabled
    private_class_method def self.item_options(check, raw, source)
      case raw
      when false then nil
      when true then {}
      when Hash
        unknown = raw.keys - OPTIONS.fetch(check)
        unless unknown.empty?
          raise ArgumentError,
                "unknown option(s) #{unknown.join(', ')} under 'check.#{check}' in #{source} " \
                "(allowed: #{OPTIONS.fetch(check).join(', ')})"
        end
        raw
      else
        raise ArgumentError, "'check.#{check}' must be true, false or a mapping of options (got #{raw.inspect}) in #{source}"
      end
    end

    private_class_method def self.item_profiles(check, raw, declared, source, given)
      return [nil, *declared] unless given

      unless raw.is_a?(Array) && !raw.empty? && raw.all? { |name| name.is_a?(String) }
        raise ArgumentError,
              "'check.#{check}.profiles' must be a non-empty list of profile names (got #{raw.inspect}) in #{source}; " \
              "set 'check.#{check}: false' to disable the check"
      end

      unknown = raw - [BASE_PROFILE, *declared]
      unless unknown.empty?
        raise ArgumentError,
              "'check.#{check}.profiles' names undeclared profile(s) #{unknown.join(', ')} in #{source} " \
              "(use '#{BASE_PROFILE}' or one of the declared profiles: #{declared.empty? ? 'none' : declared.join(', ')})"
      end

      raw.uniq.map { |name| name == BASE_PROFILE ? nil : name }
    end

    private_class_method def self.item_patterns(raw, source)
      unless raw.is_a?(Array) && raw.all? { |pattern| pattern.is_a?(String) }
        raise ArgumentError, "'check.unmasked_sensitive.patterns' must be a list of regular expressions (got #{raw.inspect}) in #{source}"
      end

      raw.map do |pattern|
        Regexp.new(pattern, Regexp::IGNORECASE)
      rescue RegexpError => e
        raise ArgumentError, "'check.unmasked_sensitive.patterns' has an invalid regular expression #{pattern.inspect} in #{source}: #{e.message}"
      end
    end
  end
end

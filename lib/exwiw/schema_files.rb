# frozen_string_literal: true

module Exwiw
  # Where the schema config files live and which of them are profile overlays.
  #
  # A profile overlay `<table>.<profile>.json` sits next to its base
  # `<table>.json` and is merged into it when that profile is selected (see
  # Exwiw::ConfigOverlay). Only declared profile names are recognized, so
  # without `profiles:` in the config file every `*.json` stays a base file,
  # exactly as before overlays existed.
  module SchemaFiles
    PROFILE_NAME_PATTERN = /\A[a-z0-9_-]+\z/

    module_function

    # Validates `profiles:` from the config file; raises ArgumentError naming `source`.
    #
    # @param value [Object] the raw `profiles` value (nil when absent)
    # @param source [String] the config file, for the error message
    # @return [Array<String>] the declared profile names
    def validate_profiles!(value, source:)
      return [] if value.nil?

      unless value.is_a?(Array) && value.all? { |name| name.is_a?(String) }
        raise ArgumentError, "'profiles' must be a list of profile names (got #{value.inspect}) in #{source}"
      end

      value.each do |name|
        unless name.match?(PROFILE_NAME_PATTERN)
          raise ArgumentError,
                "profile name '#{name}' must contain only lowercase letters, digits, '_' and '-' in #{source}"
        end
      end

      duplicates = value.tally.select { |_, count| count > 1 }.keys
      unless duplicates.empty?
        raise ArgumentError, "profile(s) #{duplicates.join(', ')} declared more than once in #{source}"
      end

      value.dup.freeze
    end

    # @param path [String] a schema config file path
    # @param profiles [Array<String>] the declared profiles
    # @return [String, nil] the profile `path` is an overlay of, or nil for a base file
    def overlay_profile(path, profiles)
      stem, dot, profile = File.basename(path, ".json").rpartition(".")
      return nil if dot.empty? || stem.empty?

      profiles.include?(profile) ? profile : nil
    end

    def overlay?(path, profiles)
      !overlay_profile(path, profiles).nil?
    end

    # @return [Array<String>] the base config files directly under `dir`, sorted
    def base_files(dir, profiles)
      Dir.glob(File.join(dir, "*.json")).sort.reject { |path| overlay?(path, profiles) }
    end

    # @return [Array<String>] the overlays directly under `dir` (only `profile`'s when given), sorted
    def overlay_files(dir, profiles, profile: nil)
      Dir.glob(File.join(dir, "*.json")).sort.select do |path|
        found = overlay_profile(path, profiles)
        found && (profile.nil? || found == profile)
      end
    end

  end
end

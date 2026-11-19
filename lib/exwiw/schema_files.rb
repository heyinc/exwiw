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
    module_function

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

  end
end

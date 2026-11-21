# frozen_string_literal: true

require "yaml"

module Exwiw
  # Minimal reader for the exwiw config YAML (exwiw.yml / exwiw.yaml).
  #
  # The CLI has its own, richer config handling (CLI#apply_config_file!); this
  # module exists for contexts that have no CLI in scope — chiefly the
  # `exwiw:schema:*` rake tasks, which otherwise only knew the
  # EXWIW_SCHEMA_DIR_PATH env var and a hard-coded default. It deliberately
  # reads only what those tasks need (schema_dir, profiles, check): an absent or
  # unreadable config simply yields nothing so the caller can fall back.
  module ConfigFile
    # Mirrors CLI::DEFAULT_CONFIG_PATHS; .yml wins when both are present.
    DEFAULT_PATHS = %w[exwiw.yml exwiw.yaml].freeze

    module_function

    # The `schema_dir` from the config file, expanded to an absolute path
    # relative to the config file's own directory (matching the CLI). Returns
    # nil when no config file is found, it cannot be parsed, or it does not set
    # `schema_dir`. Pass an explicit `path` to read a specific file; otherwise
    # the default paths are looked up in the current directory.
    def schema_dir(path = nil)
      path, config = read(path)
      return nil if config.nil?

      value = config["schema_dir"]
      return nil if value.nil?

      # Strip a trailing slash and resolve relative to the config file's
      # directory, exactly as CLI#expand_dir does.
      value = value.end_with?("/") ? value[0..-2] : value
      File.expand_path(value, File.dirname(File.expand_path(path)))
    end

    # The declared schema profiles (`profiles`), so the rake tasks recognize the
    # same overlay files as the CLI. Unlike #schema_dir, an unreadable config or
    # an invalid declaration raises: falling back to none would make tidy treat
    # overlays as base files.
    #
    # @param path [String, nil] the config file; the default paths when nil
    # @return [Array<String>] the declared profiles; empty when there are none
    # @raise [ArgumentError] if the config file cannot be parsed or `profiles` is invalid
    def profiles(path = nil)
      path, config = read(path, strict: true)
      return [] if config.nil?

      SchemaFiles.validate_profiles!(config["profiles"], source: path)
    end

    # The `check` section (see CheckConfig), the defaults when absent. Raises like #profiles: falling back to the
    # defaults would silently skip a check the config enables.
    #
    # @param path [String, nil] the config file; the default paths when nil
    # @param profiles [Array<String>] the declared profiles (#profiles)
    # @return [Exwiw::CheckConfig]
    # @raise [ArgumentError] if the config file cannot be parsed or `check` is invalid
    def check(path = nil, profiles: [])
      path, config = read(path, strict: true)
      return CheckConfig.default(profiles: profiles) if config.nil?

      CheckConfig.parse(config["check"], profiles: profiles, source: path)
    end

    # Unless `strict`, an unparsable or non-mapping config reads as no config; an empty file always does.
    private_class_method def read(path, strict: false)
      path ||= DEFAULT_PATHS.map { |p| File.expand_path(p) }.find { |p| File.file?(p) }
      return [path, nil] if path.nil? || !File.file?(path)

      config =
        begin
          YAML.safe_load(File.read(path))
        rescue Psych::SyntaxError => e
          raise ArgumentError, "Could not parse the config file #{path}: #{e.message}" if strict

          nil
        end
      if strict && !config.nil? && !config.is_a?(Hash)
        raise ArgumentError, "The config file #{path} must be a YAML mapping (got #{config.class})."
      end

      [path, config.is_a?(Hash) ? config : nil]
    end
  end
end

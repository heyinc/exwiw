# frozen_string_literal: true

require "yaml"

module Exwiw
  # Reads the optional exwiw config file (`exwiw.yml` / `exwiw.yaml`).
  #
  # The CLI keeps its own richer config handling (full option merge, key
  # validation, connection-key rejection) inline in `CLI#apply_config_file!`.
  # This is the smaller slice the `exwiw:schema:*` rake tasks need: locate the
  # file and read `schema_dir`, so generation writes into the same directory
  # `export`/`explain` later read from, without a second source of truth.
  #
  # Paths inside the file are resolved relative to the file's own directory
  # (matching CLI semantics), so `schema_dir: exwiw/schema` works with the
  # config kept at the project root.
  class ConfigFile
    # Default config file names, searched in order under the base directory when
    # no explicit path is given. `.yml` wins when both are present.
    DEFAULT_PATHS = %w[exwiw.yml exwiw.yaml].freeze

    # Locate a config file: `path` if given (expanded against `base_dir`, and it
    # must exist), otherwise the first default path present under `base_dir`.
    # Returns a ConfigFile, or nil when none is found.
    def self.find(path: nil, base_dir: Dir.pwd)
      resolved =
        if path && !path.empty?
          abs = File.expand_path(path, base_dir)
          raise ArgumentError, "Config file not found: #{path}" unless File.file?(abs)
          abs
        else
          DEFAULT_PATHS.map { |p| File.expand_path(p, base_dir) }.find { |p| File.file?(p) }
        end
      return nil if resolved.nil?

      new(resolved)
    end

    attr_reader :path

    def initialize(path)
      @path = path
      @data = YAML.safe_load(File.read(path)) || {}
      unless @data.is_a?(Hash)
        raise ArgumentError, "Config file must be a YAML mapping (key: value): #{path}"
      end
    end

    # The configured schema directory, resolved to an absolute path relative to
    # the config file's own directory. Returns nil when the key is absent.
    def schema_dir
      expand_dir(@data["schema_dir"])
    end

    # Strip a trailing slash (like the CLI's dir options) and expand relative to
    # the config file's directory. Returns nil for a nil/empty value.
    private def expand_dir(value)
      return nil if value.nil? || value.empty?
      value = value.end_with?("/") ? value[0..-2] : value
      File.expand_path(value, File.dirname(@path))
    end
  end
end

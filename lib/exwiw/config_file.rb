# frozen_string_literal: true

require "yaml"

module Exwiw
  # Minimal reader for the exwiw config YAML (exwiw.yml / exwiw.yaml).
  #
  # The CLI has its own, richer config handling (CLI#apply_config_file!); this
  # module exists for contexts that have no CLI in scope — chiefly the
  # `exwiw:schema:*` rake tasks, which otherwise only knew the
  # EXWIW_SCHEMA_DIR_PATH env var and a hard-coded default. It deliberately
  # reads only what those tasks need (schema_dir) and never aborts the process:
  # an absent or unreadable config simply yields nil so the caller can fall back.
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
      path ||= DEFAULT_PATHS.map { |p| File.expand_path(p) }.find { |p| File.file?(p) }
      return nil if path.nil? || !File.file?(path)

      config =
        begin
          YAML.safe_load(File.read(path))
        rescue Psych::SyntaxError
          nil
        end
      return nil unless config.is_a?(Hash)

      value = config["schema_dir"]
      return nil if value.nil?

      # Strip a trailing slash and resolve relative to the config file's
      # directory, exactly as CLI#expand_dir does.
      value = value.end_with?("/") ? value[0..-2] : value
      File.expand_path(value, File.dirname(File.expand_path(path)))
    end
  end
end

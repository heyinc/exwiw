# frozen_string_literal: true

require "json"

module Exwiw
  # Overlay entries that reference what their base config no longer has: a
  # table/collection that is gone, or a column, field or belongs_to removed from
  # it. `schema check` reports them and `tidy` prunes them.
  module OverlayDrift
    # One overlay file against its base. `pruned` is nil when the whole base is gone.
    Entry = Struct.new(:path, :profile, :name, :pruned, :removed, keyword_init: true) do
      def stale?
        pruned.nil? || !removed.empty?
      end

      # e.g. `dev:users` for a gone table, `dev:users.columns.legacy_col` for an entry.
      def labels(table_label = name)
        return ["#{profile}:#{table_label}"] if pruned.nil?

        removed.map { |entry| "#{profile}:#{table_label}.#{entry}" }
      end
    end

    module_function

    # @param overlay_paths [Array<String>] overlay files of one directory
    # @param bases_by_name [Hash{String => Hash}] that directory's raw base configs
    # @param config_class [Class] TableConfig or MongodbCollectionConfig
    # @param profiles [Array<String>] the declared profiles
    # @return [Array<Entry>] one per overlay file
    def scan(overlay_paths, bases_by_name, config_class:, profiles:)
      overlay_paths.map do |path|
        overlay = read_json(path)
        name = overlay["name"] if overlay.is_a?(Hash)
        unless name.is_a?(String)
          raise ArgumentError, "overlay #{path} must be a JSON object with a 'name' naming the config it overlays."
        end
        # tidy rewrites overlays through here without merging them, so their keys are validated here.
        StrictKeys.validate!(config_class, overlay, owner: "overlay #{path}")

        profile = SchemaFiles.overlay_profile(path, profiles)
        base = bases_by_name[name]
        if base.nil?
          Entry.new(path: path, profile: profile, name: name, pruned: nil, removed: [])
        else
          pruned, removed = ConfigOverlay.prune(config_class, base, overlay)
          Entry.new(path: path, profile: profile, name: name, pruned: pruned, removed: removed)
        end
      end
    end

    # Deletes the overlays whose base is gone and rewrites those with stale
    # entries, keeping the rest of each overlay as written.
    #
    # @param dir [String] one schema directory
    # @return [Array<String>] the labels of what was removed
    def prune!(dir, config_class:, profiles:)
      overlay_paths = SchemaFiles.overlay_files(dir, profiles)
      return [] if overlay_paths.empty?

      scan(overlay_paths, read_bases(dir, profiles), config_class: config_class, profiles: profiles)
        .select(&:stale?)
        .flat_map do |entry|
          if entry.pruned.nil?
            File.delete(entry.path)
          else
            File.write(entry.path, JSON.pretty_generate(entry.pruned) + "\n")
          end
          entry.labels
        end
    end

    # @return [Hash{String => Hash}] the raw base configs directly under `dir`, by name
    def read_bases(dir, profiles)
      SchemaFiles.base_files(dir, profiles).each_with_object({}) do |path, acc|
        config = read_json(path)
        acc[config["name"]] = config if config.is_a?(Hash) && config["name"]
      end
    end

    def read_json(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise JSON::ParserError, "invalid JSON in schema config '#{path}': #{e.message}"
    end
  end
end

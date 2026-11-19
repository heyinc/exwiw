# frozen_string_literal: true

require "json"

module Exwiw
  # Loads the schema config files of one directory.
  class SchemaLoader
    # A raw config ready to load, and the file it came from.
    Source = Struct.new(:hash, :base_path, keyword_init: true) do
      def label
        base_path
      end
    end

    # @param dir [String] the schema directory (one database's)
    # @param config_class [Class] TableConfig or MongodbCollectionConfig
    # @param profiles [Array<String>] the declared profiles
    def initialize(dir:, config_class:, profiles: [])
      @dir = dir
      @config_class = config_class
      @profiles = profiles
    end

    # @param reject_ignored [Boolean] drop the `ignore: true` members as extraction does
    # @return [Array<TableConfig, MongodbCollectionConfig>] in base file order
    # @raise [ArgumentError] if a config cannot be loaded
    def load(reject_ignored: true)
      sources.map do |source|
        config = load_source(source)
        # Run on a copy when the full config is wanted: a config left with nothing
        # to extract must still fail, as it would on export.
        target = reject_ignored ? config : load_source(source)
        with_source(source) { target.reject_ignored_members! }
        config
      end
    end

    # @return [Array<Source>] the raw configs
    def sources
      read_bases
    end

    private def read_bases
      by_name = {}
      SchemaFiles.base_files(@dir, @profiles).map do |path|
        hash = JSON.parse(File.read(path))
        name = hash["name"] if hash.is_a?(Hash)
        if name && by_name.key?(name)
          raise ArgumentError,
                "'#{name}' is configured twice in #{@dir}: #{by_name[name]} and #{path}. " \
                "Each table/collection must have exactly one base config file."
        end

        by_name[name] = path if name
        ConfigOverlay.validate_unique_keys!(@config_class, hash, owner: "#{path} ('#{name}')")
        Source.new(hash: hash, base_path: path)
      end
    end

    private def load_source(source)
      with_source(source) { @config_class.from(source.hash) }
    end

    # Only an unknown key names the file, as before: `.from` knows the table, not the file.
    private def with_source(source)
      yield
    rescue UnknownConfigKeyError => e
      raise UnknownConfigKeyError, "#{source.label}: #{e.message}", e.backtrace
    end
  end
end

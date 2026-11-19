# frozen_string_literal: true

require "json"

module Exwiw
  # Loads the schema config files of one directory, merging the overlays of the
  # selected profile into their base configs (see Exwiw::ConfigOverlay).
  class SchemaLoader
    # A raw config ready to load, and the file(s) it came from.
    Source = Struct.new(:hash, :base_path, :overlay_path, :profile, keyword_init: true) do
      def label
        return base_path if overlay_path.nil?

        "#{overlay_path} (profile '#{profile}', merged into #{base_path})"
      end
    end

    # @param dir [String] the schema directory (one database's)
    # @param config_class [Class] TableConfig or MongodbCollectionConfig
    # @param profiles [Array<String>] the declared profiles
    # @param profile [String, nil] the profile to apply, or nil for none
    def initialize(dir:, config_class:, profiles: [], profile: nil)
      @dir = dir
      @config_class = config_class
      @profiles = profiles
      @profile = profile
    end

    # @param reject_ignored [Boolean] drop the `ignore: true` members as extraction does
    # @return [Array<TableConfig, MongodbCollectionConfig>] in base file order
    # @raise [ArgumentError] if a config or an overlay cannot be loaded
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

    # @return [Array<Source>] the raw configs, overlays merged in
    def sources
      bases = read_bases
      return bases if @profile.nil?

      apply_overlays(bases)
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

    private def apply_overlays(bases)
      by_name = bases.each_with_object({}) { |source, acc| acc[source.hash["name"]] = source if source.hash.is_a?(Hash) }
      merged = {}

      SchemaFiles.overlay_files(@dir, @profiles, profile: @profile).each do |path|
        overlay = JSON.parse(File.read(path))
        owner = "overlay #{path}"
        name = overlay["name"] if overlay.is_a?(Hash)
        unless name.is_a?(String)
          raise ArgumentError, "#{owner} must be a JSON object with a 'name' naming the config it overlays."
        end

        base = by_name[name]
        if base.nil?
          raise ArgumentError, "#{owner}: there is no base config named '#{name}' in #{@dir} to overlay."
        end
        if merged.key?(name)
          raise ArgumentError,
                "'#{name}' has more than one overlay for profile '#{@profile}': " \
                "#{merged[name].overlay_path} and #{path}."
        end

        merged[name] = Source.new(
          hash: ConfigOverlay.merge(@config_class, base.hash, overlay, owner: owner),
          base_path: base.base_path,
          overlay_path: path,
          profile: @profile,
        )
      end

      bases.map { |source| merged.fetch(source.hash["name"], source) }
    end

    private def load_source(source)
      with_source(source) { @config_class.from(source.hash) }
    end

    # A base-only config keeps the historical message (only an unknown key names
    # the file); a merged config always names the files, since the error may come
    # from either of them.
    private def with_source(source)
      yield
    rescue UnknownConfigKeyError => e
      raise UnknownConfigKeyError, "#{source.label}: #{e.message}", e.backtrace
    rescue ArgumentError, Serdes::TypeError, Serdes::RequiredAttributeError => e
      raise if source.overlay_path.nil?

      raise e.class, "#{source.label}: #{e.message}", e.backtrace
    end
  end
end

# frozen_string_literal: true

module Exwiw
  # The loaded schema configs of one database, with the profile merged in. Runners only read it, so one Schema can
  # be shared across runs.
  class Schema
    # @return [String] the schema directory it was loaded from
    attr_reader :dir

    # @return [String, nil] the profile merged in
    attr_reader :profile

    # @return [Class] TableConfig or MongodbCollectionConfig
    attr_reader :config_class

    # @return [Array<Exwiw::TableConfig, Exwiw::MongodbCollectionConfig>] in base file order
    attr_reader :configs

    # @return [Hash{String => Exwiw::TableConfig, Exwiw::MongodbCollectionConfig}]
    attr_reader :table_by_name

    # @param dir [String] the schema directory (one database's)
    # @param config_class [Class] TableConfig or MongodbCollectionConfig (the adapter's table_config_class)
    # @param profiles [Array<String>] the declared profiles
    # @param profile [String, nil] the profile to apply, or nil for none
    # @return [Exwiw::Schema]
    # @raise [ArgumentError] if a config or an overlay cannot be loaded
    def self.load(dir:, config_class:, profiles: [], profile: nil)
      configs = SchemaLoader.new(dir: dir, config_class: config_class, profiles: profiles, profile: profile).load
      new(dir: dir, profile: profile, config_class: config_class, configs: configs)
    end

    # @param dir [String]
    # @param profile [String, nil]
    # @param config_class [Class]
    # @param configs [Array<Exwiw::TableConfig, Exwiw::MongodbCollectionConfig>]
    def initialize(dir:, profile:, config_class:, configs:)
      @dir = dir
      @profile = profile
      @config_class = config_class
      @configs = configs.freeze
      @table_by_name = configs.to_h { |config| [config.name, config] }.freeze
    end

    # @param adapter_class [Class] the adapter a runner reads with
    # @return [void]
    # @raise [ArgumentError] when the schema was loaded for another kind of adapter (SQL configs for MongoDB, or back)
    def check_adapter!(adapter_class)
      return if adapter_class.table_config_class == config_class

      raise ArgumentError, "the schema in #{dir} was loaded as #{config_class.name}, but #{adapter_class.name} reads #{adapter_class.table_config_class.name}"
    end
  end
end

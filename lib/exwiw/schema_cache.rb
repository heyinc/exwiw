# frozen_string_literal: true

module Exwiw
  # Keeps loaded schemas for `ttl` seconds, so masking record by record does not parse every schema file each time.
  # A change to a schema file or the config file shows within `ttl`. Safe to share across threads.
  class SchemaCache
    DEFAULT_TTL = 60

    # @return [Exwiw::SchemaCache] the cache shared by the whole process
    def self.shared
      @shared
    end

    Entry = Data.define(:schema, :expires_at)
    private_constant :Entry

    # @param ttl [Numeric] seconds a loaded schema is kept
    def initialize(ttl: DEFAULT_TTL)
      @ttl = ttl
      @entries = {}
      @lock = Mutex.new
    end

    # @param config_class [Class] TableConfig or MongodbCollectionConfig
    # @param schema_dir [String, nil] the schema config directory; else the config file's `schema_dir`, else `schema`
    #   next to `config_path` when it is given, else "exwiw/schema"
    # @param profile [String, nil] the schema profile to apply, one of the config file's `profiles`
    # @param config_path [String, Pathname, nil] the exwiw config file; ./exwiw.yml (or .yaml) when nil
    # @return [Exwiw::Schema]
    # @raise [ArgumentError] if `config_path` is not a file, the schema directory has no config, or a config or an
    #   overlay cannot be loaded
    def fetch(config_class:, schema_dir: nil, profile: nil, config_path: nil)
      config_path &&= File.expand_path(config_path.to_s)
      raise ArgumentError, "exwiw config file not found: #{config_path}" if config_path && !File.file?(config_path)

      @lock.synchronize do
        # Relative paths (and the config file lookup) depend on the working directory, so it is part of the key.
        key = [config_class, schema_dir && File.expand_path(schema_dir), profile, config_path, Dir.pwd]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        entry = @entries[key]
        return entry.schema if entry && now < entry.expires_at

        dir = schema_dir || ConfigFile.schema_dir(config_path) ||
              (config_path ? File.join(File.dirname(config_path), "schema") : "exwiw/schema")
        profiles = ConfigFile.profiles(config_path)
        schema = Schema.load(dir: dir, config_class: config_class, profiles: profiles, profile: profile)
        raise ArgumentError, "no schema config in #{File.expand_path(dir)}" if schema.configs.empty?

        @entries[key] = Entry.new(schema: schema, expires_at: now + @ttl)
        schema
      end
    end

    @shared = new
  end
end

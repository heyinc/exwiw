# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tmpdir"

module Exwiw
  # Reports how the committed schema config differs from what the application
  # would generate now, plus the columns still waiting for a masking decision
  # and what the static checks (CheckConfig) find in the committed config.
  # Regenerating into a copy rather than over the config directory lets it run
  # on a working tree it must not modify (CI).
  #
  # The diff/report side is source-agnostic (it reads JSON config files); what
  # varies per schema source is only how to regenerate, injected as
  # `regenerator` — a callable that receives a directory pre-seeded with a copy
  # of the committed config and rewrites it the way `generate!` + `tidy!`
  # would. `models:` remains as the ActiveRecord shorthand for it.
  class SchemaCheck
    CATEGORIES = %w[
      added_tables added_columns removed_tables removed_columns changed_tables needs_mask_decision
    ].freeze

    # The subset of the removals that would break an `export` run: a non-ignored
    # config still referencing a table or column the schema no longer has, i.e.
    # the extraction SELECT would name something that does not exist. Removals of
    # `ignore: true` entries stay out (nothing selects them), as do additions.
    # `--fail-on=stale` keys the exit code to these. Deliberate over-approximation:
    # a hand-written config naming a database VIEW lands here too (tidy's stance),
    # though a SELECT against it would succeed.
    STALE_CATEGORIES = %w[stale_tables stale_columns].freeze

    # Overlay entries referencing a table/column/field/belongs_to the
    # regenerated base no longer has (labeled `<profile>:<table>[.<entry>]`).
    # Once the base is regenerated such an overlay no longer merges, so it is
    # stale drift. Reported only when profiles are declared, keeping the report
    # unchanged otherwise.
    OVERLAY_STALE = "overlay_stale"

    # The static checks on the committed config (see CheckConfig and MaskRules): one key per enabled check. Unlike
    # drift, regenerating never fixes them.
    CHECK_CATEGORIES = CheckConfig::CHECKS

    def self.from_rails_application(schema_dir:, profiles: [], checks: nil)
      Rails.application.eager_load!
      new(models: ActiveRecord::Base.descendants, schema_dir: schema_dir, profiles: profiles, checks: checks)
    end

    # The Mongoid counterpart. `Mongoid.models` registers only the base class of
    # an inheritance hierarchy, which is exactly what MongoidSchemaGenerator
    # expects (it expands descendants itself), so the same source the generate
    # task introspects is used here.
    def self.from_mongoid_application(schema_dir:, profiles: [], checks: nil)
      Rails.application.eager_load!
      new(
        schema_dir: schema_dir,
        regenerator: mongoid_regenerator(::Mongoid.models, profiles: profiles),
        profiles: profiles,
        config_class: MongodbCollectionConfig,
        checks: checks,
      )
    end

    # The adapter of a database directory of an ActiveRecord application: the default connection's for the flat
    # (single-database) layout, else the Rails database configuration named like the directory.
    #
    # @param database [String, nil] the directory name, nil for the flat layout
    # @return [String] the canonical adapter name
    # @raise [ArgumentError] when no database configuration matches
    def self.active_record_adapter(database)
      db_config =
        if database.nil?
          ActiveRecord::Base.connection_db_config
        else
          env = defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env : ActiveRecord::ConnectionHandling::DEFAULT_ENV.call
          ActiveRecord::Base.configurations.configs_for(env_name: env, name: database)
        end
      if db_config.nil?
        raise ArgumentError,
              "no database configuration named '#{database}' (the schema directory's name) in the '#{env}' environment, " \
              "so its adapter is unknown"
      end

      Adapter.normalize_active_record_name(db_config.adapter)
    end

    # The regeneration step `from_mongoid_application` injects, exposed so a
    # caller (and the specs) can run the check against an explicit model list
    # without a Rails application — and so what they exercise is the very lambda
    # production uses.
    #
    # `skip_unsupported` is deliberately left off: this runs as a CI gate, and a
    # newly added construct exwiw cannot represent has to fail the task with the
    # generator's actionable message rather than quietly become an `ignore: true`
    # config that reports clean while the collection stops being dumped.
    def self.mongoid_regenerator(models, profiles: [])
      lambda do |tmp_dir|
        # Explicit: safe mode is not optional here, whatever the library default is.
        MongoidSchemaGenerator.new(models: models, output_dir: tmp_dir, safe_new_columns: true,
                                   profiles: profiles).generate!
        MongoidSchemaGenerator.new(models: models, output_dir: tmp_dir, profiles: profiles).tidy!
      end
    end

    # `profiles` are the declared schema profiles: their overlays are left out of
    # the diff, must merge into the committed config (`config_class` loads the
    # result), and are checked against the regenerated one (OVERLAY_STALE).
    #
    # `checks` (CheckConfig, the defaults when nil) selects the static checks, which judge each database directory
    # with its `adapter`: a name, or a callable taking the directory name (nil for the flat layout). It defaults to
    # mongodb for MongoDB configs and to .active_record_adapter with `models:`.
    def initialize(schema_dir:, models: nil, regenerator: nil, profiles: [], config_class: TableConfig, checks: nil, adapter: nil)
      if models.nil? && regenerator.nil?
        raise ArgumentError, "SchemaCheck requires either models: or regenerator:"
      end

      @schema_dir = schema_dir
      @profiles = profiles
      @config_class = config_class
      @regenerator = regenerator || active_record_regenerator(models)
      @checks = checks || CheckConfig.default(profiles: profiles)
      @adapter = adapter ||
                 (config_class == MongodbCollectionConfig && "mongodb") ||
                 (models && self.class.method(:active_record_adapter))
    end

    # The report as a plain Hash. Every list is sorted, so a given state always
    # produces the same output (it ends up in a CI comment).
    #
    # @raise [ArgumentError] if an overlay does not merge into the committed config
    def run
      committed = read_configs(@schema_dir)
      validate_overlays!
      overlay_stale = nil
      regenerated = Dir.mktmpdir do |tmp_dir|
        regenerate_into(tmp_dir)
        overlay_stale = stale_overlay_entries(tmp_dir) unless @profiles.empty?
        read_configs(tmp_dir)
      end

      report = diff(committed, regenerated)
      report["needs_mask_decision"] = flagged_columns(committed)
      report[OVERLAY_STALE] = overlay_stale if overlay_stale
      report.merge(static_findings)
    end

    # Whether the report requires someone to act: the config is out of date, a
    # column's masking has not been decided yet, or a static check found something.
    def self.clean?(report)
      (CATEGORIES + [OVERLAY_STALE] + CHECK_CATEGORIES).all? { |category| report.fetch(category, []).empty? }
    end

    # Whether the report contains what regenerating the config addresses: drift, or an undecided mask.
    def self.drifted?(report)
      (CATEGORIES + [OVERLAY_STALE]).any? { |category| !report.fetch(category, []).empty? }
    end

    # @return [Array<String>] the static checks with findings in the report
    def self.failed_checks(report)
      CHECK_CATEGORIES.reject { |category| report.fetch(category, []).empty? }
    end

    # Whether the report contains drift that would break an extraction run
    # (see STALE_CATEGORIES). Always a subset of what makes clean? false.
    def self.stale?(report)
      (STALE_CATEGORIES + [OVERLAY_STALE]).any? { |category| !report.fetch(category, []).empty? }
    end

    # Runs the enabled static checks on every database directory as export loads it, once per selected profile. A
    # finding repeated across profiles is one entry listing them.
    private def static_findings
      enabled = @checks.enabled
      return {} if enabled.empty?

      found = enabled.to_h { |check| [check, Hash.new { |h, k| h[k] = [] }] }
      database_dirs.each do |dir, database|
        adapter_class = adapter_class_for(database)
        @checks.profiles.each do |profile|
          schema = Schema.load(dir: dir, config_class: @config_class, profiles: @profiles, profile: profile)
          schema.check_adapter!(adapter_class)
          schema.configs.each do |config|
            next if MaskUpdateRunner.unmaskable_reason(config)

            table = adapter_class.describe_masks(config, schema.table_by_name)
            label = database ? "#{database}/#{config.name}" : config.name
            enabled.each do |check|
              next unless @checks.profiles_by_check.fetch(check).include?(profile)

              check_findings(check, table, adapter_class).each do |path, reason|
                found[check][["#{label}.#{path}", reason]] << (profile || CheckConfig::BASE_PROFILE)
              end
            end
          end
        end
      end

      found.transform_values do |entries|
        entries.map { |(location, reason), profiles| "#{location} [#{profiles.join(', ')}]: #{reason}" }.sort
      end
    end

    # @return [Array<Array(String, String)>] each finding's path and reason
    private def check_findings(check, table, adapter_class)
      patterns = @checks.mask_patterns
      credential_patterns = @checks.credential_patterns
      case check
      when "integrity"
        findings = []
        if MaskRules.masks_primary_key?(table)
          findings << [table.primary_key, "the primary key is masked, which breaks the rows referencing it and mask-update, " \
                                          "which addresses rows by it; remove the mask"]
        end
        unless table.selects_primary_key
          findings << [table.primary_key, "the primary key is not selected (is it ignored?), which breaks the rows " \
                                          "referencing it and mask-update, which addresses rows by it; select it"]
        end
        findings
      when "guessable_credentials"
        reason = "masked to a guessable value; mask it with unset or replace_with_random, or set allow_guessable_credential"
        MaskRules.unaccepted_credentials(table, credential_patterns).map { |path| [path, reason] } +
          MaskRules.stray_guessable_allowances(table, credential_patterns).map do |path|
            [path, "sets allow_guessable_credential, but is not a credential-looking column masked to a guessable value; " \
                   "remove it"]
          end
      when "unmasked_sensitive"
        MaskRules.unmasked_sensitive(table, patterns).map do |path|
          [path, "looks sensitive but is not masked; add a mask, or set allow_unmasked if the real value is needed"]
        end +
          MaskRules.stray_unmasked_allowances(table, patterns).map do |path, why|
            [path, "sets allow_unmasked, but #{STRAY_UNMASKED_REASONS.fetch(why)}; remove it"]
          end
      end
    end

    STRAY_UNMASKED_REASONS = {
      masked: "it is masked",
      exempt: "it is the primary key or a belongs_to foreign key, which are never masked",
      not_sensitive: "its name matches no mask pattern",
    }.freeze
    private_constant :STRAY_UNMASKED_REASONS

    # Each directory holding base config files, with its database name (nil for the flat layout).
    private def database_dirs
      return [] unless Dir.exist?(@schema_dir)

      SchemaFiles.base_files_recursive(@schema_dir, @profiles).map { |path| File.dirname(path) }.uniq.map do |dir|
        relative = Pathname.new(dir).relative_path_from(Pathname.new(@schema_dir)).to_s
        [dir, relative == "." ? nil : relative]
      end
    end

    private def adapter_class_for(database)
      name = @adapter.respond_to?(:call) ? @adapter.call(database) : @adapter
      if name.nil?
        raise ArgumentError,
              "the schema check needs the database adapter to run the #{@checks.enabled.join(', ')} check(s); " \
              "pass adapter: (the CLI's --adapter)"
      end

      Adapter.class_for(name)
    rescue RuntimeError => e
      raise ArgumentError, "cannot resolve the adapter of #{database || 'the schema directory'}: #{e.message}"
    end

    # The overlays are left out of the copy: the generators never read them, and
    # the regenerated side is compared against base configs only.
    private def regenerate_into(tmp_dir)
      if Dir.exist?(@schema_dir)
        FileUtils.cp_r(File.join(@schema_dir, "."), tmp_dir)
        SchemaFiles.overlay_files_recursive(tmp_dir, @profiles).each { |path| File.delete(path) }
      end
      @regenerator.call(tmp_dir)
    end

    private def active_record_regenerator(models)
      lambda do |tmp_dir|
        # Explicit: safe mode is not optional here, whatever the library default is.
        SchemaGenerator.new(models: models, output_dir: tmp_dir, safe_new_columns: true,
                            profiles: @profiles).generate!
        SchemaGenerator.new(models: models, output_dir: tmp_dir, profiles: @profiles).tidy!
      end
    end

    # Loads every (directory, profile) that has overlays exactly as export would,
    # so an overlay that does not merge fails the check whatever --fail-on says.
    private def validate_overlays!
      return if @profiles.empty? || !Dir.exist?(@schema_dir)

      SchemaFiles.overlay_files_recursive(@schema_dir, @profiles)
                 .map { |path| [File.dirname(path), SchemaFiles.overlay_profile(path, @profiles)] }
                 .uniq
                 .each do |dir, profile|
        SchemaLoader.new(dir: dir, config_class: @config_class, profiles: @profiles, profile: profile).load
      end
    end

    private def stale_overlay_entries(regenerated_dir)
      return [] unless Dir.exist?(@schema_dir)

      SchemaFiles.overlay_files_recursive(@schema_dir, @profiles).group_by { |path| File.dirname(path) }
                 .flat_map do |dir, paths|
        relative = Pathname.new(dir).relative_path_from(Pathname.new(@schema_dir)).to_s
        bases = OverlayDrift.read_bases(File.join(regenerated_dir, relative), @profiles)
        OverlayDrift.scan(paths, bases, config_class: @config_class, profiles: @profiles).flat_map do |entry|
          entry.labels(relative == "." ? entry.name : "#{relative}/#{entry.name}")
        end
      end.sort
    end

    # Every config file under `dir`, keyed by its path relative to `dir` so the
    # per-database subdirectories stay distinct. Hand-editing these files is the
    # workflow this drives, so a syntax error has to name the file it is in.
    private def read_configs(dir)
      return {} unless Dir.exist?(dir)

      SchemaFiles.base_files_recursive(dir, @profiles).each_with_object({}) do |path, acc|
        key = Pathname.new(path).relative_path_from(Pathname.new(dir)).to_s
        begin
          acc[key] = JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          raise JSON::ParserError, "invalid JSON in schema config '#{path}': #{e.message}"
        end
      end
    end

    private def diff(committed, regenerated)
      report = (CATEGORIES + STALE_CATEGORIES).to_h { |category| [category, []] }

      (committed.keys | regenerated.keys).sort.each do |key|
        before = committed[key]
        after = regenerated[key]

        if before.nil?
          report["added_tables"] << table_label(key, after)
          next
        end
        if after.nil?
          label = table_label(key, before)
          report["removed_tables"] << label
          # A rails-managed table is dumped whole, so its disappearance breaks
          # the export too; only `ignore: true` keeps a removed table out.
          report["stale_tables"] << label unless before["ignore"]
          next
        end
        next if before == after

        label = table_label(key, before)
        report["changed_tables"] << label
        added, removed = column_diff(before, after)
        report["added_columns"] += added.sort.map { |column| "#{label}.#{column}" }
        report["removed_columns"] += removed.sort.map { |column| "#{label}.#{column}" }
        if extracted?(before)
          stale = removed & extracted_column_names(before)
          report["stale_columns"] += stale.sort.map { |column| "#{label}.#{column}" }
        end
      end

      report
    end

    private def column_diff(before, after)
      before_names = column_names(before)
      after_names = column_names(after)
      [after_names - before_names, before_names - after_names]
    end

    # `fields` is the MongoDB config's spelling of `columns`.
    private def column_names(config)
      (config["columns"] || config["fields"] || []).map { |column| column["name"] }
    end

    # Whether the extraction SELECT names this table's columns: an `ignore: true`
    # config only contributes DDL, and a rails-managed one is dumped as
    # `SELECT *` — so a removed column cannot break either. (A removed
    # rails-managed table still can; #diff handles that separately.)
    private def extracted?(config)
      !config["ignore"] && !TableConfig::RAILS_MANAGED_TYPES.include?(config["type"])
    end

    # The columns the extraction SELECT actually names: `ignore: true` columns
    # are dropped when the config loads, so their staleness breaks nothing.
    private def extracted_column_names(config)
      (config["columns"] || config["fields"] || [])
        .reject { |column| column["ignore"] }
        .map { |column| column["name"] }
    end

    # How a table is named in the report. The database is part of the label, or
    # the same table name in two of them collides (each has `schema_migrations`).
    private def table_label(key, config)
      name = config&.fetch("name", nil) || File.basename(key, ".json")
      db = File.dirname(key)
      db == "." ? name : "#{db}/#{name}"
    end

    private def flagged_columns(committed)
      committed.flat_map do |key, config|
        (config["columns"] || config["fields"] || [])
          .select { |column| column["needs_mask_decision"] }
          .map { |column| "#{table_label(key, config)}.#{column['name']}" }
      end.sort
    end
  end
end

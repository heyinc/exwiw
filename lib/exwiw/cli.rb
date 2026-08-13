# frozen_string_literal: true

require 'fileutils'
require 'logger'
require 'optparse'
require 'pathname'

require 'json'
require 'yaml'

require 'exwiw'

module Exwiw
  class CLI
    KNOWN_SUBCOMMANDS = %w[export explain schema].freeze

    # The verbs `exwiw schema` takes, mirroring the `exwiw:schema:*` rake tasks
    # a Rails application would run instead.
    SCHEMA_VERBS = %w[generate check tidy].freeze

    # `schema check` exit codes. 1 means "the config needs work" — that is the
    # signal CI acts on — so a failure to *perform* the check (an unreachable
    # database, a malformed config) must not use it, or an infrastructure
    # problem reads as a schema problem and gets "fixed" by regenerating.
    SCHEMA_CHECK_DIRTY_EXIT = 1
    SCHEMA_CHECK_ERROR_EXIT = 2

    # Config file loaded automatically when --config is omitted, if one exists in
    # the current directory. Kept at the project root (rather than under exwiw/)
    # so that config-relative paths like `schema_dir: exwiw/schema` read naturally.
    # Both extensions are accepted; .yml wins when both are present.
    DEFAULT_CONFIG_PATHS = %w[exwiw.yml exwiw.yaml].freeze

    # Keys accepted in the config file. Anything outside this set is rejected so
    # a typo surfaces immediately instead of being silently ignored. These mirror
    # the non-connection CLI options (plus `adapter`).
    ALLOWED_CONFIG_KEYS = %w[
      adapter
      schema_dir
      output_dir
      output_format
      insert_only
      after_insert_hook
      log_level
      target_table
      target_collection
      ids
      ids_field
      scope_column
      parallel_workers
      explain_verbosity
      mongodb_query_timeout_ms
    ].freeze

    # MongoDB explain verbosity levels (passed through to the server's explain
    # command). `queryPlanner` only plans the query and is the safe default —
    # the query is not executed; the other two run it to gather runtime stats.
    EXPLAIN_VERBOSITIES = %w[queryPlanner executionStats allPlansExecution].freeze
    DEFAULT_EXPLAIN_VERBOSITY = "queryPlanner"

    # Database connection settings are environment-specific (and sometimes
    # secret-adjacent), so they must be passed via CLI/env, never the committed
    # config file. `adapter` is the one connection-ish key allowed in config.
    REJECTED_CONNECTION_KEYS = %w[host port user database uri password].freeze

    # Keys that only make sense for `export`. They are skipped when merging config
    # for `explain` so a shared config file does not trip validate_explain_only!,
    # and for `schema`, which performs no export at all.
    EXPORT_ONLY_CONFIG_KEYS = %w[output_dir output_format insert_only after_insert_hook parallel_workers].freeze

    def self.start(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup

      @subcommand =
        if !@argv.empty? && !@argv.first.start_with?("-") && KNOWN_SUBCOMMANDS.include?(@argv.first)
          @argv.shift
        else
          "export"
        end

      # `schema` is the one subcommand taking a verb of its own
      # (`exwiw schema generate`), so the next positional argument belongs to
      # it. An unknown or missing verb is not consumed here — validation
      # reports it with the list of valid ones rather than OptionParser
      # failing on a stray argument.
      @schema_verb =
        if @subcommand == "schema" && !@argv.empty? && !@argv.first.start_with?("-")
          @argv.shift
        end

      @help = @argv.empty?

      @database_host = nil
      @database_port = nil
      @database_user = nil
      @database_password = ENV["DATABASE_PASSWORD"]
      @connection_uri = nil
      @output_dir = nil
      @schema_dir = nil
      @from_db = false
      @config_file_path = nil
      @database_adapter = nil
      @database_name = nil
      @target_table_name = nil
      @target_collection_name = nil
      @ids = []
      @ids_field = nil
      @scope_column = nil
      @output_format = nil
      @insert_only = nil
      @after_insert_hook_path = nil
      @parallel_workers = nil
      @mongodb_query_timeout_ms = nil
      @explain_verbosity = nil
      # nil (not :info) so we can tell "user passed --log-level" from the default,
      # letting a config-file value fill in; the :info default is applied later.
      @log_level = nil

      parser.parse!(@argv)
    end

    def run
      if @help
        puts parser.help
        return
      end

      validate_options!

      connection_config = ConnectionConfig.new(
        adapter: @database_adapter,
        host: @database_host,
        port: @database_port,
        user: @database_user,
        password: @database_password,
        database_name: @database_name,
        uri: @connection_uri,
        mongodb_query_timeout_ms: @mongodb_query_timeout_ms,
      )

      dump_target = DumpTarget.new(
        table_name: @target_table_name,
        ids: @ids,
        ids_field: @ids_field,
        scope_column: @scope_column,
      )

      logger = build_logger

      case @subcommand
      when "export"
        confirm_output_dir_clear!
        Runner.new(
          connection_config: connection_config,
          output_dir: @output_dir,
          schema_dir: @schema_dir,
          dump_target: dump_target,
          output_format: @output_format,
          insert_only: @insert_only,
          after_insert_hook_path: @after_insert_hook_path,
          parallel_workers: @parallel_workers,
          cli_options: build_cli_options_hash,
          logger: logger,
        ).run
      when "explain"
        ExplainRunner.new(
          connection_config: connection_config,
          schema_dir: @schema_dir,
          dump_target: dump_target,
          logger: logger,
          io: $stdout,
          explain_verbosity: @explain_verbosity,
        ).run
      when "schema"
        run_schema(connection_config)
      end
    end

    # `exwiw schema generate|check|tidy --from-db`: the same three operations
    # the `exwiw:schema:*` rake tasks perform for a Rails application, driven
    # from a database connection instead of from the application's models.
    private def run_schema(connection_config)
      introspector = DbIntrospector.build(connection_config)

      case @schema_verb
      when "generate" then run_schema_generate(introspector)
      when "tidy" then run_schema_tidy(introspector)
      when "check" then run_schema_check(introspector)
      end
    end

    private def run_schema_generate(introspector)
      DbSchemaGenerator.new(
        introspector: introspector,
        output_dir: @schema_dir,
        safe_new_columns: schema_safe_new_columns?,
      ).generate!

      puts "exwiw: wrote the schema config for #{@database_name} to #{@schema_dir}."
    end

    private def run_schema_tidy(introspector)
      result = DbSchemaGenerator.new(introspector: introspector, output_dir: @schema_dir).tidy!

      if result.empty?
        puts "exwiw: schema config is already tidy; nothing to remove."
        return
      end

      result.removed_tables.each do |name|
        puts "exwiw: removed config for table '#{name}' (no longer exists in the database)."
      end
      result.removed_columns.each do |table_name, columns|
        puts "exwiw: removed column(s) #{columns.join(', ')} from '#{table_name}' (no longer in the table)."
      end
      result.removed_belongs_tos.each do |table_name, targets|
        puts "exwiw: removed belongs_to(s) to #{targets.join(', ')} from '#{table_name}' " \
             "(the target table no longer exists)."
      end
    end

    private def run_schema_check(introspector)
      # Regenerate exactly as `generate` + `tidy` would, into the copy
      # SchemaCheck hands over, so the report is the diff against a config that
      # has been through both steps rather than only the first.
      regenerator = lambda do |tmp_dir|
        # Explicit: safe mode is not optional here, whatever the library default is.
        DbSchemaGenerator.new(introspector: introspector, output_dir: tmp_dir, safe_new_columns: true).generate!
        DbSchemaGenerator.new(introspector: introspector, output_dir: tmp_dir).tidy!
      end

      report =
        begin
          SchemaCheck.new(schema_dir: @schema_dir, regenerator: regenerator).run
        rescue StandardError => e
          # See SCHEMA_CHECK_ERROR_EXIT: not being able to run the check is a
          # different answer from "the config is out of date".
          $stderr.puts "exwiw: could not run the schema check (#{e.class}: #{e.message})"
          exit SCHEMA_CHECK_ERROR_EXIT
        end

      json = JSON.pretty_generate(report)
      puts json
      # A file too, so a caller need not assume stdout carries only the JSON.
      File.write(ENV["EXWIW_SCHEMA_CHECK_OUTPUT"], json + "\n") if ENV["EXWIW_SCHEMA_CHECK_OUTPUT"]

      return if SchemaCheck.clean?(report)

      $stderr.puts "exwiw: the schema config is out of date or has undecided masking; " \
                   "run `exwiw schema generate --from-db` (then `exwiw schema tidy --from-db`) " \
                   "and resolve every `needs_mask_decision` column."
      exit SCHEMA_CHECK_DIRTY_EXIT
    end

    # Safe mode is on unless EXWIW_NEW_COLUMNS=plain, matching the rake task: a
    # first-time bootstrap wants it off, since there every column is new and
    # flagging the whole config at once is noise.
    private def schema_safe_new_columns?
      ENV["EXWIW_NEW_COLUMNS"] != "plain"
    end

    private def validate_options!
      # Fill in any options not given on the CLI from the config file. Done first
      # so a config-provided `adapter` is in place before normalization below.
      # CLI values always win (the merge only fills nil/empty ivars).
      apply_config_file!

      # Default log level once CLI and config have both had their say.
      @log_level ||= :info

      # Fold driver/Rails adapter spellings (mysql2, sqlite3) into exwiw's
      # canonical names up front, so every check below — and the
      # EXWIW_DATABASE_ADAPTER passed to hooks — sees the canonical name.
      @database_adapter = Adapter.normalize_name(@database_adapter)

      # Reject an unknown adapter up front, before checking adapter-specific
      # options like host/port/password, so the error points at the real problem.
      unless Adapter::CANONICAL_ADAPTERS.include?(@database_adapter)
        $stderr.puts "Invalid adapter. Available options are: #{Adapter::CANONICAL_ADAPTERS.join(', ')} " \
                     "(aliases also accepted: #{Adapter::ADAPTER_ALIASES.keys.join(', ')})"
        exit 1
      end

      resolve_target_collection_alias!
      resolve_scope_column!
      resolve_ids_field!
      resolve_uri_option!
      resolve_parallel_workers!
      resolve_mongodb_query_timeout_ms!

      if @subcommand == "explain"
        validate_explain_only!
        resolve_explain_verbosity!
      end

      # `schema` shares only the connection options with the other subcommands:
      # it neither extracts rows nor reads a dump target, so every check below
      # is about an export it will not perform. Its own requirements — a schema
      # source, an introspectable adapter, a schema dir the verb can use — are
      # validated instead.
      if @subcommand == "schema"
        validate_schema_options!
        return
      end

      if @database_adapter != "sqlite"
        # When a connection URI is supplied (mongodb only), host/port/database
        # are read from the URI, so none of them are required on the CLI.
        required_options = {}
        unless @connection_uri
          required_options["Target database host"] = @database_host
          required_options["Target database port"] = @database_port
          required_options["Target database name"] = @database_name
        end
        required_options["Database user"] = @database_user unless @database_adapter == "mongodb"
        required_options.each do |k, v|
          if v.nil?
            $stderr.puts "#{k} is required"
            exit 1
          end
        end

        if @database_adapter != "mongodb" && (@database_password.nil? || @database_password.empty?)
          $stderr.puts "environment variable 'DATABASE_PASSWORD' is required"
          exit 1
        end
      end

      if @subcommand == "export"
        @output_dir ||= "dump"
        @output_format ||= "insert"
        @insert_only = @insert_only ? true : false

        valid_output_formats = ["insert", "copy"]
        unless valid_output_formats.include?(@output_format)
          $stderr.puts "Invalid output format '#{@output_format}'. Available options are: #{valid_output_formats.join(', ')}"
          exit 1
        end

        if @output_format == "copy" && @database_adapter != "postgresql"
          $stderr.puts "--output-format=copy is only supported with the postgresql adapter"
          exit 1
        end
      end

      if @schema_dir.nil?
        $stderr.puts "Schema dir is required (pass --schema-dir or set schema_dir in the config file)"
        exit 1
      end

      unless Dir.exist?(@schema_dir)
        $stderr.puts "Schema dir does not exist: #{@schema_dir}"
        exit 1
      end

      if Dir.glob(File.join(@schema_dir, "*.json")).empty?
        $stderr.puts "Schema dir contains no .json files: #{@schema_dir}"
        exit 1
      end

      if @target_table_name && @ids.empty?
        $stderr.puts "--ids is required when --target-table is specified"
        exit 1
      end

      if @scope_column && @ids.empty?
        $stderr.puts "--ids is required when --scope-column is specified"
        exit 1
      end

      if !@target_table_name && !@scope_column && @ids.any?
        $stderr.puts "--target-table or --scope-column is required when --ids is specified"
        exit 1
      end

      if @after_insert_hook_path
        unless File.file?(@after_insert_hook_path)
          $stderr.puts "--after-insert-hook file not found: #{@after_insert_hook_path}"
          exit 1
        end

        ext = File.extname(@after_insert_hook_path)
        if ext != '.rb' && !File.executable?(@after_insert_hook_path)
          $stderr.puts "--after-insert-hook must be a .rb file or an executable script: #{@after_insert_hook_path}"
          exit 1
        end
      end
    end

    # Merge settings from the config file (YAML) into any options the user did
    # not pass on the CLI. The CLI always wins: every assignment below only fills
    # an ivar that is still nil/empty after parsing ARGV. Connection settings
    # (except `adapter`) are rejected here — they belong on the CLI/env.
    private def apply_config_file!
      path =
        if @config_file_path
          unless File.file?(@config_file_path)
            $stderr.puts "Config file not found: #{@config_file_path}"
            exit 1
          end
          @config_file_path
        else
          DEFAULT_CONFIG_PATHS.map { |p| File.expand_path(p) }.find { |p| File.file?(p) }
        end
      return if path.nil?

      # Paths inside the config file are resolved relative to the file's own
      # directory (not cwd), so `schema_dir: exwiw/schema` reads naturally with the
      # config kept at the project root, and an absolute --config works from any
      # cwd. (CLI path flags stay cwd-relative — each source resolves relative to
      # where it is written.) `path` is always absolute here.
      base = File.dirname(path)

      config = YAML.safe_load(File.read(path)) || {}
      unless config.is_a?(Hash)
        $stderr.puts "Config file must be a YAML mapping (key: value): #{path}"
        exit 1
      end

      config.each_key do |key|
        if REJECTED_CONNECTION_KEYS.include?(key)
          $stderr.puts "'#{key}' is a database connection setting and must be passed via the CLI/environment, not the config file (#{path})"
          exit 1
        end
        unless ALLOWED_CONFIG_KEYS.include?(key)
          $stderr.puts "Unknown config key '#{key}' in #{path}. Allowed keys: #{ALLOWED_CONFIG_KEYS.join(', ')}"
          exit 1
        end
      end

      # For `explain`, drop export-only keys so a config shared with `export`
      # does not make validate_explain_only! reject the run.
      if @subcommand == "explain" || @subcommand == "schema"
        config = config.reject { |k, _| EXPORT_ONLY_CONFIG_KEYS.include?(k) }
      end

      @database_adapter ||= config["adapter"]
      @schema_dir ||= expand_dir(config["schema_dir"], base)
      @output_dir ||= expand_dir(config["output_dir"], base)
      @after_insert_hook_path ||= (File.expand_path(config["after_insert_hook"], base) if config["after_insert_hook"])
      @output_format ||= config["output_format"]
      @insert_only = config["insert_only"] if @insert_only.nil? && config.key?("insert_only")
      @log_level ||= config["log_level"]&.to_sym
      @target_table_name ||= config["target_table"]
      @target_collection_name ||= config["target_collection"]
      if @ids.empty? && config.key?("ids")
        raw = config["ids"]
        # Accept either a YAML list or a "1,2" string; coerce to strings to match
        # the CLI's `--ids=1,2` -> ["1", "2"] shape.
        @ids = (raw.is_a?(String) ? raw.split(",") : Array(raw)).map(&:to_s)
      end
      @ids_field ||= config["ids_field"]
      @scope_column ||= config["scope_column"]
      @parallel_workers ||= parse_parallel_workers(config["parallel_workers"]) if config.key?("parallel_workers")
      @mongodb_query_timeout_ms ||= parse_mongodb_query_timeout_ms(config["mongodb_query_timeout_ms"]) if config.key?("mongodb_query_timeout_ms")
      @explain_verbosity ||= config["explain_verbosity"]
    end

    # Strip a trailing slash (like the CLI's dir options) and expand relative to
    # `base` (the config file's directory). Returns nil for a nil value.
    private def expand_dir(value, base)
      return nil if value.nil?
      value = value.end_with?("/") ? value[0..-2] : value
      File.expand_path(value, base)
    end

    # `--target-collection` is a mongodb-only alias of `--target-table`. Fold it
    # into @target_table_name (the single field the rest of the CLI/runner uses)
    # after rejecting the misuses: combining it with --target-table, or using it
    # with a non-mongodb adapter.
    private def resolve_target_collection_alias!
      return if @target_collection_name.nil?

      if @target_table_name
        $stderr.puts "Specify only one of --target-table and --target-collection"
        exit 1
      end

      if @database_adapter != "mongodb"
        $stderr.puts "--target-collection is only supported by the mongodb adapter (use --target-table)"
        exit 1
      end

      @target_table_name = @target_collection_name
    end

    # `--ids-field` overrides which field `--ids` is matched against on the target
    # collection (defaulting to its primary key). It is mongodb-only and
    # meaningless without a target collection to constrain. (The SQL adapters have
    # no equivalent: a scoped target's `scope_column` is the column `--ids` filter
    # against there.) Runs after resolve_target_collection_alias! so
    # @target_table_name already reflects the collection alias.
    private def resolve_ids_field!
      return if @ids_field.nil?

      if @database_adapter != "mongodb"
        $stderr.puts "--ids-field is only supported by the mongodb adapter"
        exit 1
      end

      unless @target_table_name
        $stderr.puts "--target-table is required when --ids-field is specified"
        exit 1
      end
    end

    # `--scope-column` is **deprecated**: it selected scope-column mode with a
    # single global column for every table. The preferred way is to declare a
    # per-table `scope_column:` in the schema config and pass `--target-table`
    # (the target is then scoped like any other table). The flag still works as
    # before — SQL-only and mutually exclusive with `--target-table` — but emits a
    # deprecation warning. Runs after resolve_target_collection_alias! so
    # --target-collection is already folded into @target_table_name.
    private def resolve_scope_column!
      return if @scope_column.nil?

      sql_adapters = ["mysql", "postgresql", "sqlite"]
      unless sql_adapters.include?(@database_adapter)
        $stderr.puts "--scope-column is only supported by the sql adapters"
        exit 1
      end

      if @target_table_name
        $stderr.puts "--scope-column cannot be combined with --target-table/--target-collection"
        exit 1
      end

      if @ids_field
        $stderr.puts "--scope-column cannot be combined with --ids-field"
        exit 1
      end

      $stderr.puts "warning: --scope-column is deprecated; declare a per-table `scope_column:` " \
                   "in the schema config and run with --target-table instead."
    end

    # `--uri` supplies a full connection string (e.g. `mongodb+srv://...`) and is
    # mongodb-only — the SQL adapters shell out to their own client binaries with
    # discrete host/port/user flags and have no equivalent. Runs after the
    # adapter name has been normalized so the family check is reliable.
    private def resolve_uri_option!
      return if @connection_uri.nil?

      if @database_adapter != "mongodb"
        $stderr.puts "--uri is only supported by the mongodb adapter (use --host/--port)"
        exit 1
      end
    end

    # `--parallel-workers` opts into the MongoDB fork-parallel dump schedule
    # (docs/mongodb-dump-parallelism-2x-notes.md). It is mongodb-only (the SQL
    # adapters shell out to their own dumpers) and must be a positive integer;
    # N<2 is accepted but runs serially. Runs after the adapter name is normalized
    # so the family check is reliable. `explain` rejection is handled separately
    # by validate_explain_only!.
    private def resolve_parallel_workers!
      return if @parallel_workers.nil?

      if @database_adapter != "mongodb"
        $stderr.puts "--parallel-workers is only supported by the mongodb adapter"
        exit 1
      end

      if @parallel_workers < 1
        $stderr.puts "--parallel-workers must be a positive integer (got #{@parallel_workers})"
        exit 1
      end
    end

    # Coerce a config-file `parallel_workers` (YAML scalar) to Integer, matching
    # the CLI flag's Integer coercion. A non-integer value is a config typo, so
    # fail fast rather than silently dropping it.
    private def parse_parallel_workers(value)
      return nil if value.nil?

      Integer(value)
    rescue ArgumentError, TypeError
      $stderr.puts "config 'parallel_workers' must be an integer (got #{value.inspect})"
      exit 1
    end

    # `--mongodb-query-timeout-ms` sets the global, server-enforced CSOT timeout
    # applied to every MongoDB query (find cursor lifetime, count, executing
    # explain). It is mongodb-only (the SQL adapters shell out to their own
    # clients) and must be a positive integer. A per-collection `query_timeout_ms`
    # in the schema config overrides it. Runs after the adapter name is normalized
    # so the family check is reliable.
    private def resolve_mongodb_query_timeout_ms!
      return if @mongodb_query_timeout_ms.nil?

      if @database_adapter != "mongodb"
        $stderr.puts "--mongodb-query-timeout-ms is only supported by the mongodb adapter"
        exit 1
      end

      if @mongodb_query_timeout_ms < 1
        $stderr.puts "--mongodb-query-timeout-ms must be a positive integer (got #{@mongodb_query_timeout_ms})"
        exit 1
      end
    end

    # Coerce a config-file `mongodb_query_timeout_ms` (YAML scalar) to Integer,
    # matching the CLI flag's Integer coercion. A non-integer value is a config
    # typo, so fail fast rather than silently dropping it.
    private def parse_mongodb_query_timeout_ms(value)
      return nil if value.nil?

      Integer(value)
    rescue ArgumentError, TypeError
      $stderr.puts "config 'mongodb_query_timeout_ms' must be an integer (got #{value.inspect})"
      exit 1
    end

    # Everything `exwiw schema <verb>` needs, and nothing the export path
    # requires. Runs instead of the export/explain validations, not after them.
    private def validate_schema_options!
      unless SCHEMA_VERBS.include?(@schema_verb)
        $stderr.puts "Usage: exwiw schema #{SCHEMA_VERBS.join('|')} --from-db [options] " \
                     "(got #{@schema_verb.inspect})"
        exit 1
      end

      # The schema source is spelled out rather than assumed. Reading a live
      # database is one way to describe an application's schema and not the
      # only conceivable one, so the flag keeps the command unambiguous today
      # and leaves the reader expecting alternatives tomorrow.
      unless @from_db
        $stderr.puts "`exwiw schema #{@schema_verb}` requires --from-db to say where the schema is read from " \
                     "(a live database connection). A Rails application can use the exwiw:schema:#{@schema_verb} " \
                     "rake task instead, which reads its models."
        exit 1
      end

      unless DbIntrospector::SUPPORTED_ADAPTERS.include?(@database_adapter)
        $stderr.puts "--from-db supports the #{DbIntrospector::SUPPORTED_ADAPTERS.join(' and ')} adapters only " \
                     "(got '#{@database_adapter}'). sqlite and mongodb schemas are not read this way."
        exit 1
      end

      {
        "Target database host" => @database_host,
        "Target database port" => @database_port,
        "Target database name" => @database_name,
        "Database user" => @database_user,
      }.each do |name, value|
        if value.nil?
          $stderr.puts "#{name} is required"
          exit 1
        end
      end

      # Deliberately no DATABASE_PASSWORD requirement, unlike export: schema
      # generation is commonly run in CI against a throwaway database started
      # with trust/empty authentication, and refusing an empty password would
      # make the check unrunnable exactly where it is most wanted. The password
      # is still used when set.

      if @schema_dir.nil?
        $stderr.puts "Schema dir is required (pass --schema-dir or set schema_dir in the config file)"
        exit 1
      end

      # `generate` is also the bootstrap command, so it creates the directory;
      # `check` and `tidy` only ever read an existing config, and a missing
      # directory there means the wrong path far more often than an empty one.
      if @schema_verb == "generate"
        FileUtils.mkdir_p(@schema_dir)
      elsif !Dir.exist?(@schema_dir)
        $stderr.puts "Schema dir does not exist: #{@schema_dir}"
        exit 1
      end
    end

    private def validate_explain_only!
      rejected = []
      rejected << "--output-dir" unless @output_dir.nil?
      rejected << "--output-format" unless @output_format.nil?
      rejected << "--insert-only" unless @insert_only.nil?
      rejected << "--after-insert-hook" unless @after_insert_hook_path.nil?
      rejected << "--parallel-workers" unless @parallel_workers.nil?

      unless rejected.empty?
        $stderr.puts "The following options are not applicable in 'explain' subcommand: #{rejected.join(', ')}"
        exit 1
      end
    end

    # Resolve the MongoDB explain verbosity for an `explain` run. It is
    # mongodb-only, so this no-ops (and skips validation) for the SQL adapters,
    # which ignore verbosity. The env var wins over the config-file value (it is
    # the more run-specific override, like a CLI flag would be); when neither is
    # set the safe, execution-free `queryPlanner` default is used.
    private def resolve_explain_verbosity!
      return unless @database_adapter == "mongodb"

      env = ENV["EXWIW_MONGODB_EXPLAIN_VERBOSITY"]
      @explain_verbosity = env unless env.nil? || env.empty?
      @explain_verbosity ||= DEFAULT_EXPLAIN_VERBOSITY

      unless EXPLAIN_VERBOSITIES.include?(@explain_verbosity)
        $stderr.puts "Invalid explain verbosity '#{@explain_verbosity}'. Available options are: #{EXPLAIN_VERBOSITIES.join(', ')}"
        exit 1
      end
    end

    # The export clears @output_dir before writing (see Runner#clean_output_dir!).
    # That is destructive, so when running interactively (stdin is a tty) ask for
    # confirmation first. In non-interactive contexts (CI, pipes) we proceed
    # without prompting. Only prompt when there is actually something to delete.
    private def confirm_output_dir_clear!
      return unless $stdin.tty?
      return unless Dir.exist?(@output_dir)

      entries = Dir.each_child(@output_dir).to_a
      return if entries.empty?

      $stderr.puts "All contents of the output dir will be removed before export:"
      $stderr.puts "  #{@output_dir} (#{entries.size} entr#{entries.size == 1 ? 'y' : 'ies'})"
      $stderr.print "Continue? [y/N]: "

      answer = $stdin.gets&.strip&.downcase
      unless answer == "y" || answer == "yes"
        $stderr.puts "Aborted."
        exit 1
      end
    end

    private def build_cli_options_hash
      {
        database_host: @database_host,
        database_port: @database_port,
        database_user: @database_user,
        database_password: @database_password,
        output_dir: @output_dir,
        schema_dir: @schema_dir,
        database_adapter: @database_adapter,
        database_name: @database_name,
        target_table: @target_table_name,
        ids: @ids.dup.freeze,
        ids_field: @ids_field,
        scope_column: @scope_column,
        output_format: @output_format,
        insert_only: @insert_only,
        log_level: @log_level,
        after_insert_hook: @after_insert_hook_path,
      }.freeze
    end

    private def build_logger
      formatter = proc do |severity, timestamp, progname, msg|
        formatted_ts = timestamp.strftime("%Y-%m-%d %H:%M:%S")
        "#{formatted_ts} [#{progname}]: #{msg}\n"
      end

      # When STDOUT is a pipe (captured by a parent process / log aggregation),
      # Logger.new(STDOUT) is block-buffered, so per-collection progress only
      # surfaces when the buffer fills or the process exits. Sync so each log
      # line flushes immediately and progress is visible in real time.
      STDOUT.sync = true

      Logger.new(
        STDOUT,
        level: @log_level,
        datetime_format: "%Y-%m-%d %H:%M:%S",
        progname: "exwiw",
        formatter: formatter,
      )
    end

    private def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = <<~BANNER
          exwiw #{Exwiw::VERSION}

          Usage: exwiw [SUBCOMMAND] [options]

          Subcommands:
            export    Generate INSERT/COPY SQL files (default when omitted).
            explain   Print EXPLAIN output for each extraction query to stdout.
                      For mongodb, set verbosity via EXWIW_MONGODB_EXPLAIN_VERBOSITY
                      or `explain_verbosity:` in config (queryPlanner (default,
                      no query is executed) | executionStats | allPlansExecution).
            schema    Maintain the schema config (generate | check | tidy) by
                      reading a live database, for applications that cannot be
                      loaded to generate it from their models. Requires --from-db;
                      mysql and postgresql only. `check` prints a JSON report and
                      exits 1 when the config needs work.
        BANNER
        opts.version = Exwiw::VERSION

        opts.on("-h", "--host=HOST", "Target database host") { |v| @database_host = v }
        opts.on("-p", "--port=PORT", "Target database port") { |v| @database_port = v }
        opts.on("-u", "--user=USERNAME", "Target database user") { |v| @database_user = v }
        opts.on("-o", "--output-dir=[DUMP_DIR_PATH]", "Output file path. default is dump/. Its contents are emptied before each export (export subcommand only)") do |v|
          v = v.end_with?("/") ? v[0..-2] : v
          @output_dir = File.expand_path(v)
        end
        opts.on("--schema-dir=SCHEMA_DIR_PATH", "Directory of schema JSON files. (or set schema_dir in the config file)") do |v|
          v = v.end_with?("/") ? v[0..-2] : v
          @schema_dir = File.expand_path(v)
        end
        opts.on("--from-db", "Read the schema from the database the connection options point at (schema subcommand only; mysql/postgresql). Required by `exwiw schema`.") { @from_db = true }
        opts.on("-c", "--config=CONFIG_FILE_PATH", "Path to the exwiw config YAML. Defaults to ./#{DEFAULT_CONFIG_PATHS.first} (or .#{File.extname(DEFAULT_CONFIG_PATHS.last)}) when present. CLI options take precedence; paths inside the file are resolved relative to the file.") do |v|
          @config_file_path = File.expand_path(v)
        end
        opts.on("-a", "--adapter=ADAPTER", "Database adapter: mysql, sqlite, postgresql, mongodb (aliases: mysql2, sqlite3)") { |v| @database_adapter = v }
        opts.on("--uri=URI", "Full MongoDB connection URI (mongodb:// or mongodb+srv://). mongodb adapter only; takes precedence over --host/--port/--user. TLS, replicaSet, authSource and credentials are read from the URI.") { |v| @connection_uri = v }
        opts.on("--database=DATABASE", "Target database name") { |v| @database_name = v }
        opts.on("--target-table=[TABLE]", "Target table for extraction. If omitted, dump all tables.") { |v| @target_table_name = v }
        opts.on("--target-collection=[COLLECTION]", "Alias of --target-table for the mongodb adapter.") { |v| @target_collection_name = v }
        opts.on("--ids=[IDS]", "Comma-separated list of identifiers. Required when --target-table is given.") { |v| @ids = v.split(',') }
        opts.on("--ids-field=[FIELD]", "Field on the target collection that --ids is matched against. Defaults to the primary key. (mongodb adapter only)") { |v| @ids_field = v }
        opts.on("--scope-column=[COLUMN]", "DEPRECATED. Filter every table by this shared global column (--ids are its values) instead of a single --target-table. SQL adapters only; mutually exclusive with --target-table. Prefer declaring a per-table `scope_column:` in the schema config and running with --target-table.") { |v| @scope_column = v }
        opts.on("--output-format=[FORMAT]", "Output format: insert (default) or copy (PostgreSQL only, export subcommand only)") { |v| @output_format = v }
        opts.on("--insert-only", "Do not generate DELETE SQL files (export subcommand only)") { @insert_only = true }
        opts.on("--after-insert-hook=PATH", "Path to a .rb or .sh post-processing hook executed after all insert/delete files are written (export subcommand only)") do |v|
          @after_insert_hook_path = File.expand_path(v)
        end
        opts.on("--parallel-workers=N", Integer, "Fork N workers for the MongoDB dump's parallel schedule (mongodb + export only; N>=2 enables it, default is serial). Output is byte-identical to serial; falls back to serial where fork is unavailable.") { |v| @parallel_workers = v }
        opts.on("--mongodb-query-timeout-ms=N", Integer, "Global server-enforced timeout (ms) for every MongoDB query (mongodb only). Aborts an accidentally heavy/unscoped query past the deadline. Overridden per collection by `query_timeout_ms` in the schema config.") { |v| @mongodb_query_timeout_ms = v }
        opts.on("--log-level=LEVEL", "Log level (debug, info). default is info") { |v| @log_level = v.to_sym }

        opts.on("--help", "Print this help") do
          @help = true
        end
      end
    end
  end
end

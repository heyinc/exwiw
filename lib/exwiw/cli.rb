# frozen_string_literal: true

require 'logger'
require 'optparse'
require 'pathname'

require 'json'
require 'yaml'

require 'exwiw'

module Exwiw
  class CLI
    KNOWN_SUBCOMMANDS = %w[export explain].freeze

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
      ids_column
      scope_column
    ].freeze

    # Database connection settings are environment-specific (and sometimes
    # secret-adjacent), so they must be passed via CLI/env, never the committed
    # config file. `adapter` is the one connection-ish key allowed in config.
    REJECTED_CONNECTION_KEYS = %w[host port user database uri password].freeze

    # Keys that only make sense for `export`. They are skipped when merging config
    # for `explain` so a shared config file does not trip validate_explain_only!.
    EXPORT_ONLY_CONFIG_KEYS = %w[output_dir output_format insert_only after_insert_hook].freeze

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

      @help = @argv.empty?

      @database_host = nil
      @database_port = nil
      @database_user = nil
      @database_password = ENV["DATABASE_PASSWORD"]
      @connection_uri = nil
      @output_dir = nil
      @schema_dir = nil
      @config_file_path = nil
      @database_adapter = nil
      @database_name = nil
      @target_table_name = nil
      @target_collection_name = nil
      @ids = []
      @ids_field = nil
      @ids_column = nil
      @scope_column = nil
      @output_format = nil
      @insert_only = nil
      @after_insert_hook_path = nil
      @parallel_workers = nil
      @cursor_parallel = nil
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
          cursor_parallel: @cursor_parallel,
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
        ).run
      end
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
      resolve_ids_column_alias!
      resolve_uri_option!
      validate_parallel_workers!
      validate_cursor_parallel!

      if @subcommand == "explain"
        validate_explain_only!
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
      config = config.reject { |k, _| EXPORT_ONLY_CONFIG_KEYS.include?(k) } if @subcommand == "explain"

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
      @ids_column ||= config["ids_column"]
      @scope_column ||= config["scope_column"]
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

    # `--ids-column` is the sql-adapter spelling of `--ids-field` (the mongodb
    # spelling). Both override which column/field `--ids` is matched against on
    # the target table; internally they fold into the single @ids_field carried
    # by DumpTarget. Mirror the --target-table/--target-collection split: each
    # flag is restricted to its adapter family and the two are mutually
    # exclusive. Runs after resolve_target_collection_alias! so
    # @target_table_name already reflects the collection alias.
    private def resolve_ids_column_alias!
      if @ids_field && @ids_column
        $stderr.puts "Specify only one of --ids-field and --ids-column"
        exit 1
      end

      if @ids_field && @database_adapter != "mongodb"
        $stderr.puts "--ids-field is only supported by the mongodb adapter (use --ids-column)"
        exit 1
      end

      if @ids_column
        sql_adapters = ["mysql", "postgresql", "sqlite"]
        unless sql_adapters.include?(@database_adapter)
          $stderr.puts "--ids-column is only supported by the sql adapters (use --ids-field)"
          exit 1
        end

        @ids_field = @ids_column
      end

      # --ids-field/--ids-column override the column --ids filters against on
      # the target table; meaningless without a target table to constrain.
      if @ids_field && !@target_table_name
        flag = @ids_column ? "--ids-column" : "--ids-field"
        $stderr.puts "--target-table is required when #{flag} is specified"
        exit 1
      end
    end

    # `--scope-column` switches to scope-column mode: every table is filtered by a
    # shared column (`--ids` are its values) instead of anchoring on one
    # `--target-table`. It is SQL-only and mutually exclusive with the single-target
    # flags. Runs after resolve_target_collection_alias! (so --target-collection is
    # already folded into @target_table_name) and before resolve_ids_column_alias!
    # so the clearer "cannot combine" message wins over the generic ids-column one.
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

      if @ids_field || @ids_column
        flag = @ids_column ? "--ids-column" : "--ids-field"
        $stderr.puts "--scope-column cannot be combined with #{flag}"
        exit 1
      end
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

    # `--parallel-workers` forks worker processes to serialize documents in
    # parallel — a mongodb-only, export-only knob (the dump's per-document
    # extended-JSON encoding is the bottleneck it parallelizes). Runs after the
    # adapter name is normalized so the family check is reliable. >1 enables
    # parallelism; 1 is the serial default.
    private def validate_parallel_workers!
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

    # `--cursor-parallel` upgrades the worker forks from serializing-only (which
    # leaves the BSON->Ruby cursor decode serial in the parent, capping the win at
    # ~1.1-1.4x) to fetching disjoint `_id` ranges with their own cursors — so the
    # decode is parallel too (measured ~3.4x@4 / ~5.5x@8). It is mongodb-only and
    # needs more than one worker to split the cursor across, so it requires
    # --parallel-workers > 1. The output is sorted by `_id` rather than natural
    # order (a still-equivalent re-import), which is why it is opt-in rather than
    # implied by --parallel-workers. Runs after the adapter name is normalized.
    private def validate_cursor_parallel!
      return unless @cursor_parallel

      if @database_adapter != "mongodb"
        $stderr.puts "--cursor-parallel is only supported by the mongodb adapter"
        exit 1
      end

      if @parallel_workers.nil? || @parallel_workers < 2
        $stderr.puts "--cursor-parallel requires --parallel-workers > 1 (it splits the collection's cursor across workers)"
        exit 1
      end
    end

    private def validate_explain_only!
      if @database_adapter == "mongodb"
        $stderr.puts "mongodb adapter is not yet supported by 'explain' subcommand"
        exit 1
      end

      rejected = []
      rejected << "--output-dir" unless @output_dir.nil?
      rejected << "--output-format" unless @output_format.nil?
      rejected << "--insert-only" unless @insert_only.nil?
      rejected << "--after-insert-hook" unless @after_insert_hook_path.nil?

      unless rejected.empty?
        $stderr.puts "The following options are not applicable in 'explain' subcommand: #{rejected.join(', ')}"
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
                      (not yet supported for the mongodb adapter)
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
        opts.on("--ids-column=[COLUMN]", "Column on the target table that --ids is matched against. Defaults to the primary key. (sql adapters only)") { |v| @ids_column = v }
        opts.on("--scope-column=[COLUMN]", "Filter every table by this shared column (--ids are its values) instead of a single --target-table. Tables lacking it are reached via belongs_to. SQL adapters only; mutually exclusive with --target-table.") { |v| @scope_column = v }
        opts.on("--output-format=[FORMAT]", "Output format: insert (default) or copy (PostgreSQL only, export subcommand only)") { |v| @output_format = v }
        opts.on("--insert-only", "Do not generate DELETE SQL files (export subcommand only)") { @insert_only = true }
        opts.on("--parallel-workers=N", Integer, "Serialize documents across N forked worker processes (mongodb adapter, export only). >1 speeds up large/embed-heavy dumps at the cost of more memory; 1 (default) is serial. Overrides EXWIW_MONGODB_PARALLEL_WORKERS.") { |v| @parallel_workers = v }
        opts.on("--cursor-parallel", "Also fetch each collection across forked workers (disjoint _id ranges), not just serialize (mongodb adapter, export only; requires --parallel-workers > 1). Parallelizes the cursor decode for a larger speedup, but emits JSONL sorted by _id rather than natural order. Overrides EXWIW_MONGODB_CURSOR_PARALLEL.") { @cursor_parallel = true }
        opts.on("--after-insert-hook=PATH", "Path to a .rb or .sh post-processing hook executed after all insert/delete files are written (export subcommand only)") do |v|
          @after_insert_hook_path = File.expand_path(v)
        end
        opts.on("--log-level=LEVEL", "Log level (debug, info). default is info") { |v| @log_level = v.to_sym }

        opts.on("--help", "Print this help") do
          @help = true
        end
      end
    end
  end
end

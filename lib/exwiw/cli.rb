# frozen_string_literal: true

require 'logger'
require 'optparse'
require 'pathname'

require 'json'

require 'exwiw'

module Exwiw
  class CLI
    KNOWN_SUBCOMMANDS = %w[dump explain].freeze

    def self.start(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup

      @subcommand =
        if !@argv.empty? && !@argv.first.start_with?("-") && KNOWN_SUBCOMMANDS.include?(@argv.first)
          @argv.shift
        else
          "dump"
        end

      @help = @argv.empty?

      @database_host = nil
      @database_port = nil
      @database_user = nil
      @database_password = ENV["DATABASE_PASSWORD"]
      @output_dir = nil
      @config_dir = nil
      @database_adapter = nil
      @database_name = nil
      @target_table_name = nil
      @target_collection_name = nil
      @ids = []
      @ids_field = nil
      @ids_column = nil
      @output_format = nil
      @insert_only = nil
      @after_insert_hook_path = nil
      @log_level = :info

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
      )

      dump_target = DumpTarget.new(
        table_name: @target_table_name,
        ids: @ids,
        ids_field: @ids_field,
      )

      logger = build_logger

      case @subcommand
      when "dump"
        Runner.new(
          connection_config: connection_config,
          output_dir: @output_dir,
          config_dir: @config_dir,
          dump_target: dump_target,
          output_format: @output_format,
          insert_only: @insert_only,
          after_insert_hook_path: @after_insert_hook_path,
          cli_options: build_cli_options_hash,
          logger: logger,
        ).run
      when "explain"
        ExplainRunner.new(
          connection_config: connection_config,
          config_dir: @config_dir,
          dump_target: dump_target,
          logger: logger,
          io: $stdout,
        ).run
      end
    end

    private def validate_options!
      resolve_target_collection_alias!
      resolve_ids_column_alias!

      if @subcommand == "explain"
        validate_explain_only!
      end

      if @database_adapter != "sqlite3"
        required_options = {
          "Target database host" => @database_host,
          "Target database port" => @database_port,
          "Target database name" => @database_name,
        }
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

      valid_adapters = ["mysql2", "postgresql", "sqlite3", "mongodb"]
      unless valid_adapters.include?(@database_adapter)
        $stderr.puts "Invalid adapter. Available options are: #{valid_adapters.join(', ')}"
        exit 1
      end

      if @subcommand == "dump"
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

      if @config_dir.nil?
        $stderr.puts "Config dir is required"
        exit 1
      end

      unless Dir.exist?(@config_dir)
        $stderr.puts "Config dir does not exist: #{@config_dir}"
        exit 1
      end

      if Dir.glob(File.join(@config_dir, "*.json")).empty?
        $stderr.puts "Config dir contains no .json files: #{@config_dir}"
        exit 1
      end

      if @target_table_name && @ids.empty?
        $stderr.puts "--ids is required when --target-table is specified"
        exit 1
      end

      if !@target_table_name && @ids.any?
        $stderr.puts "--target-table is required when --ids is specified"
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
        sql_adapters = ["mysql2", "postgresql", "sqlite3"]
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

    private def build_cli_options_hash
      {
        database_host: @database_host,
        database_port: @database_port,
        database_user: @database_user,
        database_password: @database_password,
        output_dir: @output_dir,
        config_dir: @config_dir,
        database_adapter: @database_adapter,
        database_name: @database_name,
        target_table: @target_table_name,
        ids: @ids.dup.freeze,
        ids_field: @ids_field,
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
            dump      Generate INSERT/COPY SQL files (default when omitted).
            explain   Print EXPLAIN output for each extraction query to stdout.
                      (not yet supported for the mongodb adapter)
        BANNER
        opts.version = Exwiw::VERSION

        opts.on("-h", "--host=HOST", "Target database host") { |v| @database_host = v }
        opts.on("-p", "--port=PORT", "Target database port") { |v| @database_port = v }
        opts.on("-u", "--user=USERNAME", "Target database user") { |v| @database_user = v }
        opts.on("-o", "--output-dir=[DUMP_DIR_PATH]", "Output file path. default is dump/ (dump subcommand only)") do |v|
          v = v.end_with?("/") ? v[0..-2] : v
          @output_dir = File.expand_path(v)
        end
        opts.on("-c", "--config-dir=CONFIG_DIR_PATH", "Config dir path.") do |v|
          v = v.end_with?("/") ? v[0..-2] : v
          @config_dir = File.expand_path(v)
        end
        opts.on("-a", "--adapter=ADAPTER", "Database adapter") { |v| @database_adapter = v }
        opts.on("--database=DATABASE", "Target database name") { |v| @database_name = v }
        opts.on("--target-table=[TABLE]", "Target table for extraction. If omitted, dump all tables.") { |v| @target_table_name = v }
        opts.on("--target-collection=[COLLECTION]", "Alias of --target-table for the mongodb adapter.") { |v| @target_collection_name = v }
        opts.on("--ids=[IDS]", "Comma-separated list of identifiers. Required when --target-table is given.") { |v| @ids = v.split(',') }
        opts.on("--ids-field=[FIELD]", "Field on the target collection that --ids is matched against. Defaults to the primary key. (mongodb adapter only)") { |v| @ids_field = v }
        opts.on("--ids-column=[COLUMN]", "Column on the target table that --ids is matched against. Defaults to the primary key. (sql adapters only)") { |v| @ids_column = v }
        opts.on("--output-format=[FORMAT]", "Output format: insert (default) or copy (PostgreSQL only, dump subcommand only)") { |v| @output_format = v }
        opts.on("--insert-only", "Do not generate DELETE SQL files (dump subcommand only)") { @insert_only = true }
        opts.on("--after-insert-hook=PATH", "Path to a .rb or .sh post-processing hook executed after all insert/delete files are written (dump subcommand only)") do |v|
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

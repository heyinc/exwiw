# frozen_string_literal: true

require "fileutils"

module Exwiw
  class Runner
    def initialize(
      connection_config:,
      output_dir:,
      schema_dir:,
      dump_target:,
      logger:,
      output_format: 'insert',
      insert_only: false,
      after_insert_hook_path: nil,
      cli_options: {}
    )
      @connection_config = connection_config
      @output_dir = output_dir
      @schema_dir = schema_dir
      @dump_target = dump_target
      @output_format = output_format
      @insert_only = insert_only
      @after_insert_hook_path = after_insert_hook_path
      @cli_options = cli_options
      @logger = logger
    end

    def run
      adapter = Adapter.build(@connection_config, @logger)
      configs = load_table_config(adapter.class.table_config_class)

      validate_ignored(configs)
      validate_rails_managed_target!(configs)

      table_by_name = configs.each_with_object({}) { |config, hash| hash[config.name] = config }

      target = table_by_name[@dump_target.table_name]
      validate_target_exists!(target)
      adapter.validate_as_dump_target!(target) if target

      dumpable_configs = configs.select { |c| adapter.dumpable?(c) }
      # Scope-column mode: abort if any extractable table cannot be scoped (no-op
      # otherwise). Done before extraction so nothing is dumped if it would leak.
      QueryAstBuilder.validate_scope!(dumpable_configs, table_by_name, @dump_target, @logger)
      # Hybrid mode (--target-table + --scope-column): abort on tables reachable by
      # neither anchor and on edges that would dangle (no-op otherwise).
      QueryAstBuilder.validate_hybrid!(dumpable_configs, table_by_name, @dump_target, @logger)
      # A per-table `scope_column` is meaningless without `--scope-column`; abort so
      # a misconfiguration is not silently ignored (no-op in scope/hybrid mode).
      QueryAstBuilder.validate_scope_column_usage!(dumpable_configs, @dump_target)

      @logger.info("Determining table processing order...")
      ordered_table_names = DetermineTableProcessingOrder.run(dumpable_configs, logger: @logger)

      clean_output_dir!

      ordered_tables = ordered_table_names.map { |n| table_by_name.fetch(n) }
      schema_path = File.join(@output_dir, "insert-000-schema.#{adapter.schema_output_extension}")
      @logger.info("Writing schema to #{schema_path}...")
      adapter.dump_schema(ordered_tables, schema_path)

      total_size = ordered_table_names.size
      ordered_table_names.each_with_index do |table_name, idx|
        table = table_by_name.fetch(table_name)

        if table.ignore
          @logger.info("Skipping data extraction for '#{table_name}' (ignore:true)")
          next
        end

        @logger.info("Processing table '#{table_name}'... (#{idx + 1}/#{total_size})")

        query_ast = adapter.build_query(table, @dump_target, table_by_name)

        # Track which phase we are in so that, if an error is raised while
        # turning the fetched rows into SQL/JSONL, the rescue below can report
        # both the failing step and the exact extraction query that produced the
        # data being processed.
        phase = "executing extraction query"
        begin
          results = adapter.execute(query_ast)
          record_num = results.size

          if record_num.zero?
            @logger.info("  No records matched. skip this table.")
            next
          end
          insert_idx = (idx + 1).to_s.rjust(3, '0')

          if @output_format == 'copy'
            phase = "generating COPY statement"
            @logger.debug("  Generate COPY statement...")
            copy_sql = adapter.to_copy_from_stdin(results, table)
            @logger.info("  Generated COPY statement for #{record_num} records.")

            File.open(File.join(@output_dir, "insert-#{insert_idx}-#{table_name}.#{adapter.output_extension}"), 'w') do |file|
              pre = adapter.pre_insert_sql(table)
              file.puts(pre) if pre
              file.puts(copy_sql)
              post = adapter.post_insert_sql(table)
              file.puts(post) if post
            end
          else
            phase = "generating INSERT statement"
            @logger.debug("  Generate INSERT statement...")
            # Let the adapter write the INSERT/JSONL output straight to the file
            # instead of building the whole table's output as one string first,
            # so only a bounded amount of serialized text is resident at a time —
            # important for large tables/collections whose one-shot output would
            # otherwise be held in full alongside the already-large result set.
            #
            # The chunk size falls back to the adapter's default when the table
            # config does not set one (SQL adapters: nil -> one statement, but
            # streamed in bounded buffers; MongoDB: a positive default so the
            # JSONL is chunked). #write_inserts emits bytes identical to the
            # previous inline chunk loop and returns the statement count.
            chunk_size = table.bulk_insert_chunk_size || adapter.default_bulk_insert_chunk_size

            statement_count = 0
            File.open(File.join(@output_dir, "insert-#{insert_idx}-#{table_name}.#{adapter.output_extension}"), 'w') do |file|
              pre = adapter.pre_insert_sql(table)
              file.puts(pre) if pre
              statement_count = adapter.write_inserts(file, results, table, chunk_size)
              file.print("\n")
              post = adapter.post_insert_sql(table)
              file.puts(post) if post
            end

            @logger.info("  Generated INSERT statement for #{record_num} records (#{statement_count} statement(s)).")
          end

          if adapter.supports_bulk_delete? && !@insert_only && !(table.respond_to?(:rails_managed?) && table.rails_managed?)
            phase = "generating DELETE statement"
            @logger.debug("  Generate DELETE statement...")
            delete_sql = adapter.to_bulk_delete(query_ast, table)
            if @logger.debug?
              @logger.debug("  Generated DELETE statement:\n#{delete_sql}")
            else
              @logger.info("  Generated DELETE statement.")
            end
            delete_idx = (total_size - idx).to_s.rjust(3, '0')
            File.open(File.join(@output_dir, "delete-#{delete_idx}-#{table_name}.#{adapter.output_extension}"), 'w') do |file|
              file.puts(delete_sql)
            end
          end
        rescue => e
          @logger.error("Error while #{phase} for table '#{table_name}' (#{idx + 1}/#{total_size}): #{e.class}: #{e.message}")
          @logger.error("  Extraction query that produced the data being processed:")
          @logger.error("    #{adapter.describe_query(query_ast)}")
          raise
        end
      end

      if @after_insert_hook_path
        @logger.info("Running after-insert hook: #{@after_insert_hook_path}")
        AfterInsertHook.run(
          path: @after_insert_hook_path,
          cli_options: @cli_options,
          output_dir: @output_dir,
          next_idx: total_size + 1,
          output_extension: adapter.output_extension,
          logger: @logger,
        )
      end
    end

    # Empty the output dir before writing so each export starts from a clean
    # slate and never mixes files from a previous run. Remove the contents
    # (including dotfiles) rather than the dir itself, preserving the dir's own
    # permissions/inode. The CLI is responsible for confirming this with the
    # user when running interactively.
    private def clean_output_dir!
      if Dir.exist?(@output_dir)
        entries = Dir.each_child(@output_dir).to_a
        unless entries.empty?
          @logger.info("Cleaning output dir #{@output_dir} (#{entries.size} entr#{entries.size == 1 ? 'y' : 'ies'})...")
          entries.each { |entry| FileUtils.rm_rf(File.join(@output_dir, entry)) }
        end
      else
        FileUtils.mkdir_p(@output_dir)
      end
    end

    private def load_table_config(klass)
      Dir[File.join(@schema_dir, "*.json")].map do |file|
        json = JSON.parse(File.read(file))
        # Drop belongs_tos/columns(fields) flagged ignore:true so they are not
        # considered during extraction. Done here (after loading from file)
        # rather than in `.from` so the schema generators keep the full config
        # and can preserve the ignored entries on regeneration.
        klass.from(json).reject_ignored_members!
      end
    end

    private def validate_ignored(configs)
      ignored_names = configs.select { |c| c.ignore }.map(&:name).to_set
      return if ignored_names.empty?

      configs.each do |config|
        next if config.ignore
        next unless config.respond_to?(:belongs_tos)

        dangling = config.belongs_tos.select { |rel| ignored_names.include?(rel.table_name) }
        next if dangling.empty?

        raise ArgumentError,
              "Table '#{config.name}' has belongs_to references to ignored table(s): " \
              "#{dangling.map(&:table_name).join(', ')}. " \
              "Remove the belongs_to entries or unset `ignore` on the referenced table."
      end

      if @dump_target.table_name && ignored_names.include?(@dump_target.table_name)
        raise ArgumentError,
              "--target-table '#{@dump_target.table_name}' is marked ignore:true and cannot be used as a dump target."
      end

      ignored_names.each { |n| @logger.info("Table '#{n}' is marked ignore:true (schema will be included, data extraction skipped)") }
    end

    # Reject a `--target-table` (or `--target-collection`) that does not match any
    # table/collection in the loaded schema. Without this a typo'd target silently
    # matched nothing and produced an empty dump with no indication of the mistake.
    # `target` is the looked-up config (nil when not found); a nil dump target
    # (dump-all / scope-column mode) is allowed through.
    #
    # TODO: this checks the loaded schema (schema_dir JSON), not the live DB
    # connection — a table that exists in the database but has no schema config
    # is still rejected here. We may instead want to verify existence against the
    # connection (would need a table-exists capability on each adapter). revisit.
    private def validate_target_exists!(target)
      return if @dump_target.table_name.nil?
      return unless target.nil?

      raise ArgumentError,
            "--target-table '#{@dump_target.table_name}' does not exist in the schema (#{@schema_dir})."
    end

    private def validate_rails_managed_target!(configs)
      return if @dump_target.table_name.nil?

      target = configs.find { |c| c.name == @dump_target.table_name }
      return if target.nil?
      return unless target.respond_to?(:rails_managed?) && target.rails_managed?

      raise ArgumentError,
            "--target-table '#{@dump_target.table_name}' is a Rails-managed table (type=#{target.type}) and cannot be used as a dump target."
    end
  end
end

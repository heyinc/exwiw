# frozen_string_literal: true

require "fileutils"

module Exwiw
  class Runner
    def initialize(
      connection_config:,
      output_dir:,
      config_dir:,
      dump_target:,
      logger:,
      output_format: 'insert',
      insert_only: false,
      after_insert_hook_path: nil,
      cli_options: {}
    )
      @connection_config = connection_config
      @output_dir = output_dir
      @config_dir = config_dir
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
      adapter.validate_as_dump_target!(target) if target

      @logger.info("Determining table processing order...")
      ordered_table_names = DetermineTableProcessingOrder.run(configs.select { |c| adapter.dumpable?(c) })

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
            chunk_size = table.bulk_insert_chunk_size
            chunks = chunk_size ? results.each_slice(chunk_size).to_a : [results]
            insert_sql = chunks.map { |chunk_rows| adapter.to_bulk_insert(chunk_rows, table) }.join("\n")

            @logger.info("  Generated INSERT statement for #{record_num} records (#{chunks.size} statement(s)).")
            File.open(File.join(@output_dir, "insert-#{insert_idx}-#{table_name}.#{adapter.output_extension}"), 'w') do |file|
              pre = adapter.pre_insert_sql(table)
              file.puts(pre) if pre
              file.puts(insert_sql)
              post = adapter.post_insert_sql(table)
              file.puts(post) if post
            end
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
      Dir[File.join(@config_dir, "*.json")].map do |file|
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

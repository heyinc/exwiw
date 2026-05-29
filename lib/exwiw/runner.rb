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

      validate_skipped(configs)
      validate_rails_managed_target!(configs)

      table_by_name = configs.each_with_object({}) { |config, hash| hash[config.name] = config }

      target = table_by_name[@dump_target.table_name]
      adapter.validate_as_dump_target!(target) if target

      @logger.info("Determining table processing order...")
      ordered_table_names = DetermineTableProcessingOrder.run(configs.select { |c| adapter.dumpable?(c) })

      if !Dir.exist?(@output_dir)
        FileUtils.mkdir_p(@output_dir)
      end

      ordered_tables = ordered_table_names.map { |n| table_by_name.fetch(n) }
      schema_path = File.join(@output_dir, "insert-000-schema.#{adapter.schema_output_extension}")
      @logger.info("Writing schema to #{schema_path}...")
      adapter.dump_schema(ordered_tables, schema_path)

      total_size = ordered_table_names.size
      ordered_table_names.each_with_index do |table_name, idx|
        table = table_by_name.fetch(table_name)

        if table.skip
          @logger.info("Skipping data extraction for '#{table_name}' (skip:true)")
          next
        end

        @logger.info("Processing table '#{table_name}'... (#{idx + 1}/#{total_size})")

        query_ast = adapter.build_query(table, @dump_target, table_by_name)
        results = adapter.execute(query_ast)
        record_num = results.size

        if record_num.zero?
          @logger.info("  No records matched. skip this table.")
          next
        end
        insert_idx = (idx + 1).to_s.rjust(3, '0')

        if @output_format == 'copy'
          @logger.debug("  Generate COPY statement...")
          copy_sql = adapter.to_copy_from_stdin(results, table)
          @logger.info("  Generated COPY statement for #{record_num} records.")

          File.open(File.join(@output_dir, "insert-#{insert_idx}-#{table_name}.#{adapter.output_extension}"), 'w') do |file|
            file.puts(copy_sql)
            post = adapter.post_insert_sql(table)
            file.puts(post) if post
          end
        else
          @logger.debug("  Generate INSERT statement...")
          chunk_size = table.bulk_insert_chunk_size
          chunks = chunk_size ? results.each_slice(chunk_size).to_a : [results]
          insert_sql = chunks.map { |chunk_rows| adapter.to_bulk_insert(chunk_rows, table) }.join("\n")

          @logger.info("  Generated INSERT statement for #{record_num} records (#{chunks.size} statement(s)).")
          File.open(File.join(@output_dir, "insert-#{insert_idx}-#{table_name}.#{adapter.output_extension}"), 'w') do |file|
            file.puts(insert_sql)
            post = adapter.post_insert_sql(table)
            file.puts(post) if post
          end
        end

        if adapter.supports_bulk_delete? && !@insert_only && !(table.respond_to?(:rails_managed?) && table.rails_managed?)
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

    private def load_table_config(klass)
      Dir[File.join(@config_dir, "*.json")].map do |file|
        json = JSON.parse(File.read(file))
        klass.from(json)
      end
    end

    private def validate_skipped(configs)
      skipped_names = configs.select { |c| c.skip }.map(&:name).to_set
      return if skipped_names.empty?

      configs.each do |config|
        next if config.skip
        next unless config.respond_to?(:belongs_tos)

        dangling = config.belongs_tos.select { |rel| skipped_names.include?(rel.table_name) }
        next if dangling.empty?

        raise ArgumentError,
              "Table '#{config.name}' has belongs_to references to skipped table(s): " \
              "#{dangling.map(&:table_name).join(', ')}. " \
              "Remove the belongs_to entries or unset `skip` on the referenced table."
      end

      if @dump_target.table_name && skipped_names.include?(@dump_target.table_name)
        raise ArgumentError,
              "--target-table '#{@dump_target.table_name}' is marked skip:true and cannot be used as a dump target."
      end

      skipped_names.each { |n| @logger.info("Table '#{n}' is marked skip:true (schema will be included, data extraction skipped)") }
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

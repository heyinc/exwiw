# frozen_string_literal: true

module Exwiw
  class ExplainRunner
    def initialize(
      connection_config:,
      config_dir:,
      dump_target:,
      logger:,
      io: $stdout
    )
      @connection_config = connection_config
      @config_dir = config_dir
      @dump_target = dump_target
      @logger = logger
      @io = io
    end

    def run
      adapter = Adapter.build(@connection_config, @logger)
      configs = load_table_config(adapter.class.table_config_class)
      configs = reject_and_validate_skipped(configs)

      table_by_name = configs.each_with_object({}) { |config, hash| hash[config.name] = config }

      target = table_by_name[@dump_target.table_name]
      adapter.validate_as_dump_target!(target) if target

      @logger.debug("Determining table processing order...")
      ordered_table_names = DetermineTableProcessingOrder.run(configs.select { |c| adapter.dumpable?(c) })

      total_size = ordered_table_names.size
      ordered_table_names.each_with_index do |table_name, idx|
        @logger.debug("Explaining '#{table_name}'... (#{idx + 1}/#{total_size})")
        table = table_by_name.fetch(table_name)

        query_ast = adapter.build_query(table, @dump_target, table_by_name)
        sql = adapter.compile_ast(query_ast)
        explain_text = adapter.explain(query_ast)

        @io.puts "-- [#{idx + 1}/#{total_size}] #{table_name}"
        @io.puts sql
        @io.puts
        @io.puts "-- EXPLAIN:"
        @io.puts explain_text
        @io.puts
      end
    end

    private def load_table_config(klass)
      Dir[File.join(@config_dir, "*.json")].map do |file|
        json = JSON.parse(File.read(file))
        klass.from(json)
      end
    end

    private def reject_and_validate_skipped(configs)
      skipped_names = configs.select { |c| c.skip }.map(&:name).to_set
      return configs if skipped_names.empty?

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

      skipped_names.each { |n| @logger.info("Skipping table '#{n}' (skip:true)") }
      configs.reject { |c| c.skip }
    end
  end
end

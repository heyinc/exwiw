# frozen_string_literal: true

module Exwiw
  class ExplainRunner
    def initialize(
      connection_config:,
      schema_dir:,
      dump_target:,
      logger:,
      io: $stdout
    )
      @connection_config = connection_config
      @schema_dir = schema_dir
      @dump_target = dump_target
      @logger = logger
      @io = io
    end

    def run
      adapter = Adapter.build(@connection_config, @logger)
      configs = load_table_config(adapter.class.table_config_class)
      validate_ignored(configs)

      table_by_name = configs.each_with_object({}) { |config, hash| hash[config.name] = config }

      target = table_by_name[@dump_target.table_name]
      adapter.validate_as_dump_target!(target) if target

      dumpable_configs = configs.select { |c| adapter.dumpable?(c) }
      QueryAstBuilder.validate_scope!(dumpable_configs, table_by_name, @dump_target, @logger)
      QueryAstBuilder.validate_target_scope!(dumpable_configs, table_by_name, @dump_target, @logger)

      @logger.debug("Determining table processing order...")
      ordered_table_names = DetermineTableProcessingOrder.run(dumpable_configs, logger: @logger)

      total_size = ordered_table_names.size
      ordered_table_names.each_with_index do |table_name, idx|
        table = table_by_name.fetch(table_name)
        if table.ignore
          @logger.debug("Skipping explain for '#{table_name}' (ignore:true)")
          next
        end

        @logger.debug("Explaining '#{table_name}'... (#{idx + 1}/#{total_size})")

        query_ast = adapter.build_query(table, @dump_target, table_by_name)
        sql = adapter.commented_sql(query_ast)
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
      Dir[File.join(@schema_dir, "*.json")].map do |file|
        json = JSON.parse(File.read(file))
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
    end
  end
end

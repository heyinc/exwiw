# frozen_string_literal: true

module Exwiw
  class ExplainRunner
    def initialize(
      connection_config:,
      schema_dir:,
      dump_target:,
      logger:,
      io: $stdout,
      explain_verbosity: nil
    )
      @connection_config = connection_config
      @schema_dir = schema_dir
      @dump_target = dump_target
      @logger = logger
      @io = io
      # mongodb-only; nil lets the adapter pick its safe default (queryPlanner).
      @explain_verbosity = explain_verbosity
    end

    def run
      adapter = Adapter.build(@connection_config, @logger)
      # explain executes nothing, so an adapter whose non-target scope is captured
      # at runtime (mongodb) has no parent ids to filter children by; ask it to
      # build placeholder scope filters so each query reflects the real dump.
      adapter.explain_scope_with_placeholders!
      configs = load_table_config(adapter.class.table_config_class)
      validate_ignored(configs)

      table_by_name = configs.each_with_object({}) { |config, hash| hash[config.name] = config }

      target = table_by_name[@dump_target.table_name]
      validate_target_exists!(target)
      adapter.validate_as_dump_target!(target) if target

      dumpable_configs = configs.select { |c| adapter.dumpable?(c) }
      QueryAstBuilder.validate_scope!(dumpable_configs, table_by_name, @dump_target, @logger)

      @logger.debug("Determining table processing order...")
      # Match the export's processing order (see Runner#run): mongodb orders a
      # reverse-scoped collection after its `via` referencers.
      ordered_table_names = DetermineTableProcessingOrder.run(
        dumpable_configs,
        logger: @logger,
        runtime_reverse_scope: adapter.is_a?(Adapter::MongodbAdapter),
      )

      total_size = ordered_table_names.size
      ordered_table_names.each_with_index do |table_name, idx|
        table = table_by_name.fetch(table_name)
        if table.ignore
          @logger.debug("Skipping explain for '#{table_name}' (ignore:true)")
          next
        end

        @logger.debug("Explaining '#{table_name}'... (#{idx + 1}/#{total_size})")

        query_ast = adapter.build_query(table, @dump_target, table_by_name)
        # describe_query is the adapter-agnostic "what query is this": the
        # commented SELECT for SQL adapters, the find description for mongodb.
        query_text = adapter.describe_query(query_ast)
        explain_text = adapter.explain(query_ast, verbosity: @explain_verbosity)

        @io.puts "-- [#{idx + 1}/#{total_size}] #{table_name}"
        @io.puts query_text
        @io.puts
        @io.puts "-- EXPLAIN:"
        @io.puts explain_text
        @io.puts

        explain_batch_scope(adapter, table, table_by_name)
      end
    end

    # For a table extracted in batches (see Exwiw::BatchedExtraction), also show
    # the query that resolves the ids the extraction is sliced by — the one part
    # of a batched export that is not visible in the query above. The per-batch
    # query itself is the query above with the scope filter replaced by a literal
    # id list, which explain cannot render faithfully: it resolves no ids, since
    # it executes no extraction SELECT.
    private def explain_batch_scope(adapter, table, table_by_name)
      batched = BatchedExtraction.build(
        adapter: adapter,
        table: table,
        dump_target: @dump_target,
        table_by_name: table_by_name,
        logger: @logger,
      )
      return if batched.nil?

      key_query_ast = batched.key_query_ast
      @io.puts batched.describe_plan
      @io.puts adapter.describe_query(key_query_ast)
      @io.puts
      @io.puts "-- EXPLAIN (batch_scope id set):"
      @io.puts adapter.explain(key_query_ast, verbosity: @explain_verbosity)
      @io.puts
    end

    private def load_table_config(klass)
      Dir[File.join(@schema_dir, "*.json")].map do |file|
        json = JSON.parse(File.read(file))
        begin
          klass.from(json).reject_ignored_members!
        rescue UnknownConfigKeyError => e
          # `.from` knows the table, not the file; point at the offending file.
          raise UnknownConfigKeyError, "#{file}: #{e.message}", e.backtrace
        end
      end
    end

    # Reject a `--target-table` (or `--target-collection`) absent from the loaded
    # schema; mirrors Runner#validate_target_exists! so explain and export fail the
    # same way on a typo. `target` is the looked-up config (nil when not found).
    #
    # TODO: same caveat as Runner#validate_target_exists! — this checks the schema
    # (schema_dir JSON), not the live DB connection; verifying against the
    # connection would need a table-exists capability on each adapter. revisit.
    private def validate_target_exists!(target)
      return if @dump_target.table_name.nil?
      return unless target.nil?

      raise ArgumentError,
            "--target-table '#{@dump_target.table_name}' does not exist in the schema (#{@schema_dir})."
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

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
      after_insert_hook_path: nil,
      parallel_workers: nil,
      cli_options: {}
    )
      @connection_config = connection_config
      @output_dir = output_dir
      @schema_dir = schema_dir
      @dump_target = dump_target
      @output_format = output_format
      @after_insert_hook_path = after_insert_hook_path
      @parallel_workers = parallel_workers
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

      @logger.info("Determining table processing order...")
      # runtime_reverse_scope: the mongodb adapter builds a reverse-scoped
      # collection's filter from ids captured while its `via` referencers were
      # dumped, so those referencers must be processed first. The SQL adapters
      # scope via subqueries and keep the historical belongs_to-only order
      # (which also keeps their INSERT output loadable in foreign-key order).
      ordered_table_names = DetermineTableProcessingOrder.run(
        dumpable_configs,
        logger: @logger,
        runtime_reverse_scope: adapter.is_a?(Adapter::MongodbAdapter),
      )

      clean_output_dir!

      # Opt-in MongoDB inter-collection fork parallelism (see
      # docs/mongodb-dump-parallelism-2x-notes.md). It is byte-identical to the
      # serial loop below — same filenames (the file index is taken over the same
      # full processing order) and same per-collection bytes — so it is a drop-in
      # replacement for the whole schema+inserts pass, after which the common
      # after-insert hook still runs. Everything before this point (validation,
      # scope check, ordering, output-dir clean) applies to both paths.
      if use_mongodb_parallel?(adapter, configs)
        dump_mongodb_parallel(configs, table_by_name)
        run_after_insert_hook(adapter, ordered_table_names.size)
        return
      end

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
        phase = "compiling row transforms (map/replace_with_fake_data)"
        begin
          # Ruby-side masking (map / replace_with_fake_data): wrap the streamed
          # results so rows are transformed as they are drained. nil (and thus
          # a byte-identical, cost-free run) when no column opts in; covers
          # both the INSERT and COPY branches below.
          row_transformer = RowTransformer.build(table)

          # `batch_scope` splits the extraction into one query per slice of the
          # scope's id set, streaming rows like any adapter result. `query_ast`
          # stays the unbatched query — the error message below describes that
          # one.
          phase = "resolving the batch_scope id set"
          batched = BatchedExtraction.build(
            adapter: adapter,
            table: table,
            dump_target: @dump_target,
            table_by_name: table_by_name,
            logger: @logger,
          )
          batched&.prepare!

          phase = "executing extraction query"
          results = batched || adapter.execute(query_ast)
          results = row_transformer.wrap(results) if row_transformer
          insert_idx = (idx + 1).to_s.rjust(3, '0')

          if @output_format == 'copy'
            # COPY mode (PostgreSQL only) builds the whole body up front rather
            # than streaming, so it keeps the explicit count + early skip.
            record_num = results.size
            if record_num.zero?
              @logger.info("  No records matched. skip this table.")
              next
            end
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
            # previous inline chunk loop and returns [statement_count, record_num].
            #
            # The row count comes from this single streaming pass, so empty
            # tables are detected here (and the just-opened file removed) rather
            # than via a separate upfront count query — eliminating a redundant
            # second scan of the same filter (e.g. MongoDB count_documents / SQL
            # SELECT COUNT(*)), which is a full COLLSCAN for an unindexed scope.
            chunk_size = table.bulk_insert_chunk_size || adapter.default_bulk_insert_chunk_size

            insert_path = File.join(@output_dir, "insert-#{insert_idx}-#{table_name}.#{adapter.output_extension}")
            statement_count = 0
            record_num = 0
            File.open(insert_path, 'w') do |file|
              pre = adapter.pre_insert_sql(table)
              file.puts(pre) if pre
              statement_count, record_num = adapter.write_inserts(file, results, table, chunk_size)
              file.print("\n")
              post = adapter.post_insert_sql(table)
              file.puts(post) if post
            end

            if record_num.zero?
              File.delete(insert_path)
              @logger.info("  No records matched. skip this table.")
              next
            end

            @logger.info("  Generated INSERT statement for #{record_num} records (#{statement_count} statement(s)).")
          end
        rescue => e
          @logger.error("Error while #{phase} for table '#{table_name}' (#{idx + 1}/#{total_size}): #{e.class}: #{e.message}")
          @logger.error("  Extraction query that produced the data being processed:")
          @logger.error("    #{adapter.describe_query(query_ast)}")
          raise
        end
      end

      run_after_insert_hook(adapter, total_size)
    end

    # Run the post-processing hook (no-op when none configured). `total_size` is
    # the count of processed tables/collections; the hook's first output file is
    # numbered just past them. Shared by the serial and parallel dump paths.
    private def run_after_insert_hook(adapter, total_size)
      return unless @after_insert_hook_path

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

    # True when the opt-in MongoDB fork-parallel dump should run instead of the
    # serial loop: the mongodb adapter, a worker count > 1, a genuine-anchor dump
    # target (the schedule is built around the scoped DAG), and a runtime that can
    # fork. Anything else falls back to the serial path (warning when the user
    # explicitly asked for parallelism but it cannot apply).
    private def use_mongodb_parallel?(adapter, configs)
      return false unless adapter.is_a?(Adapter::MongodbAdapter)
      return false unless @parallel_workers && @parallel_workers > 1

      if @dump_target.table_name.nil?
        @logger.warn("--parallel-workers ignored: MongoDB parallelism needs a --target-collection; running serially.")
        return false
      end

      # A reverse-scoped collection consumes @state captured from its `via`
      # referencers, an ordering constraint the parallel schedule (built around
      # the belongs_to DAG only) does not express yet — a worker could dump the
      # collection before its arms and silently drop rows. Run serially instead.
      if configs.any? { |c| c.respond_to?(:reverse_scope) && c.reverse_scope&.via&.any? }
        @logger.warn("--parallel-workers ignored: reverse_scope collections require the serial processing order; running serially.")
        return false
      end

      unless MongodbParallelDumper.available?
        @logger.warn("--parallel-workers ignored: fork is unavailable on this runtime; running serially.")
        return false
      end

      true
    end

    # Build the static plan and hand the whole schema+inserts pass to the fork
    # orchestrator. `configs` are the reject_ignored_members!'d configs (the plan
    # rejects embedded and orders them itself, identically to the serial path).
    private def dump_mongodb_parallel(configs, table_by_name)
      plan = MongodbParallelPlan.new(
        configs: configs,
        target_table_name: @dump_target.table_name,
        logger: @logger,
      )
      @logger.info(
        "MongoDB parallel dump with #{@parallel_workers} worker(s): " \
        "genuine=#{plan.genuine.size}, leaves=#{plan.leaves.size}, ref_bt=#{plan.ref_bt.size}."
      )
      stats = MongodbParallelDumper.new(
        connection_config: @connection_config,
        plan: plan,
        dump_target: @dump_target,
        table_by_name: table_by_name,
        output_dir: @output_dir,
        workers: @parallel_workers,
        logger: @logger,
      ).run
      @logger.info("MongoDB parallel dump complete: #{stats.inspect}")
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
        begin
          klass.from(json).reject_ignored_members!
        rescue UnknownConfigKeyError => e
          # `.from` knows the table, not the file; point at the offending file.
          raise UnknownConfigKeyError, "#{file}: #{e.message}", e.backtrace
        end
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

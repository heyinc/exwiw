# frozen_string_literal: true

module Exwiw
  # Extracts one table as a series of queries, each constrained to a slice of the
  # scope's id set, for a table configured with `batch_scope` (see {BatchScope}).
  #
  # The problem it solves is a *plan* problem, not a volume problem. A scoped
  # extraction of a table reached through a `belongs_to` hop compiles to
  #
  #   SELECT activities.* FROM activities
  #     JOIN customers ON activities.customer_id = customers.id
  #                   AND customers.tenant_id IN ('t1')
  #
  # which is index-driven while the scope keeps few customers. Past some number
  # the planner's estimate of "probe the foreign-key index once per customer"
  # exceeds its estimate of "scan the table once", and it switches to a full scan
  # of a table that may hold hundreds of millions of rows — for a result set that
  # is a small fraction of it. The scan then exceeds the server's
  # `statement_timeout` (or runs for hours), and no filter on the extracted table
  # fixes it: a predicate that reduces the *output* does not reduce the *work*
  # once the plan is a scan.
  #
  # So instead of persuading the planner, this removes the choice. The batch
  # table's in-scope primary keys are resolved once, and the extraction runs one
  # query per `size`-sized slice of them, each carrying `customers.id IN (<ids>)`
  # in place of the scope filter. An explicit id list of that size is exactly
  # estimated and selective, so the foreign-key index is unambiguously the
  # cheapest plan for every batch; total work is proportional to the rows the
  # table actually keeps rather than to the table's size.
  #
  # Rows are identical to the unbatched query's, in a different order (batch by
  # batch). The slices partition the id set — each id appears in exactly one
  # batch — so no row is dropped or emitted twice; #each streams them as one
  # continuous sequence, so the Runner's row transforms, chunked INSERT writing
  # and empty-table skip all work unchanged. Which rows a batch may keep is
  # enforced by QueryAstBuilder#batch_scope_terminus!, which rejects a scoping
  # shape whose rows are not all selected through the batch table.
  class BatchedExtraction
    include Enumerable

    # The batch table's config: the scoped table whose in-scope primary keys
    # slice the extraction.
    attr_reader :terminus

    # A BatchedExtraction for `table`, or nil when it is not configured for one.
    # Raises ArgumentError when `batch_scope` is configured but the table's
    # scoping shape cannot be sliced by it (see #batch_scope_terminus!), so a
    # misconfiguration surfaces before any extraction runs.
    def self.build(adapter:, table:, dump_target:, table_by_name:, logger:)
      return nil unless table.respond_to?(:batch_scope) && table.batch_scope

      new(
        adapter: adapter,
        table: table,
        dump_target: dump_target,
        table_by_name: table_by_name,
        logger: logger,
      )
    end

    def initialize(adapter:, table:, dump_target:, table_by_name:, logger:)
      @adapter = adapter
      @table = table
      @dump_target = dump_target
      @table_by_name = table_by_name
      @logger = logger
      @terminus = QueryAstBuilder
        .new(table.name, table_by_name, dump_target, logger)
        .batch_scope_terminus!
    end

    def batch_size
      @table.batch_scope.batch_size
    end

    # The batch table's own extraction query, projected to its primary key: the
    # ids this extraction is sliced by. Reusing that query is what keeps the
    # batches faithful to the scope — the batch table is narrowed by exactly the
    # filter it would carry in the unbatched query. The primary key is projected
    # as a plain column so masking configured on it cannot corrupt the ids.
    def key_query_ast
      @key_query_ast ||= begin
        scoped = QueryAstBuilder.run(@terminus.name, @table_by_name, @dump_target, @logger)

        QueryAst::Select.new.tap do |ast|
          ast.from(scoped.from_table_name)
          ast.select([TableColumn.from_symbol_keys(name: @terminus.primary_key)])
          scoped.join_clauses.each { |join_clause| ast.join(join_clause) }
          scoped.where_clauses.each { |where_clause| ast.where(where_clause) }
        end
      end
    end

    # The extraction query for one batch.
    def batch_query_ast(ids)
      QueryAstBuilder.run(@table.name, @table_by_name, @dump_target, @logger, batch_ids: ids)
    end

    # Resolve the id set and log the plan, before extraction starts. Separated
    # from #each so the id-set query's cost (and an empty id set) is reported
    # where it happens rather than inside the streaming pass.
    def prepare!
      if key_ids.empty?
        @logger.info("  No in-scope #{@terminus.name} ids to batch by; extracting nothing.")
      else
        @logger.info(
          "  Extracting in #{batch_count} batch(es) of up to #{batch_size} " \
          "#{@terminus.name}.#{@terminus.primary_key} value(s) (#{key_ids.size} in scope)."
        )
      end
      self
    end

    # The batch table's in-scope primary keys, fetched once. Held in memory for
    # the whole extraction: the id set belongs to a single scope (one tenant's
    # rows of one table), which is orders of magnitude smaller than the batched
    # table itself, and the connection must be free for the per-batch queries.
    def key_ids
      @key_ids ||= @adapter.execute(key_query_ast).map(&:first)
    end

    def batch_count
      (key_ids.size + batch_size - 1) / batch_size
    end

    # Stream every batch's rows as one sequence.
    def each
      return enum_for(:each) unless block_given?

      extracted = 0
      key_ids.each_slice(batch_size).with_index do |ids, idx|
        rows = 0
        @adapter.execute(batch_query_ast(ids)).each do |row|
          rows += 1
          yield row
        end
        extracted += rows
        @logger.info("  Batch #{idx + 1}/#{batch_count}: #{rows} record(s), #{extracted} so far.")
      end

      self
    end

    # Total rows across every batch. Only the COPY output format needs the count
    # up front (the INSERT path tallies rows as it streams), and each batch
    # answers it with its own count query, so this deliberately stays lazy.
    def size
      @size ||= key_ids.each_slice(batch_size).sum { |ids| @adapter.execute(batch_query_ast(ids)).size }
    end
    alias length size

    # One-line description of the plan, for `exwiw explain` (which resolves no
    # ids, so it cannot show a batch's literal id list).
    def describe_plan
      "-- batch_scope: extracted in batches of up to #{batch_size} #{@terminus.name}." \
        "#{@terminus.primary_key} value(s). Each batch runs the query above with " \
        "`#{@terminus.name}.#{@terminus.primary_key} IN (<batch ids>)` in place of the scope filter, " \
        "over the ids of:"
    end
  end
end

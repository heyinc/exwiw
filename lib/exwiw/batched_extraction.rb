# frozen_string_literal: true

module Exwiw
  # Extracts a table configured with `batch_scope` as one query per slice of the
  # scope's id set, so each query stays index-driven instead of degrading into a
  # full scan. Rows are the unbatched query's, in batch order; the slices
  # partition the id set, so none is dropped or repeated. See README.md.
  class BatchedExtraction
    include Enumerable

    attr_reader :terminus

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

    # The batch table's own extraction query projected to its primary key, so the
    # ids are narrowed by exactly the filter the unbatched query would carry. The
    # key is a plain column so masking configured on it cannot corrupt the ids.
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

    def batch_query_ast(ids)
      QueryAstBuilder.run(@table.name, @table_by_name, @dump_target, @logger, batch_ids: ids)
    end

    # Resolve the id set and log the plan before extraction starts, so its cost
    # (and an empty id set) is reported where it happens rather than mid-stream.
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

    # Drained in full rather than streamed: the connection has to be free for the
    # per-batch queries. One scope's primary keys, so far smaller than the table.
    # Sorted here, not via ORDER BY — the id-set query stays cheap on the source
    # DB (no sort node spilling at whale scale), and the array is in memory
    # anyway. Any total order makes batch composition, and so the dump,
    # reproducible run to run.
    def key_ids
      @key_ids ||= @adapter.execute(key_query_ast).map(&:first).sort
    end

    def batch_count
      (key_ids.size + batch_size - 1) / batch_size
    end

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

    # Only the COPY output format needs the count up front, and each batch answers
    # it with its own count query, so this stays lazy.
    def size
      @size ||= key_ids.each_slice(batch_size).sum { |ids| @adapter.execute(batch_query_ast(ids)).size }
    end
    alias length size

    def describe_plan
      "-- batch_scope: extracted in batches of up to #{batch_size} #{@terminus.name}." \
        "#{@terminus.primary_key} value(s). Each batch runs the query above with " \
        "`#{@terminus.name}.#{@terminus.primary_key} IN (<batch ids>)` in place of the scope filter, " \
        "over the ids of:"
    end
  end
end

# frozen_string_literal: true

require "stringio"

module Exwiw
  # Builds the statements (SQL UPDATEs, or `bulkWrite`s for MongoDB) that mask chosen rows of one table in place with
  # the masks declared for export. #run writes them as text (lines of canonical Extended JSON for MongoDB) and only
  # reads the database; #apply hands them to the caller to execute.
  class MaskUpdateRunner
    class Error < ArgumentError; end

    CHUNK_SIZE = 1_000

    # What `MaskUpdateRunner#run` returns: the rows found (`target_count`), the columns (MongoDB: field paths) the
    # statements set, and the given primary keys with no row.
    Summary = Data.define(:table_name, :target_count, :columns, :missing_primary_key_values) do
      # Sums up the summaries of runs on the same table, e.g. one per batch; columns come from the schema, so any
      # non-empty one will do (a run with no ids reports none).
      #
      # @param table_name [String]
      # @param summaries [Array<Summary>] possibly none
      # @return [Summary]
      def self.merge(table_name, summaries)
        checked = summaries.find { |s| !s.columns.empty? }
        new(
          table_name: table_name,
          target_count: summaries.sum(&:target_count),
          columns: checked&.columns || [],
          missing_primary_key_values: summaries.flat_map(&:missing_primary_key_values),
        )
      end
    end

    # @param source [Exwiw::DataSource] the database to read
    # @param schema [Exwiw::Schema] the loaded schema configs
    # @param dump_target [Exwiw::DumpTarget] `table_name` and `ids` (default ID space) name the rows to mask by primary key
    # @param logger [Logger]
    # @param io [#puts] where #run writes the statements
    # @param extra_assignments [Hash{String => Object}] columns (fields) set to a fixed value on every row found, unless
    #   masked, e.g. updated_at (for SQL a Time is written in its own zone without an offset)
    def initialize(
      source:,
      schema:,
      dump_target:,
      logger:,
      io: $stdout,
      extra_assignments: {}
    )
      @source = source
      @schema = schema
      @dump_target = dump_target
      @logger = logger
      @io = io
      @extra_assignments = extra_assignments.transform_keys(&:to_s)
    end

    # Reads the target rows and writes the statements that mask them to `io`.
    #
    # @return [Exwiw::MaskUpdateRunner::Summary]
    # @raise [Exwiw::MaskUpdateRunner::Error] when no statements can be generated, or dump_target uses `ids_field`, `scope_column` or another ID space
    def run
      adapter, statements, summary = generate
      # Nothing reaches `io` unless every statement is written, so a failure never leaves a script that masks only some rows.
      output = StringIO.new
      statements.each { |statement| adapter.write_mask_update(output, statement) }
      @io.write(output.string)
      summary
    end

    # Reads the target rows and yields each statement that masks them, once all are built, for the caller to execute.
    # Wrap the call in a transaction to make the masking all-or-nothing.
    #
    # @yieldparam statement [String, Exwiw::Adapter::MongodbAdapter::MaskUpdateBulkWrite] an SQL UPDATE, or a bulk write for the collection
    # @return [Exwiw::MaskUpdateRunner::Summary]
    # @raise [Exwiw::MaskUpdateRunner::Error] as #run does; nothing is yielded then
    def apply(&block)
      raise ArgumentError, "a block that executes each statement is required" unless block

      _adapter, statements, summary = generate
      statements.each(&block)
      summary
    end

    private def generate
      reject_unsupported_target!
      @schema.check_adapter!(@source.adapter_class)
      @logger.info("Applying schema profile '#{@schema.profile}'") if @schema.profile
      adapter = @source.build_adapter(@logger)
      table_by_name = @schema.table_by_name

      reason = @schema.mask_update_refusal(@dump_target.table_name)
      raise Error, reason if reason

      table = table_by_name[@dump_target.table_name.to_s]
      primary_key_values = normalize_primary_key_values(table, @dump_target.default_ids)
      columns = adapter.mask_update_columns(table, table_by_name)

      row_transformer = RowTransformer.build(table)
      statements = []
      record_count = 0
      missing = []
      primary_key_values.each_slice(CHUNK_SIZE) do |chunk|
        target = @dump_target.dup.tap { |t| t.ids = chunk }
        query_ast = adapter.build_query(table, target, table_by_name, self_ancestors: false)
        results = adapter.execute(query_ast)
        results = row_transformer.wrap(results) if row_transformer

        chunk_statements, found, not_found = adapter.mask_update_statements(results, table, chunk, @extra_assignments)
        statements.concat(chunk_statements)
        record_count += found
        missing.concat(not_found)
      end

      summary = Summary.new(
        table_name: table.name,
        target_count: record_count,
        columns: columns,
        missing_primary_key_values: missing,
      )
      [adapter, statements, summary]
    end

    private def normalize_primary_key_values(table, primary_key_values)
      values = Array(primary_key_values)
      raise Error, "no primary key values given for '#{table.name}'" if values.empty?

      values.each do |value|
        unless value.is_a?(Integer) || value.is_a?(String) || (defined?(::BSON::ObjectId) && value.is_a?(::BSON::ObjectId))
          raise Error, "primary key value #{value.inspect} for '#{table.name}' must be an Integer, a String or a BSON::ObjectId"
        end
        raise Error, "primary key values for '#{table.name}' must not contain an empty value" if value == ""
      end
      values.uniq
    end

    private def reject_unsupported_target!
      case @dump_target.mode
      when :primary_key then nil
      when :scope_column then raise Error, "mode: :scope_column is not supported: the ids must be primary keys"
      else raise Error, "mode is required: set mode: :primary_key (--mode=primary-key) to say the ids are primary keys"
      end
      if @dump_target.recursive?
        raise Error, "recursion is not supported yet: only the target table's rows are masked, so set recursive: false (--no-recursive)"
      end
      raise Error, "ids_field is not supported: rows are addressed by primary key" if @dump_target.ids_field
      raise Error, "scope_column is not supported: only one table's rows can be masked" if @dump_target.scope_column
      return if @dump_target.named_id_spaces.empty?

      raise Error, "ID spaces other than default (#{@dump_target.named_id_spaces.join(', ')}) are not supported"
    end
  end
end

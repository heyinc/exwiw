# frozen_string_literal: true

require "stringio"

module Exwiw
  # Builds the statements (SQL UPDATEs, or `bulkWrite`s for MongoDB) that mask chosen rows of one table in place with
  # the masks declared for export. #run writes them as text (lines of canonical Extended JSON for MongoDB) and only
  # reads the database; #apply hands them to the caller to execute.
  class MaskUpdateRunner
    class Error < ArgumentError; end

    CHUNK_SIZE = 1_000

    CREDENTIAL_NAME = MaskRules::CREDENTIAL_NAME

    # What `MaskUpdateRunner#run` returns: the rows found (`target_count`), the columns (MongoDB: field paths) the
    # statements set, the given primary keys with no row, and the credential-looking columns accepted by `allow_guessable_credential`.
    Summary = Data.define(:table_name, :target_count, :columns, :missing_primary_key_values, :allowed_guessable_columns)

    # What an adapter's `check_mask_update` returns: the columns (MongoDB: field paths) the statements will set, and the
    # credential-looking ones accepted by `allow_guessable_credential`.
    Checked = Data.define(:columns, :allowed_guessable_columns)

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

      table = table_by_name[@dump_target.table_name.to_s]
      raise Error, "table '#{@dump_target.table_name}' is not declared in the schema (#{@schema.dir})" if table.nil?

      validate_table!(table)
      primary_key_values = normalize_primary_key_values(table, @dump_target.default_ids)
      checked = adapter.check_mask_update(table, table_by_name)

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
        columns: checked.columns,
        missing_primary_key_values: missing,
        allowed_guessable_columns: checked.allowed_guessable_columns,
      )
      [adapter, statements, summary]
    end

    # A credential-looking column may only be masked to NULL or a cryptographically random SQL expression (the adapter's RANDOM_SECRET_PATTERNS): a constant, id-derived, fake or map value is guessable.
    #
    # @param table [Exwiw::MaskRules::Table] the table (collection) being masked, as its adapter describes it
    # @return [Array<String>] the "table.column" entries that needed `allow_guessable_credential`
    # @raise [Exwiw::MaskUpdateRunner::Error] for an unaccepted credential-looking column, or an `allow_guessable_credential` that guards nothing
    def self.check_credential_columns!(table)
      qualify = ->(paths) { paths.map { |path| "#{table.name}.#{path}" } }
      unaccepted = MaskRules.unaccepted_credentials(table)
      unless unaccepted.empty?
        raise Error,
              "#{qualify.(unaccepted).join(', ')} look like credentials but are not masked to NULL or a random value, so the value written would be " \
              "guessable; mask them with raw_sql \"NULL\" or a random expression such as gen_random_uuid()::text (PostgreSQL), " \
              "HEX(RANDOM_BYTES(16)) (MySQL) or hex(randomblob(16)) (SQLite), or set allow_guessable_credential: true on them"
      end

      stray = MaskRules.stray_guessable_allowances(table)
      return qualify.(MaskRules.guessable_credentials(table)) if stray.empty?

      raise Error,
            "#{qualify.(stray).join(', ')} set allow_guessable_credential, but are not credential-looking " \
            "columns masked to a guessable value; remove it"
    end

    # Why `table` cannot be masked in place at all, shared with the schema check, which skips such tables.
    #
    # @param table [Exwiw::TableConfig, Exwiw::MongodbCollectionConfig]
    # @return [String, nil] the reason, or nil when it can be masked
    def self.unmaskable_reason(table)
      if table.respond_to?(:type) && table.type == TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY
        return "table '#{table.name}' has a composite primary key, which is not supported"
      end
      return "table '#{table.name}' is declared ignore: true" if table.ignore
      if table.respond_to?(:rails_managed?) && table.rails_managed?
        return "table '#{table.name}' is rails-managed and declares no columns to mask"
      end
      return unless table.respond_to?(:embedded?) && table.embedded?

      "collection '#{table.name}' is embedded in '#{table.embedded_in.collection_name}'; " \
        "its masks apply through the parent collection's documents, so pass the parent instead"
    end

    private def validate_table!(table)
      reason = self.class.unmaskable_reason(table)
      raise Error, reason if reason
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

# frozen_string_literal: true

require "stringio"

module Exwiw
  # Writes the statements (SQL UPDATEs, or a mongosh script for MongoDB) that mask chosen rows of
  # one table in place with the masks declared for export. Only reads the database.
  class MaskUpdateRunner
    class Error < ArgumentError; end

    CHUNK_SIZE = 1_000

    CREDENTIAL_NAME = /password|digest|salt|secret|token|credential|encrypted|passcode|api_key|access_key/i

    # What `MaskUpdateRunner#run` returns: the rows found (`target_count`), the columns (MongoDB: field paths) the
    # statements set, the given primary keys with no row, and the credential-looking columns that needed an allowance.
    Summary = Data.define(:table_name, :target_count, :columns, :missing_primary_key_values, :allowed_constant_columns)

    # What an adapter's `check_mask_update` returns: the columns (MongoDB: field paths) the statements will set, and the
    # credential-looking ones that needed an allowance.
    Checked = Data.define(:columns, :allowed_constant_columns)

    # @param connection_config [Exwiw::ConnectionConfig] the database to read
    # @param schema_dir [String] directory of the schema config files
    # @param dump_target [Exwiw::DumpTarget] `table_name` and `ids` (default ID space) name the rows to mask by primary key
    # @param logger [Logger]
    # @param io [#puts] where the statements are written
    # @param allow_constant_columns [Array<String>] credential-looking "table.column"s the caller accepts masking to non-NULL
    # @param profiles [Array<String>] the declared schema profiles
    # @param profile [String, nil] the schema profile to apply
    def initialize(
      connection_config:,
      schema_dir:,
      dump_target:,
      logger:,
      io: $stdout,
      allow_constant_columns: [],
      profiles: [],
      profile: nil
    )
      @connection_config = connection_config
      @schema_dir = schema_dir
      @dump_target = dump_target
      @logger = logger
      @io = io
      @allow_constant_columns = Array(allow_constant_columns).map(&:to_s)
      @profiles = profiles
      @profile = profile
    end

    # Reads the target rows and writes the statements that mask them to `io`.
    #
    # @return [Exwiw::MaskUpdateRunner::Summary]
    # @raise [Exwiw::MaskUpdateRunner::Error] when no statements can be generated, or dump_target uses `ids_field`, `scope_column` or another ID space
    def run
      reject_unsupported_target!
      adapter = Adapter.build(@connection_config, @logger)
      table_by_name = load_table_config(adapter.class.table_config_class).to_h { |config| [config.name, config] }

      table = table_by_name[@dump_target.table_name.to_s]
      raise Error, "table '#{@dump_target.table_name}' is not declared in the schema (#{@schema_dir})" if table.nil?

      validate_table!(table)
      primary_key_values = normalize_primary_key_values(table, @dump_target.default_ids)
      # the ids are primary keys here even if the table declares a scope_column
      table = table.dup.tap { |t| t.scope_column = nil } if table.respond_to?(:scope_column=)
      table_by_name = table_by_name.merge(table.name => table)
      checked = adapter.check_mask_update(table, table_by_name, allow_constant_columns: @allow_constant_columns)

      row_transformer = RowTransformer.build(table)
      # Nothing reaches `io` unless every row is written, so a failure never leaves a script that masks only some rows.
      output = StringIO.new
      record_count = 0
      missing = []
      primary_key_values.each_slice(CHUNK_SIZE) do |chunk|
        target = @dump_target.dup.tap { |t| t.ids = chunk }
        query_ast = adapter.build_query(table, target, table_by_name, self_ancestors: false)
        results = adapter.execute(query_ast)
        results = row_transformer.wrap(results) if row_transformer

        _statement_count, found, not_found = adapter.write_mask_updates(output, results, table, chunk)
        record_count += found
        missing.concat(not_found)
      end
      @io.write(output.string)

      Summary.new(
        table_name: table.name,
        target_count: record_count,
        columns: checked.columns,
        missing_primary_key_values: missing,
        allowed_constant_columns: checked.allowed_constant_columns,
      )
    end

    # A credential-looking column may only be masked to NULL or a cryptographically random SQL expression (the adapter's RANDOM_SECRET_PATTERNS): a constant, id-derived, fake or map value is guessable.
    #
    # @param table_name [String] table (collection) being masked
    # @param masks [Array<Array(String, Boolean)>] each masked column or field path, and whether its mask is safe (raw_sql NULL, or a random-bytes expression)
    # @param allowed [Array<String>] "table.column" entries the caller accepts
    # @return [Array<String>] the "table.column" entries that needed `allowed`
    # @raise [Exwiw::MaskUpdateRunner::Error] for an unaccepted credential-looking column, or an `allowed` entry that guards nothing
    def self.check_credential_columns!(table_name, masks, allowed)
      guarded = masks.select { |path, safe| path.match?(CREDENTIAL_NAME) && !safe }.map { |path, _| "#{table_name}.#{path}" }
      unaccepted = guarded - allowed
      unless unaccepted.empty?
        raise Error,
              "#{unaccepted.join(', ')} look like credentials but are not masked to NULL or a random value, so the value written would be " \
              "guessable; mask them with raw_sql \"NULL\" or a random expression such as gen_random_uuid()::text (PostgreSQL), " \
              "HEX(RANDOM_BYTES(16)) (MySQL) or hex(randomblob(16)) (SQLite), or name them in allow_constant_columns"
      end

      stray = allowed - guarded
      return guarded if stray.empty?

      raise Error, "allow_constant_columns names #{stray.join(', ')}, which no credential-looking column of '#{table_name}' needs"
    end

    private def validate_table!(table)
      if table.respond_to?(:type) && table.type == TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY
        raise Error, "table '#{table.name}' has a composite primary key, which is not supported"
      end
      raise Error, "table '#{table.name}' is declared ignore: true" if table.ignore
      if table.respond_to?(:rails_managed?) && table.rails_managed?
        raise Error, "table '#{table.name}' is rails-managed and declares no columns to mask"
      end
      return unless table.respond_to?(:embedded?) && table.embedded?

      raise Error,
            "collection '#{table.name}' is embedded in '#{table.embedded_in.collection_name}'; " \
            "its masks apply through the parent collection's documents, so pass the parent instead"
    end

    private def normalize_primary_key_values(table, primary_key_values)
      values = Array(primary_key_values)
      raise Error, "no primary key values given for '#{table.name}'" if values.empty?

      values.each do |value|
        unless value.is_a?(Integer) || value.is_a?(String)
          raise Error, "primary key value #{value.inspect} for '#{table.name}' must be an Integer or a String"
        end
        raise Error, "primary key values for '#{table.name}' must not contain an empty value" if value == ""
      end
      values.uniq
    end

    private def load_table_config(klass)
      @logger.info("Applying schema profile '#{@profile}'") if @profile
      SchemaLoader.new(dir: @schema_dir, config_class: klass, profiles: @profiles, profile: @profile).load
    end

    private def reject_unsupported_target!
      if @dump_target.recursive
        raise Error, "recursion is not supported yet: only the target table's rows are masked, so set recursive: false (--no-recursive)"
      end
      raise Error, "ids_field is not supported: rows are addressed by primary key" if @dump_target.ids_field
      raise Error, "scope_column is not supported: only one table's rows can be masked" if @dump_target.scope_column
      return if @dump_target.named_id_spaces.empty?

      raise Error, "ID spaces other than default (#{@dump_target.named_id_spaces.join(', ')}) are not supported"
    end
  end
end

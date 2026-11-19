# frozen_string_literal: true

module Exwiw
  # Builds statements (SQL UPDATEs, or a mongosh script for MongoDB) that mask chosen rows of
  # one table in place with the masks declared for export. Only reads the database.
  class MaskUpdatePlan
    class Error < ArgumentError; end

    CHUNK_SIZE = 1_000

    CREDENTIAL_NAME = /password|digest|salt|secret|token|credential|encrypted|passcode|api_key|access_key/i

    # What `MaskUpdatePlan#summary` reports: the rows found (`target_count`), the columns (MongoDB: field paths) the
    # statements set, the given primary keys with no row, and the credential-looking columns that needed an allowance.
    Summary = Data.define(:table_name, :target_count, :columns, :missing_primary_key_values, :allowed_constant_columns)

    # What an adapter's `build_mask_update` returns: `statements` are the UPDATEs, one per row (MongoDB: `bulkWrite`
    # calls), and the other fields are what `Summary` reports.
    Generated = Data.define(:statements, :target_count, :columns, :missing_primary_key_values, :allowed_constant_columns)

    attr_reader :script, :summary

    # @param adapter [Exwiw::Adapter::Base] connected adapter; only reads
    # @param tables [Enumerable] loaded TableConfig / MongodbCollectionConfig objects
    # @param dump_target [Exwiw::DumpTarget] `table_name` and `ids` (default ID space) name the rows to mask by primary key
    # @param allow_constant_columns [Array<String>] credential-looking "table.column"s the caller accepts masking to non-NULL
    # @return [Exwiw::MaskUpdatePlan]
    # @raise [Exwiw::MaskUpdatePlan::Error] when no statements can be generated, or dump_target uses `ids_field`, `scope_column` or another ID space
    def self.build(adapter:, tables:, dump_target:, allow_constant_columns: [])
      reject_unsupported_target!(dump_target)
      table_by_name = (tables.respond_to?(:values) ? tables.values : tables.to_a).to_h { |t| [t.name, t] }
      table = table_by_name[dump_target.table_name.to_s]
      raise Error, "table '#{dump_target.table_name}' is not declared in the schema" if table.nil?

      validate_table!(table)
      values = normalize_primary_key_values(table, dump_target.default_ids)
      target = dump_target.dup.tap { |t| t.ids = values }

      generated = adapter.build_mask_update(
        table, target, table_by_name, allow_constant_columns: Array(allow_constant_columns).map(&:to_s)
      )
      new(table, generated)
    end

    def self.reject_unsupported_target!(dump_target)
      raise Error, "ids_field is not supported: rows are addressed by primary key" if dump_target.ids_field
      raise Error, "scope_column is not supported: only one table's rows can be masked" if dump_target.scope_column
      return if dump_target.named_id_spaces.empty?

      raise Error, "ID spaces other than default (#{dump_target.named_id_spaces.join(', ')}) are not supported"
    end
    private_class_method :reject_unsupported_target!

    # A credential-looking column may only be masked to NULL or a cryptographically random SQL expression (the adapter's RANDOM_SECRET_PATTERNS): a constant, id-derived, fake or map value is guessable.
    #
    # @param table_name [String] table (collection) being masked
    # @param masks [Array<Array(String, Boolean)>] each masked column or field path, and whether its mask is safe (raw_sql NULL, or a random-bytes expression)
    # @param allowed [Array<String>] "table.column" entries the caller accepts
    # @return [Array<String>] the "table.column" entries that needed `allowed`
    # @raise [Exwiw::MaskUpdatePlan::Error] for an unaccepted credential-looking column, or an `allowed` entry that guards nothing
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

    def self.validate_table!(table)
      if table.respond_to?(:type) && table.type == TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY
        raise Error, "table '#{table.name}' has a composite primary key, which is not supported"
      end
      raise Error, "table '#{table.name}' is declared ignore: true" if table.ignore
      if table.respond_to?(:rails_managed?) && table.rails_managed?
        raise Error, "table '#{table.name}' is rails-managed and declares no columns to mask"
      end
      raise Error, "table '#{table.name}' has no primary key, so its rows cannot be addressed" if table.primary_key.nil?
      return unless table.respond_to?(:embedded?) && table.embedded?

      raise Error,
            "collection '#{table.name}' is embedded in '#{table.embedded_in.collection_name}'; " \
            "its masks apply through the parent collection's documents, so pass the parent instead"
    end
    private_class_method :validate_table!

    def self.normalize_primary_key_values(table, primary_key_values)
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
    private_class_method :normalize_primary_key_values

    def initialize(table, generated)
      @script = generated.statements.join("\n")
      @summary = Summary.new(
        table_name: table.name,
        target_count: generated.target_count,
        columns: generated.columns,
        missing_primary_key_values: generated.missing_primary_key_values,
        allowed_constant_columns: generated.allowed_constant_columns,
      )
    end
  end
end

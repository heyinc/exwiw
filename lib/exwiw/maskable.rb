# frozen_string_literal: true

require "logger"

module Exwiw
  # Lets a model mask its own rows in place with the masks its exwiw schema declares, through the model's own
  # connection. Include Exwiw::Maskable::ActiveRecordModel or Exwiw::Maskable::MongoidDocument in the model (or
  # ApplicationRecord); nothing is added to a model that does not include one.
  module Maskable
    # What `mask_with_exwiw!` returns: the runner's summary, and the statements it executed (or, with `dry_run`, would
    # execute): SQL UPDATEs, or MongodbAdapter::MaskUpdateBulkWrite for MongoDB.
    Result = Data.define(:summary, :statements)

    # The schema for a model, from the process-wide cache. A model (or its base class or concern) may define the class
    # methods `exwiw_config_path` (the exwiw config file; ./exwiw.yml otherwise) and `exwiw_schema_dir` (the schema
    # directory, e.g. one per database; else the config file's `schema_dir`, else `schema` next to the config file).
    #
    # @param model [Class] the model being masked
    # @param source [Exwiw::DataSource]
    # @param profile [String, nil]
    # @return [Exwiw::Schema]
    def self.schema_for(model, source, profile)
      # Looked up rather than defaulted in ClassMethods, whose default would shadow a concern's `class_methods`.
      config_path = model.exwiw_config_path if model.respond_to?(:exwiw_config_path)
      schema_dir = model.exwiw_schema_dir if model.respond_to?(:exwiw_schema_dir)
      SchemaCache.shared.fetch(
        config_class: source.adapter_class.table_config_class, schema_dir: schema_dir&.to_s, profile: profile,
        config_path: config_path,
      )
    end

    # Builds the statements that mask the rows of `table_name` whose primary keys are `ids`.
    #
    # @param source [Exwiw::DataSource] the model's connection
    # @param table_name [String] the table (collection) to mask
    # @param ids [Array<Integer, String>] primary keys of the rows to mask
    # @param extra_assignments [Hash{String => Object}] columns (fields) set to a fixed value on every masked row
    # @param schema [Exwiw::Schema] the loaded schema
    # @param allow_constant_columns [Array<String>] credential-looking "table.column"s accepted as non-NULL masks
    # @param logger [Logger, nil]
    # @return [Array(Exwiw::MaskUpdateRunner::Summary, Array)] the summary and the statements, none executed
    # @raise [Exwiw::MaskUpdateRunner::Error] when the rows cannot be masked as declared
    def self.plan(source:, schema:, table_name:, ids:, extra_assignments:, allow_constant_columns:, logger:)
      if ids.empty?
        summary = MaskUpdateRunner::Summary.new(
          table_name: table_name, target_count: 0, columns: [], missing_primary_key_values: [], allowed_constant_columns: [],
        )
        return [summary, []]
      end

      statements = []
      summary = MaskUpdateRunner.new(
        source: source,
        schema: schema,
        dump_target: DumpTarget.new(table_name: table_name, ids: ids, mode: :primary_key, recursive: false),
        logger: logger || ::Logger.new(nil),
        allow_constant_columns: allow_constant_columns,
        extra_assignments: extra_assignments,
      ).apply { |statement| statements << statement }
      [summary, statements]
    end
  end
end

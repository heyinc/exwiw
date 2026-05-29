# frozen_string_literal: true

require "fileutils"
require "json"

module Exwiw
  class SchemaGenerator
    class MultipleDatabasesNotSupportedError < StandardError; end

    def self.from_rails_application(output_dir:)
      Rails.application.eager_load!
      new(models: ActiveRecord::Base.descendants, output_dir: output_dir)
    end

    def initialize(models:, output_dir:)
      @models = models
      @output_dir = output_dir
    end

    def generate!
      tables = build_tables
      write_files(tables)
      tables
    end

    def build_tables
      models = concrete_models
      validate_single_database!(models)

      tables_from_models = models.group_by(&:table_name).map do |table_name, model_group|
        representative = model_group.first
        TableConfig.from_symbol_keys(
          name: table_name,
          primary_key: representative.primary_key,
          belongs_tos: aggregate_belongs_tos(model_group),
          columns: representative.column_names.map { |name| { name: name } },
        )
      end

      tables_from_models + build_rails_managed_tables
    end

    def write_files(tables)
      FileUtils.mkdir_p(@output_dir)

      tables.each do |table|
        path = File.join(@output_dir, "#{table.name}.json")
        config_to_write =
          if File.exist?(path)
            TableConfig.from(JSON.parse(File.read(path))).merge(table)
          else
            table
          end
        File.write(path, JSON.pretty_generate(config_to_write.to_hash) + "\n")
      end
    end

    private def concrete_models
      @models.reject(&:abstract_class?).select(&:table_exists?)
    end

    private def build_rails_managed_tables
      conn = ActiveRecord::Base.connection
      result = []

      schema_migrations_name = ActiveRecord::Base.schema_migrations_table_name
      if conn.table_exists?(schema_migrations_name)
        result << TableConfig.from_symbol_keys(
          name: schema_migrations_name,
          type: TableConfig::RAILS_MANAGED_SCHEMA_MIGRATIONS,
          comment: "Managed internally by Rails. Tracks applied schema migrations.",
          belongs_tos: [],
          columns: [],
        )
      end

      internal_metadata_name = ActiveRecord::Base.internal_metadata_table_name
      if conn.table_exists?(internal_metadata_name)
        result << TableConfig.from_symbol_keys(
          name: internal_metadata_name,
          type: TableConfig::RAILS_MANAGED_INTERNAL_METADATA,
          comment: "Managed internally by Rails. Stores environment and schema metadata.",
          belongs_tos: [],
          columns: [],
        )
      end

      result
    end

    private def aggregate_belongs_tos(models)
      pairs = models
        .flat_map { |m| m.reflect_on_all_associations(:belongs_to) }
        .reject(&:polymorphic?) # XXX: Support polymorphic
        .map { |assoc| [assoc.table_name, assoc.foreign_key] }
        .uniq

      pairs.map do |table_name, foreign_key|
        { table_name: table_name, foreign_key: foreign_key }
      end
    end

    # `connection_specification_name` is a quasi-private API but has been stable
    # across Rails 6.1 - 8.x. With Rails multi-DB (`connects_to`), every
    # descendant of the same abstract base shares one spec name regardless of
    # role/shard, so distinct values across concrete models indicate genuinely
    # separate databases.
    private def validate_single_database!(models)
      return if models.empty?

      specs = models.map(&:connection_specification_name).uniq
      return if specs.size <= 1

      raise MultipleDatabasesNotSupportedError, <<~MSG
        exwiw does not yet support Rails multiple-database setup.
        Detected connection specifications: #{specs.inspect}
        Track progress at https://github.com/riseshia/exwiw/issues
      MSG
    end
  end
end

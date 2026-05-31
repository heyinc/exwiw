# frozen_string_literal: true

require "fileutils"
require "json"

module Exwiw
  class SchemaGenerator
    def self.from_rails_application(output_dir:)
      Rails.application.eager_load!
      new(models: ActiveRecord::Base.descendants, output_dir: output_dir)
    end

    def initialize(models:, output_dir:)
      @models = models
      @output_dir = output_dir
    end

    def generate!
      groups = build_table_groups
      write_groups(groups)
      groups
    end

    # Returns a Hash keyed by the database name.
    #
    # - Single-database setup: the only key is `nil`, signalling that the table
    #   configs should be written flat into `output_dir` (backwards compatible).
    # - Multi-database setup (Rails `connects_to`): one key per database
    #   (`connection_db_config.name`, e.g. "primary" / "analytics"), each
    #   mapping to that database's table configs. They are written into
    #   `output_dir/<db_name>/`.
    def build_table_groups
      models = concrete_models
      grouped = models.group_by { |model| database_name_for(model) }

      if grouped.size <= 1
        conn = models.empty? ? ActiveRecord::Base.connection : models.first.connection
        return { nil => build_tables_for(models, conn) }
      end

      grouped.each_with_object({}) do |(db_name, group_models), result|
        conn = group_models.first.connection
        result[db_name] = build_tables_for(group_models, conn)
      end
    end

    # Backwards-compatible flat list of all table configs. Only meaningful for
    # a single-database setup; for multi-database setups prefer
    # `#build_table_groups` so the database association is preserved.
    def build_tables
      build_table_groups.values.flatten
    end

    def write_groups(groups)
      groups.each do |db_name, tables|
        dir = db_name.nil? ? @output_dir : File.join(@output_dir, db_name)
        write_files(dir, tables)
      end
    end

    def write_files(dir, tables)
      FileUtils.mkdir_p(dir)

      tables.each do |table|
        path = File.join(dir, "#{table.name}.json")
        config_to_write =
          if File.exist?(path)
            TableConfig.from(JSON.parse(File.read(path))).merge(table)
          else
            table
          end
        File.write(path, JSON.pretty_generate(config_to_write.to_hash) + "\n")
      end
    end

    private def build_tables_for(models, conn)
      tables_from_models = models.group_by(&:table_name).map do |table_name, model_group|
        representative = model_group.first
        primary_key = representative.primary_key

        # Tables with a composite primary key (`representative.primary_key` is an
        # Array) are not supported yet. Emit them with `primary_key` omitted,
        # `skip: true`, and a `type` that marks them as unsupported — the `type`
        # acts as a signpost for adding support later. The config file itself is
        # still generated so a user can manually remove `skip` and wire it up when
        # needed.
        if primary_key.is_a?(Array)
          TableConfig.from_symbol_keys(
            name: table_name,
            type: TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY,
            skip: true,
            comment: "exwiw does not support composite primary keys " \
                     "(#{primary_key.join(', ')}); data extraction is skipped.",
            belongs_tos: aggregate_belongs_tos(model_group),
            columns: representative.column_names.map { |name| { name: name } },
          )
        else
          TableConfig.from_symbol_keys(
            name: table_name,
            primary_key: primary_key,
            belongs_tos: aggregate_belongs_tos(model_group),
            columns: representative.column_names.map { |name| { name: name } },
          )
        end
      end

      tables_from_models + build_rails_managed_tables(conn)
    end

    private def concrete_models
      @models.reject(&:abstract_class?).select(&:table_exists?)
    end

    # The rails-managed tables (`schema_migrations` / `ar_internal_metadata`)
    # have no model class, so they cannot be picked up from
    # `ActiveRecord::Base.descendants`. In a multi-DB setup each connection has
    # its own migration history table, so we take the target connection and only
    # emit an entry when the table actually exists on that connection. The table
    # name itself (including any prefix/suffix) comes from the global settings
    # (`ActiveRecord::Base.schema_migrations_table_name`, etc.).
    private def build_rails_managed_tables(conn)
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
      belongs_to_assocs = models.flat_map { |m| m.reflect_on_all_associations(:belongs_to) }

      non_polymorphic = belongs_to_assocs
        .reject(&:polymorphic?)
        .map { |assoc| { table_name: assoc.table_name, foreign_key: assoc.foreign_key } }

      # A polymorphic belongs_to (`belongs_to :reviewable, polymorphic: true`)
      # has no single target table. The candidate tables are found by looking up
      # the other models that declare `has_many/has_one ..., as: <association_name>`.
      # For each candidate table, expand one belongs_to entry carrying the type
      # column (`foreign_type`) and the stored type value (`type_value`).
      polymorphic = belongs_to_assocs
        .select(&:polymorphic?)
        .flat_map do |assoc|
          polymorphic_target_models(assoc.name).map do |target_model|
            {
              table_name: target_model.table_name,
              foreign_key: assoc.foreign_key,
              foreign_type: assoc.foreign_type,
              type_value: target_model.polymorphic_name,
            }
          end
        end

      (non_polymorphic + polymorphic).uniq
    end

    # Enumerate the concrete models that can be targets of the polymorphic
    # association `association_name`, by looking them up from every model's
    # `has_many` / `has_one` `as:` option. The order of `concrete_models` depends
    # on `ActiveRecord::Base.descendants`, which can vary by Ruby version, so sort
    # by `table_name` to return a deterministic order and keep the generated
    # belongs_to ordering stable.
    private def polymorphic_target_models(association_name)
      concrete_models.select do |model|
        (model.reflect_on_all_associations(:has_many) +
         model.reflect_on_all_associations(:has_one))
          .any? { |reflection| reflection.options[:as] == association_name }
      end.sort_by(&:table_name)
    end

    # Identifies which database a model belongs to. With Rails multi-DB
    # (`connects_to` backed by `database.yml`), `connection_db_config.name`
    # returns the configuration name ("primary", "analytics", ...) which is
    # stable across roles/shards and makes a natural per-database directory
    # name. Single-database apps all share one name, collapsing into one group.
    private def database_name_for(model)
      model.connection_db_config.name
    end
  end
end

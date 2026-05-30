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

        # 複合主キー (`representative.primary_key` が Array) のテーブルは現状未対応。
        # primary_key を省略し、type で非対応である旨を明示したうえで skip:true を
        # 付与して出力する。type を付けておくことで将来対応する際の目印になる。
        # 利用者が必要に応じて手動で skip を外して設定し直せるよう、設定ファイル
        # 自体は生成しておく。
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

    # rails-managed テーブル (`schema_migrations` / `ar_internal_metadata`) は
    # モデルクラスを持たないため `ActiveRecord::Base.descendants` からは拾えない。
    # multi-DB 構成では各 connection が独立した migration 履歴テーブルを持つので、
    # 対象 connection を受け取り、その connection 上に該当テーブルが存在する場合のみ
    # エントリを生成する。テーブル名そのものは prefix/suffix を含むグローバル設定
    # (`ActiveRecord::Base.schema_migrations_table_name` 等) から得る。
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
      pairs = models
        .flat_map { |m| m.reflect_on_all_associations(:belongs_to) }
        .reject(&:polymorphic?) # XXX: Support polymorphic
        .map { |assoc| [assoc.table_name, assoc.foreign_key] }
        .uniq

      pairs.map do |table_name, foreign_key|
        { table_name: table_name, foreign_key: foreign_key }
      end
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

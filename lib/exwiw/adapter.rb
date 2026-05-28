# frozen_string_literal: true

module Exwiw
  module Adapter
    class Base
      attr_reader :connection_config

      def initialize(connection_config, logger)
        @connection_config = connection_config
        @logger = logger
      end

      # The config class that this adapter consumes. Runner uses this to
      # decide which Serdes type to load scenario JSON into. SQL adapters
      # share the SQL-shaped TableConfig; non-SQL adapters override.
      def self.table_config_class
        TableConfig
      end

      # @params [Exwiw::TableConfig] table
      # @params [Exwiw::DumpTarget] dump_target
      # @params [Hash{String => Exwiw::TableConfig}] table_by_name
      # @return [Object] adapter-specific query object (e.g. Exwiw::QueryAst::Select for SQL)
      def build_query(table, dump_target, table_by_name)
        raise NotImplementedError
      end

      # File extension used for dump output (e.g. 'sql' for SQL, 'jsonl' for MongoDB).
      def output_extension
        'sql'
      end

      # File extension used for the leading `insert-000-schema.*` file.
      # SQL adapters emit `.sql` (CREATE TABLE IF NOT EXISTS ...);
      # MongodbAdapter overrides to `.js` (mongosh-runnable createCollection / createIndex).
      def schema_output_extension
        'sql'
      end

      # Write the leading schema-creation file for this adapter to `output_path`.
      # Default is a no-op; subclasses override to emit idempotent DDL so the
      # generated dump can be applied to an empty database.
      #
      # @param ordered_tables [Array] table configs in dependency order
      # @param output_path [String] absolute path to write to
      def dump_schema(ordered_tables, output_path)
      end

      # Whether this adapter emits delete-NNN-*.sql files.
      def supports_bulk_delete?
        true
      end

      # Whether the given config produces its own dump output and needs an
      # independent processing pass. SQL adapters always do; non-SQL adapters
      # may exclude e.g. embedded subdocument configs.
      def dumpable?(_config)
        true
      end

      # Hook for adapter-specific validation when this config is used as the
      # dump_target. Default: nothing to validate.
      def validate_as_dump_target!(_config)
      end

      # Optional SQL appended to the per-table insert-NNN-<table>.* file after
      # the bulk INSERT statements. Use to bring side-state in sync with the
      # explicit IDs that were just inserted (e.g. PostgreSQL sequences).
      # Default: nil (nothing appended).
      def post_insert_sql(_table)
        nil
      end

      def to_copy_from_stdin(_results, _table)
        raise NotImplementedError, "COPY format is not supported by #{self.class.name}"
      end

      # Run the database-specific EXPLAIN for the given query and return the
      # output as a single string for `explain` subcommand to print.
      # SQL adapters override; MongodbAdapter currently raises.
      def explain(_query_ast)
        raise NotImplementedError, "#{self.class.name} does not implement #explain"
      end

      # Identifier text prepended to every query exwiw sends to the (often
      # production) source DB, so the statement is recognizable in the
      # processlist / slow-query log / db.currentOp() and can be killed if it
      # runs long. e.g. "exwiw table=shops". `label` is "table=..." /
      # "collection=...". The version is intentionally omitted to keep the
      # comment stable across releases (snapshots / diffs). Strips `*/` to
      # avoid breaking out of the comment.
      def query_comment_text(label = nil)
        parts = ["exwiw"]
        parts << label if label
        parts.join(' ').gsub('*/', '')
      end

      # SQL block-comment form, prefixed to SELECT / EXPLAIN.
      def sql_query_comment(query_ast)
        label =
          if query_ast.respond_to?(:from_table_name) && query_ast.from_table_name
            "table=#{query_ast.from_table_name}"
          end
        "/* #{query_comment_text(label)} */"
      end

      # Comment-prefixed SELECT. Relies on the SQL adapter's #compile_ast
      # (dispatched to the subclass at runtime).
      def commented_sql(query_ast)
        "#{sql_query_comment(query_ast)} #{compile_ast(query_ast)}"
      end
    end

    # @params [Exwiw::QueryAst] query_ast
    def execute(query_ast)
      raise NotImplementedError
    end

    # @params [Array<Array<String>>] array of rows
    # @params [Exwiw::TableConfig] table
    def to_bulk_insert(results, table)
      raise NotImplementedError
    end

    # @params [Exwiw::QueryAst] select_query_ast
    # @params [Exwiw::TableConfig] table
    def to_bulk_delete(select_query_ast, table)
      raise NotImplementedError
    end

    def self.build(connection_config, logger)
      case connection_config.adapter
      when 'sqlite3'
        Adapter::Sqlite3Adapter.new(connection_config, logger)
      when 'mysql2'
        Adapter::Mysql2Adapter.new(connection_config, logger)
      when 'postgresql'
        Adapter::PostgresqlAdapter.new(connection_config, logger)
      when 'mongodb'
        Adapter::MongodbAdapter.new(connection_config, logger)
      else
        raise 'Unsupported adapter'
      end
    end
  end
end

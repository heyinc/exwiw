# frozen_string_literal: true

module Exwiw
  module Adapter
    # The adapter names exwiw uses internally. Deliberately driver-agnostic
    # (e.g. `mysql`, not `mysql2`) so they describe the database, not the Ruby
    # driver or Rails ActiveRecord adapter that happens to talk to it.
    CANONICAL_ADAPTERS = %w[mysql sqlite postgresql mongodb].freeze

    # Maps the older driver-flavored spellings onto exwiw's canonical adapter
    # name, so the CLI stays backward compatible (`--adapter=mysql2` still works)
    # and a Rails app's `connection.adapter_name` (e.g. "Mysql2", "SQLite") is
    # absorbed — lookup is case-insensitive (see .normalize_name).
    #
    # NOTE: this only normalizes the *name*; exwiw always connects with the
    # `mysql2` gem (see MysqlAdapter#connection). It is deliberately not aliased
    # from `trilogy`: a source app using the trilogy driver still needs the
    # `mysql2` gem available for exwiw to connect, so accepting `--adapter=trilogy`
    # would falsely imply trilogy support. Use `--adapter=mysql` in that case.
    ADAPTER_ALIASES = {
      "mysql2" => "mysql",
      "sqlite3" => "sqlite",
    }.freeze

    # Normalize an adapter name to its canonical form. Unknown names are passed
    # through (downcased) so the caller can reject them with a clear message.
    # Returns nil for nil input.
    def self.normalize_name(name)
      return nil if name.nil?

      key = name.to_s.downcase
      ADAPTER_ALIASES.fetch(key, key)
    end

    class Base
      attr_reader :connection_config

      # `parallel_workers` is an export-time serialization tuning knob, not a
      # connection setting: the MongodbAdapter uses it to fork worker processes
      # for the dump's dominant per-document encoding cost. It is nil for the SQL
      # adapters (they ignore it) and when unset (the adapter then falls back to
      # the EXWIW_MONGODB_PARALLEL_WORKERS env var). Threaded as explicit data
      # from the CLI rather than read from ENV here so the CLI flag is the single
      # user-facing control and SQL construction is unaffected.
      def initialize(connection_config, logger, parallel_workers: nil)
        @connection_config = connection_config
        @logger = logger
        @parallel_workers_option = parallel_workers
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

      # Optional SQL prepended to the per-table insert-NNN-<table>.* file before
      # the bulk INSERT/COPY statements. Use for session-level setup required
      # before loading data (e.g. MySQL FOREIGN_KEY_CHECKS).
      # Default: nil (nothing prepended).
      def pre_insert_sql(_table)
        nil
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

      # Write this table's bulk-insert output for `rows` straight to `io`.
      #
      # Default: serialize `rows` to a single String via #to_bulk_insert and
      # write it in one go — byte-for-byte what the Runner used to do with
      # `file.print(adapter.to_bulk_insert(...))`, so SQL adapters are
      # unaffected. The seam exists so an adapter whose per-row serialization is
      # the dump's bottleneck (MongoDB's extended-JSON encoding) can override it
      # to write directly to the output IO — e.g. concatenating the parts of a
      # fork-parallel serialization — without the Runner first materializing the
      # whole chunk as one String.
      #
      # `io` must be a real file-backed IO when an override streams external
      # parts into it (e.g. via IO.copy_stream); the default path works with any
      # IO including StringIO.
      def write_bulk_insert(io, rows, table)
        io.write(to_bulk_insert(rows, table))
      end

      # Default bulk-insert chunk size when a table config does not set one.
      # The Runner streams each chunk straight to the output file, so a non-nil
      # value here bounds how much serialized output (and how many transient
      # intermediate objects) live in memory at once. SQL adapters keep nil
      # (one statement per table, as before); adapters whose output is large
      # and built per-row (e.g. MongoDB JSONL) override with a positive value.
      def default_bulk_insert_chunk_size
        nil
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

      # One-line, human-readable description of the extraction query, used by the
      # Runner in error messages so a failure during INSERT/COPY generation (or
      # query execution) can be traced back to the query that produced the data.
      # SQL adapters expose the compiled, comment-prefixed SELECT; non-SQL
      # adapters (e.g. MongodbAdapter) override or fall back to the query object's
      # own inspect output. Best-effort: never raise from here, since it runs on
      # an error path.
      def describe_query(query_ast)
        if respond_to?(:compile_ast)
          commented_sql(query_ast)
        else
          query_ast.inspect
        end
      rescue => e
        "<unavailable: #{e.class}: #{e.message}>"
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

    def self.build(connection_config, logger, parallel_workers: nil)
      case normalize_name(connection_config.adapter)
      when 'sqlite'
        Adapter::SqliteAdapter.new(connection_config, logger, parallel_workers: parallel_workers)
      when 'mysql'
        Adapter::MysqlAdapter.new(connection_config, logger, parallel_workers: parallel_workers)
      when 'postgresql'
        Adapter::PostgresqlAdapter.new(connection_config, logger, parallel_workers: parallel_workers)
      when 'mongodb'
        Adapter::MongodbAdapter.new(connection_config, logger, parallel_workers: parallel_workers)
      else
        raise "Unsupported adapter: #{connection_config.adapter.inspect}"
      end
    end
  end
end

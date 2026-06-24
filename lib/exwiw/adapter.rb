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

      # Default bulk-insert chunk size when a table config does not set one.
      # The Runner streams each chunk straight to the output file, so a non-nil
      # value here bounds how much serialized output (and how many transient
      # intermediate objects) live in memory at once. SQL adapters keep nil
      # (one statement per table, as before); adapters whose output is large
      # and built per-row (e.g. MongoDB JSONL) override with a positive value.
      def default_bulk_insert_chunk_size
        nil
      end

      # Write the bulk INSERT/JSONL output for `results` to the open `io`,
      # returning the number of statements written. The Runner calls this once
      # per table for the non-COPY path.
      #
      # Default: build each chunk's output as a full string via #to_bulk_insert
      # and write it, separating statements with "\n" — exactly what the Runner
      # used to inline. This keeps the dominant memory cost at one chunk's
      # serialized string (bounded by `chunk_size`), which is why MongoDB sets a
      # positive default chunk size. Adapters whose output is a single large
      # statement (the SQL adapters, where chunk_size is nil) override this to
      # stream the statement to `io` in bounded buffers instead of holding the
      # whole thing in memory.
      #
      # @param io [IO] open output file
      # @param results [Enumerable] rows/documents from #execute
      # @param table the table/collection config
      # @param chunk_size [Integer, nil] rows per statement (nil => one statement)
      # @return [Array(Integer, Integer)] [statement_count, record_count]
      #
      # record_count is tallied from the rows actually streamed here so the
      # Runner no longer needs a separate upfront count query (MongoDB's
      # count_documents / the SQL adapters' SELECT COUNT(*)) just to log the row
      # count and decide whether an empty table can be skipped. That count was a
      # second full pass over the same filter — a wasted COLLSCAN when the scope
      # is unindexed; counting during the single streaming pass removes it.
      #
      # Batches rows by accumulating into a buffer and flushing every chunk_size
      # rows, rather than `results.each_slice(chunk_size)`. This is deliberate:
      # `Enumerable#each_slice` calls `#size` on the receiver as an allocation
      # hint, which for a streaming result (MongoDB's StreamingResult) issues a
      # `count_documents` — the very redundant count this single-pass design
      # removes. Driving the buffer off `#each` keeps the result's `#size`
      # untouched, so the cursor is walked exactly once. The chunk boundaries and
      # "\n" separators reproduce the each_slice output byte-for-byte.
      #
      # chunk_size is always positive for callers of this default (MongoDB); the
      # SQL adapters pass nil and override #write_inserts, so the unbounded
      # nil-branch buffer is never reached here in practice.
      def write_inserts(io, results, table, chunk_size)
        statement_count = 0
        record_count = 0
        buffer = []
        flush = lambda do
          io.print("\n") if statement_count.positive?
          io.print(to_bulk_insert(buffer, table))
          statement_count += 1
          record_count += buffer.size
          buffer.clear
        end
        results.each do |row|
          buffer << row
          flush.call if chunk_size && buffer.size >= chunk_size
        end
        flush.call unless buffer.empty?
        [statement_count, record_count]
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

      # Wrap a masking expression so a NULL source value stays NULL instead of
      # being clobbered into a non-NULL literal. The guard checks the masked
      # column itself (`column.name`) — not any other column the template may
      # reference — so only true NULL is preserved; an empty string is a real
      # value and is still masked. The column reference uses the same
      # `<from_table>.<col>` form as the Plain branch. Shared by the SQL
      # adapters' #compile_column_name ReplaceWith handling.
      private def null_preserving(ast, column, masked_expr)
        "CASE WHEN #{ast.from_table_name}.#{column.name} IS NOT NULL THEN #{masked_expr} ELSE NULL END"
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
      case normalize_name(connection_config.adapter)
      when 'sqlite'
        Adapter::SqliteAdapter.new(connection_config, logger)
      when 'mysql'
        Adapter::MysqlAdapter.new(connection_config, logger)
      when 'postgresql'
        Adapter::PostgresqlAdapter.new(connection_config, logger)
      when 'mongodb'
        Adapter::MongodbAdapter.new(connection_config, logger)
      else
        raise "Unsupported adapter: #{connection_config.adapter.inspect}"
      end
    end
  end
end

# frozen_string_literal: true

require_relative "exwiw/version"

require "json"
require "serdes"

require_relative "exwiw/ext_json"
require_relative "exwiw/config_file"
require_relative "exwiw/strict_keys"
require_relative "exwiw/belongs_to"
require_relative "exwiw/fake_data"
require_relative "exwiw/mask_value"
require_relative "exwiw/table_column"
require_relative "exwiw/reverse_scope"
require_relative "exwiw/batch_scope"
require_relative "exwiw/table_config"
require_relative "exwiw/embedded_in"
require_relative "exwiw/mongodb_field"
require_relative "exwiw/mongodb_collection_config"
require_relative "exwiw/ddl_postprocessor"
require_relative "exwiw/adapter/identifier_quoting"
require_relative "exwiw/adapter"
require_relative "exwiw/adapter/sql_bulk_insert"
require_relative "exwiw/adapter/sqlite_adapter"
require_relative "exwiw/adapter/mysql_client"
require_relative "exwiw/adapter/mysql_adapter"
require_relative "exwiw/adapter/postgresql_adapter"
require_relative "exwiw/adapter/mongodb_adapter"
require_relative "exwiw/determine_table_processing_order"
require_relative "exwiw/mongodb_parallel_plan"
require_relative "exwiw/mongodb_parallel_dumper"
require_relative "exwiw/mongo_query"
require_relative "exwiw/query_ast"
require_relative "exwiw/query_ast_builder"
require_relative "exwiw/row_transformer"
require_relative "exwiw/batched_extraction"
require_relative "exwiw/after_insert_hook"
require_relative "exwiw/runner"
require_relative "exwiw/explain_runner"
require_relative "exwiw/schema_generator"
require_relative "exwiw/mongoid_schema_generator"

begin
  require 'rails'
rescue LoadError
else
  require 'exwiw/railtie'
end

module Exwiw
  # `ids_field` optionally overrides which field `--ids` is matched against on
  # the target table. When nil the table's primary key is used (the historical
  # behavior). Currently only honored by the mongodb adapter.
  #
  # `scope_column` switches the extraction to scope-column mode: instead of a
  # single `table_name` anchor, every table is filtered by a shared column
  # (`scope_column IN ids`) and tables lacking it are reached by walking
  # belongs_to up to the nearest table that has it. When set, `table_name` is
  # nil. SQL adapters only.
  DumpTarget = Struct.new(:table_name, :ids, :ids_field, :scope_column, keyword_init: true)
  # `uri` is an optional full connection string (currently only honored by the
  # mongodb adapter, e.g. `mongodb+srv://...`). When present it is the source of
  # truth for the connection — host/port/user/password are ignored — so TLS,
  # replica_set, auth_source, etc. can be expressed via the URI's query string.
  #
  # `mongodb_query_timeout_ms` is the global, server-enforced operation timeout
  # (CSOT `timeout_ms`) applied to every MongoDB query exwiw issues — the find
  # cursor's whole lifetime, the count, and an executing `explain`. It guards
  # against an accidentally heavy/unscoped query pinning the (often production)
  # source: the server aborts the operation past the deadline. nil leaves it
  # unset (no timeout). A per-collection `query_timeout_ms` overrides it.
  # mongodb adapter only.
  ConnectionConfig = Struct.new(:adapter, :host, :port, :user, :password, :database_name, :uri, :mongodb_query_timeout_ms, keyword_init: true)
end

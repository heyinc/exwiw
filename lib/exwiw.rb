# frozen_string_literal: true

require_relative "exwiw/version"

require "json"
require "serdes"

require_relative "exwiw/belongs_to"
require_relative "exwiw/table_column"
require_relative "exwiw/table_config"
require_relative "exwiw/embedded_in"
require_relative "exwiw/mongodb_field"
require_relative "exwiw/mongodb_collection_config"
require_relative "exwiw/ddl_postprocessor"
require_relative "exwiw/adapter"
require_relative "exwiw/adapter/sqlite3_adapter"
require_relative "exwiw/adapter/mysql2_adapter"
require_relative "exwiw/adapter/postgresql_adapter"
require_relative "exwiw/adapter/mongodb_adapter"
require_relative "exwiw/determine_table_processing_order"
require_relative "exwiw/mongo_query"
require_relative "exwiw/query_ast"
require_relative "exwiw/query_ast_builder"
require_relative "exwiw/after_insert_hook"
require_relative "exwiw/runner"
require_relative "exwiw/schema_generator"

begin
  require 'rails'
rescue LoadError
else
  require 'exwiw/railtie'
end

module Exwiw
  DumpTarget = Struct.new(:table_name, :ids, keyword_init: true)
  ConnectionConfig = Struct.new(:adapter, :host, :port, :user, :password, :database_name, keyword_init: true)
end

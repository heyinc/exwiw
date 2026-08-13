# frozen_string_literal: true

require "mysql2"
require "pg"

require_relative "../../script/database_config"

# Shared plumbing for the specs that drive a real MySQL / PostgreSQL connection
# themselves — the DB-introspection ones. They need two things the rest of the
# suite does not: a ConnectionConfig built from the test database settings, and
# a way to apply fixture DDL to the same database the code under test reads.
module DbFixtures
  module_function

  def connection_config(adapter)
    config = database_config(adapter)
    Exwiw::ConnectionConfig.new(
      adapter: adapter.to_s,
      host: config[:host],
      port: config[:port],
      user: config[:username],
      password: config[:password],
      database_name: config[:database],
    )
  end

  # Run `sql`, which may hold several statements: neither driver executes a
  # semicolon-separated batch in one call, so they are split and run in order.
  # A fresh connection per call keeps this out of the way of whatever
  # connection the introspector under test is holding.
  def execute(adapter, sql)
    statements = sql.split(";\n").map(&:strip).reject(&:empty?)
    config = database_config(adapter)

    case adapter.to_s
    when "mysql"
      client = Mysql2::Client.new(config.slice(:host, :port, :username, :password, :database))
      begin
        statements.each { |statement| client.query(statement) }
      ensure
        client.close
      end
    when "postgresql"
      conn = PG.connect(
        host: config[:host], port: config[:port],
        user: config[:username], password: config[:password], dbname: config[:database],
      )
      begin
        statements.each { |statement| conn.exec(statement) }
      ensure
        conn.close
      end
    else
      raise ArgumentError, "DbFixtures does not know the #{adapter} adapter"
    end
  end
end

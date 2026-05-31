# frozen_string_literal: true

require "sqlite3"
require "mysql2"
require "pg"
require "mongo"
require "json"

require_relative "../../script/database_config"

module BootstrapDatabases
  module_function

  def run
    setup_sqlite3
    setup_mysql2
    setup_postgres
    setup_mongodb
  end

  private def setup_sqlite3
    sqlite3_config = database_config("sqlite3")
    database_name = sqlite3_config.fetch(:database)
    File.delete(database_name) if File.exist?(database_name)

    conn = SQLite3::Database.new(database_name)
    sql = File.read("seed/sqlite3-dump.sql")
    conn.execute_batch(sql)
  end

  private def setup_mysql2
    mysql2_config = database_config("mysql2")
    database_name = mysql2_config.fetch(:database)
    username = mysql2_config.fetch(:username)
    password = mysql2_config.fetch(:password)
    host = mysql2_config.fetch(:host)
    port = mysql2_config.fetch(:port)

    conn = Mysql2::Client.new(mysql2_config.except(:database))
    conn.query("DROP DATABASE IF EXISTS #{database_name}")
    conn.query("CREATE DATABASE #{database_name}")

    ret = system({"MYSQL_PWD" => password.to_s}, "mysql -h #{host} -P #{port} -u #{username} #{database_name} < seed/mysql2-dump.sql")
    raise "Failed to setup mysql2 database" unless ret
  end

  private def setup_postgres
    postgres_config = database_config("postgresql")
    database_name = postgres_config.fetch(:database)
    username = postgres_config.fetch(:username)
    password = postgres_config.fetch(:password)
    host = postgres_config.fetch(:host)
    port = postgres_config.fetch(:port)

    conn = PG.connect(
      host: host,
      port: port,
      user: username,
      password: password,
    )

    conn.exec("DROP DATABASE IF EXISTS #{database_name}")
    conn.exec("CREATE DATABASE #{database_name}")
    conn.close

    ret = system({"PGPASSWORD" => password}, "psql -h #{host} -p #{port} -U #{username} -d #{database_name} -f seed/postgresql-dump.sql > /dev/null")
    raise "Failed to setup postgres database" unless ret
  end

  private def setup_mongodb
    mongodb_config = database_config("mongodb")
    database_name = mongodb_config.fetch(:database)
    host = mongodb_config.fetch(:host)
    port = mongodb_config.fetch(:port)

    Mongo::Logger.logger.level = ::Logger::WARN

    client = Mongo::Client.new(["#{host}:#{port}"], database: database_name)
    client.database.drop

    Dir.glob("seed/mongodb/*.jsonl").each do |path|
      collection_name = File.basename(path, ".jsonl")
      # Seed lines are MongoDB Extended JSON ($oid for ObjectId `_id`/foreign
      # keys), so parse with BSON::ExtJSON — plain JSON.parse would store the
      # `{ "$oid" => ... }` wrapper as a subdocument instead of an ObjectId.
      docs = File.readlines(path, chomp: true).reject(&:empty?).map { |line| BSON::ExtJSON.parse(line) }
      client[collection_name].insert_many(docs) unless docs.empty?
    end

    # Mirror scenario/setup_with_mongodb.rb so the insert-000-schema.js
    # snapshot exercises createIndex emission (unique / plain / compound).
    client["shops"].indexes.create_one({ "name" => 1 }, name: "idx_shops_name", unique: true)
    client["users"].indexes.create_one({ "email" => 1 }, name: "idx_users_email")
    client["orders"].indexes.create_one({ "shop_id" => 1, "user_id" => 1 }, name: "idx_orders_shop_user")

    client.close
  end
end

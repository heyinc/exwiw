# frozen_string_literal: true

# Checks Exwiw::MaskUpdateRunner against a real database: the rows an UPDATE masks must equal what
# export produces for the same declarations, and everything else must stay untouched.
#
#   bundle exec ruby e2e/mask_update_scenario.rb sqlite|postgresql|mysql|mongodb

require "bundler/setup"
require "exwiw"
require "logger"
require "stringio"
require "tmpdir"
require "bson"
require "fileutils"
require "json"
require "mongo"
require "mysql2"
require "pg"
require "sqlite3"

require_relative "../script/database_config"

ADAPTER = ARGV.fetch(0)
SELECTED = [1, 2, 3, 999].freeze
LOGGER = Logger.new(nil)
DBS = { source: "exwiw_mask_update_src", apply: "exwiw_mask_update_apply", export: "exwiw_mask_update_exp" }.freeze

ROWS = [
  [1, "Alice", "alice@example.com", "a-nick", "090-1111", "Tokyo"],
  [2, nil, nil, nil, nil, "Osaka"],
  [3, "Carol", "carol@example.com", "c-nick", "090-3333", nil],
  [4, "Dave", "dave@example.com", "d-nick", "090-4444", "Kyoto"],
  [5, "Erin", "erin@example.com", "e-nick", "090-5555", "Nagoya"],
].freeze

NICKNAME_SQL = {
  "sqlite" => "('nick-' || accounts.id)",
  "postgresql" => "CONCAT('nick-', accounts.id)",
  "mysql" => "CONCAT('nick-', accounts.id)",
}.freeze

# A cryptographically random token as each adapter's credential-looking column mask, with the shape it yields.
RANDOM_TOKEN = {
  "sqlite" => ["hex(randomblob(16))", /\A[0-9A-F]{32}\z/],
  "postgresql" => ["replace(gen_random_uuid()::text, '-', '')", /\A[0-9a-f]{32}\z/],
  "mysql" => ["LOWER(HEX(RANDOM_BYTES(16)))", /\A[0-9a-f]{32}\z/],
}.freeze

def sql_columns
  [
    { name: "id" },
    { name: "name", replace_with: "user{id}" },
    { name: "email", replace_with: "masked{id}@example.com" },
    { name: "nickname", raw_sql: NICKNAME_SQL.fetch(ADAPTER) },
    { name: "phone", replace_with_fake_data: { seed: "id", type: "phone_number" } },
    { name: "display_name", map: "->(r) { r['city'].to_s.upcase + '-' + r['id'].to_s }" },
    { name: "greeting", replace_with: "hello {city}" },
    { name: "settings", replace_with: "{}" },
    { name: "tier", replace_with: 0 },
    { name: "city" },
    { name: "api_token", raw_sql: RANDOM_TOKEN.fetch(ADAPTER).first },
    { name: "internal_note", ignore: true, replace_with: "must not be written" },
  ]
end

def configs
  if ADAPTER == "mongodb"
    [
      Exwiw::MongodbCollectionConfig.from_symbol_keys(
        name: "accounts", primary_key: "_id", belongs_tos: [],
        fields: [
          { name: "_id" }, { name: "name", replace_with: "user{_id}" },
          { name: "email", replace_with: "masked{_id}@example.com" },
          { name: "phone", replace_with_fake_data: { seed: "_id", type: "phone_number" } },
          { name: "greeting", replace_with: "hello {city}" },
          { name: "tier", replace_with: 0 },
          { name: "city" },
          { name: "internal_note", ignore: true, replace_with: "must not be written" },
        ],
      ),
      Exwiw::MongodbCollectionConfig.from_symbol_keys(
        name: "account_addresses", primary_key: "_id", belongs_tos: [],
        embedded_in: { collection_name: "accounts", path: "addresses" },
        fields: [
          { name: "street", replace_with: "masked street" }, { name: "zip" },
          { name: "secret", ignore: true }, { name: "label", replace_with: "{secret}-x" },
        ],
      ),
    ]
  else
    [Exwiw::TableConfig.from_symbol_keys(name: "accounts", primary_key: "id", columns: sql_columns)]
  end
end

def connection_config(db_name)
  c = database_config(ADAPTER)
  Exwiw::ConnectionConfig.new(
    adapter: ADAPTER, host: c[:host], port: c[:port], user: c[:username], password: c[:password],
    database_name: ADAPTER == "sqlite" ? File.join(Dir.tmpdir, "#{db_name}.sqlite3") : db_name,
  )
end

# ---- per-adapter native access --------------------------------------------------------------

DDL = <<~SQL
  CREATE TABLE accounts (
    id INTEGER PRIMARY KEY, name VARCHAR(100), email VARCHAR(100), nickname VARCHAR(100),
    phone VARCHAR(100), display_name VARCHAR(100), greeting VARCHAR(100), settings %<json>s,
    tier INTEGER, city VARCHAR(100), api_token VARCHAR(100), internal_note VARCHAR(100)
  )
SQL

def sql_literal(v)
  v.nil? ? "NULL" : (v.is_a?(String) ? "'#{v.gsub("'", "''")}'" : v.to_s)
end

def native(db_name)
  cfg = connection_config(db_name)
  case ADAPTER
  when "sqlite" then SQLite3::Database.new(cfg.database_name)
  when "postgresql" then PG.connect(host: cfg.host, port: cfg.port, user: cfg.user, password: cfg.password, dbname: db_name)
  when "mysql"
    Mysql2::Client.new(host: cfg.host, port: cfg.port, username: cfg.user, password: cfg.password, database: db_name)
  when "mongodb" then Mongo::Client.new(["#{cfg.host}:#{cfg.port}"], database: db_name)
  end
end

def recreate_database(db_name)
  cfg = connection_config(db_name)
  case ADAPTER
  when "sqlite" then FileUtils.rm_f(cfg.database_name)
  when "postgresql"
    admin = PG.connect(host: cfg.host, port: cfg.port, user: cfg.user, password: cfg.password)
    admin.exec("DROP DATABASE IF EXISTS #{db_name}")
    admin.exec("CREATE DATABASE #{db_name}")
    admin.close
  when "mysql"
    admin = Mysql2::Client.new(host: cfg.host, port: cfg.port, username: cfg.user, password: cfg.password)
    admin.query("DROP DATABASE IF EXISTS #{db_name}")
    admin.query("CREATE DATABASE #{db_name}")
    admin.close
  when "mongodb" then native(db_name).database.drop
  end
end

def run_sql(db_name, sql)
  conn = native(db_name)
  case ADAPTER
  when "sqlite" then conn.execute_batch(sql)
  when "postgresql" then conn.exec(sql)
  when "mysql" then sql.split(/;\s*\n|;\s*\z/).each { |statement| conn.query(statement) unless statement.strip.empty? }
  end
  conn.close
end

def seed_documents
  ROWS.map do |id, name, email, nick, phone, city|
    { "_id" => id, "name" => name, "email" => email, "phone" => phone, "greeting" => "orig", "tier" => 7,
      "city" => city, "internal_note" => "keep #{id}",
      "addresses" => %w[a b].map { |k| { "street" => "s#{id}#{k}", "zip" => "z#{id}", "secret" => "sec#{id}#{k}", "label" => "orig" } } }
  end
end

def create_and_seed(db_name, with_data:)
  recreate_database(db_name)
  if ADAPTER == "mongodb"
    client = native(db_name)
    client["accounts"].insert_many(seed_documents) if with_data
    client.close
    return
  end
  json = { "postgresql" => "JSONB", "mysql" => "JSON" }.fetch(ADAPTER, "TEXT")
  sql = format(DDL, json: json) + ";\n"
  if with_data
    ROWS.each do |id, name, email, nick, phone, city|
      values = [id, name, email, nick, phone, "orig-display", "orig", %({"k": 1}), 7, city, "orig-token", "keep #{id}"]
      sql += "INSERT INTO accounts VALUES (#{values.map { |v| sql_literal(v) }.join(', ')});\n"
    end
  end
  run_sql(db_name, sql)
end

def read_all(db_name)
  conn = native(db_name)
  if ADAPTER == "mongodb"
    rows = conn["accounts"].find.sort("_id" => 1).map { |d| d.to_h }
    conn.close
    return rows.to_h { |d| [d["_id"], normalize(d)] }
  end
  rows =
    case ADAPTER
    when "sqlite" then conn.results_as_hash = true; conn.execute("SELECT * FROM accounts ORDER BY id")
    when "postgresql" then conn.exec("SELECT * FROM accounts ORDER BY id").to_a
    when "mysql" then conn.query("SELECT * FROM accounts ORDER BY id", cast: false).to_a
    end
  conn.close
  rows.to_h { |r| [r["id"].to_i, normalize(r)] }
end

# Compare values by text so driver type differences do not matter; JSON is re-parsed.
def normalize(row)
  row.to_h do |k, v|
    v = JSON.parse(v).to_s if k == "settings" && v.is_a?(String)
    [k, v.is_a?(Hash) || v.is_a?(Array) ? v.to_s : v&.to_s]
  end
end

def apply(db_name, script)
  if ADAPTER == "mongodb"
    cfg = connection_config(db_name)
    path = File.join(Dir.tmpdir, "mask_update_#{Process.pid}.js")
    File.write(path, script)
    ok = system("mongosh", "--quiet", "mongodb://#{cfg.host}:#{cfg.port}/#{db_name}", "--file", path)
    raise "mongosh failed" unless ok
  else
    run_sql(db_name, script)
  end
end

# ---- export through the adapter pipeline (same calls the Runner makes, minus schema dump) ----

def export_into(db_name, source_adapter, tables)
  by_name = tables.to_h { |t| [t.name, t] }
  target = by_name.fetch("accounts")
  target_ids = SELECTED.map { |id| ADAPTER == "mongodb" ? id.to_s : id }
  dump_target = Exwiw::DumpTarget.new(table_name: "accounts", ids: target_ids)
  query = source_adapter.build_query(target, dump_target, by_name)
  results = source_adapter.execute(query)
  transformer = Exwiw::RowTransformer.build(target)
  results = transformer.wrap(results) if transformer

  if ADAPTER == "mongodb"
    lines = source_adapter.to_bulk_insert(results.to_a, target).split("\n")
    client = native(db_name)
    client["accounts"].insert_many(lines.map { |l| BSON::ExtJSON.parse(l) })
    client.close
  else
    out = StringIO.new
    source_adapter.write_inserts(out, results, target, nil)
    run_sql(db_name, out.string)
  end
end

# ---- scenario -------------------------------------------------------------------------------

$failures = []
# normalize stringified addresses; export drops the ignored embedded field, the update leaves it
def without_secret(addresses) = addresses.gsub(/, "secret" => "[^"]*"/, "")
def check(label, condition)
  puts "#{condition ? '✓' : '✗'} #{label}"
  $failures << label unless condition
end

create_and_seed(DBS[:source], with_data: true)
create_and_seed(DBS[:apply], with_data: true)
create_and_seed(DBS[:export], with_data: false)

tables = configs

# The export side uses an empty copy of the schema.
export_into(DBS[:export], Exwiw::Adapter.build(connection_config(DBS[:source]), LOGGER), tables.map(&:dup).each(&:reject_ignored_members!))

original = read_all(DBS[:source])
schema_dir = Dir.mktmpdir("mask_update_schema")
tables.each { |t| File.write(File.join(schema_dir, "#{t.name}.json"), JSON.dump(t.to_hash)) }
io = StringIO.new
summary = Exwiw::MaskUpdateRunner.new(
  connection_config: connection_config(DBS[:apply]), schema_dir: schema_dir, logger: LOGGER, io: io,
  dump_target: Exwiw::DumpTarget.new(table_name: "accounts", ids: SELECTED, recursive: false, mode: :primary_key),
).run
plan = Struct.new(:script, :summary).new(io.string.delete_suffix("\n"), summary)
FileUtils.remove_entry(schema_dir)
puts plan.script
puts plan.summary.inspect

check("summary reports the missing primary key", plan.summary.missing_primary_key_values == [999])
check("summary counts existing rows", plan.summary.target_count == 3)
# a random api_token can contain "999", so look for the key in a WHERE
check("missing key absent from the script", plan.script !~ /(?:= |: )999\b/)
check("no header or transaction control", plan.script !~ /session_replication_role|FOREIGN_KEY_CHECKS|\bBEGIN\b|\bCOMMIT\b/i)

apply(DBS[:apply], plan.script)
applied = read_all(DBS[:apply])
exported = read_all(DBS[:export])

RANDOM = %w[api_token].freeze
declared = (plan.summary.columns - %w[addresses]).reject { |c| c.start_with?("addresses.") }
compared = declared - RANDOM
[1, 2, 3].each do |id|
  compared.each do |col|
    check("row #{id} #{col}: update == export (#{applied[id][col].inspect})", applied[id][col] == exported[id][col])
  end
  if ADAPTER == "mongodb"
    check("row #{id} embedded: update == export", without_secret(applied[id]["addresses"]) == exported[id]["addresses"])
    check("row #{id} embedded ignored field unchanged", applied[id]["addresses"].scan(/"secret" => "[^"]*"/) == original[id]["addresses"].scan(/"secret" => "[^"]*"/))
  end
  untouched = original[id].keys - declared - (ADAPTER == "mongodb" ? ["addresses"] : [])
  check("row #{id} undeclared columns unchanged", untouched.all? { |c| applied[id][c] == original[id][c] })
end
if ADAPTER != "mongodb"
  token_shape = RANDOM_TOKEN.fetch(ADAPTER).last
  [1, 2, 3].each do |id|
    value = applied[id]["api_token"]
    check("row #{id} api_token is a 32-char random hex, changed (#{value.inspect})",
          value.match?(token_shape) && value != original[id]["api_token"])
  end
  check("api_token differs between rows", [1, 2, 3].map { |id| applied[id]["api_token"] }.uniq.size == 3)
end
check("unselected rows unchanged", [4, 5].all? { |id| applied[id] == original[id] })
check("ignored column unchanged", [1, 2, 3].all? { |id| applied[id]["internal_note"] == original[id]["internal_note"] })
check("declared columns actually changed", applied[1]["email"] != original[1]["email"])
check("NULL preserved by replace_with", applied[2]["email"].nil?)

if $failures.empty?
  puts "✓ mask-update scenario passed (#{ADAPTER})"
else
  puts "✗ #{$failures.size} check(s) failed (#{ADAPTER})"
  exit 1
end

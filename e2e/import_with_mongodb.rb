require 'json'

require_relative './mongodb_client'

args = ARGV.dup
# `--no-drop` is used by the from-clean scenario, where insert-000-schema.js
# has already created collections and indexes — dropping would wipe them.
no_drop = args.delete("--no-drop")
# `--input-dir DIR` lets the from-clean scenario point at its own output dir
# without colliding with the default scenario's tmp/mongodb artifacts.
input_dir_idx = args.index("--input-dir")
input_dir =
  if input_dir_idx
    args.delete_at(input_dir_idx)
    args.delete_at(input_dir_idx)
  else
    "tmp/mongodb"
  end

database_name = args.first
raise "database name required" if database_name.nil? || database_name.empty?

client = MongodbScenario.client(database_name)

# exwiw emits no delete files, so the default scenario drops each target
# collection before inserting. The from-clean scenario opts out via --no-drop
# because the empty target was just set up by insert-000-schema.js.
files = Dir.glob(File.join(input_dir, "insert-*.jsonl")).sort

unless no_drop
  files.each do |path|
    collection_name = File.basename(path, ".jsonl").sub(/\Ainsert-\d+-/, "")
    puts "Drop #{collection_name}"
    client[collection_name].drop
  end
end

files.each do |path|
  collection_name = File.basename(path, ".jsonl").sub(/\Ainsert-\d+-/, "")
  puts "Import #{path} -> #{collection_name}"
  # exwiw emits MongoDB Extended JSON ($oid/$date), so parse with BSON::ExtJSON
  # to restore ObjectId `_id`/foreign keys rather than store the `$oid` wrapper.
  docs = File.readlines(path, chomp: true).reject(&:empty?).map { |line| BSON::ExtJSON.parse(line) }
  client[collection_name].insert_many(docs) unless docs.empty?
end

client.close

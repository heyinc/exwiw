require 'json'

require_relative './mongodb_client'

database_name = ARGV.first
raise "database name required" if database_name.nil? || database_name.empty?

client = MongodbScenario.client(database_name)
client.database.drop

Dir.glob("seed/mongodb/*.jsonl").each do |path|
  collection_name = File.basename(path, ".jsonl")
  # Extended JSON ($oid) -> BSON::ObjectId; plain JSON.parse would keep the
  # `{ "$oid" => ... }` wrapper as a subdocument.
  docs = File.readlines(path, chomp: true).reject(&:empty?).map { |line| BSON::ExtJSON.parse(line) }
  client[collection_name].insert_many(docs) unless docs.empty?
end

# Create representative indexes so dump_schema has something to emit and the
# from-clean scenario can verify createIndex statements actually round-trip
# through mongosh. Covers: a unique index, a plain index, and a compound index.
# (shops.name is unique in the seed; users.email is *not* — same email
# repeats across shops — so the unique flag lives on shops.)
client["shops"].indexes.create_one({ "name" => 1 }, name: "idx_shops_name", unique: true)
client["users"].indexes.create_one({ "email" => 1 }, name: "idx_users_email")
client["orders"].indexes.create_one({ "shop_id" => 1, "user_id" => 1 }, name: "idx_orders_shop_user")

client.close

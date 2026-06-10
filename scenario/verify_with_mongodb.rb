require_relative './mongodb_client'

database_name = ARGV.shift
raise "database name required" if database_name.nil? || database_name.empty?

# The seed keys `_id` with deterministic ObjectIds: a 4-hex per-collection tag
# + the zero-padded integer (see seed/mongodb). Recompute them here so the
# masked-value expectations below stay in sync with the seed.
def seed_oid_hex(tag, n)
  tag + format("%020x", n)
end
USER1_HEX = seed_oid_hex("b002", 1)            # b00200000000000000000001
POST1_HEX = seed_oid_hex("b008", 101)
POST2_HEX = seed_oid_hex("b008", 102)

# `--with-indexes` opts the from-clean scenario into checking that
# insert-000-schema.js actually round-tripped the indexes seeded in
# setup_with_mongodb.rb. The default scenario skips this because its import
# step drops collections (and their indexes) before inserting jsonl.
verify_indexes = ARGV.include?("--with-indexes")

client = MongodbScenario.client(database_name)

expected = {
  "shops" => 1,
  "users" => 2,
  "orders" => 6,
  "order_items" => 6,
  "products" => 3,
  "transactions" => 6,
  # Non-_id foreign-key propagation (belongs_to `references`): only the two
  # business_entities owned by the target shop are dumped (the third belongs to
  # another shop), and only the three sites whose `business_entity_uuid` points
  # at one of those two are pulled in (the fourth references the other shop's
  # entity). Crucially, `sites` is non-zero: its FK is a String `uuid`, and
  # before the `references` fix it was `$in`-matched against the parent's
  # ObjectId `_id` and matched nothing. See scenario/mongodb-schema/sites.json.
  "business_entities" => 2,
  "sites" => 3,
}

failed = false
expected.each do |collection, want|
  got = client[collection].count_documents({})
  if got == want
    puts "OK  #{collection}: #{got}"
  else
    puts "NG  #{collection}: expected #{want}, got #{got}"
    failed = true
  end
end

# Embedded `posts` should not be dumped as its own collection.
posts_count = client["posts"].count_documents({})
if posts_count.zero?
  puts "OK  posts collection not created (embedded)"
else
  puts "NG  posts collection unexpectedly populated: #{posts_count}"
  failed = true
end

# Verify masking of users.email (`replace_with: "masked{_id}@example.com"`, so
# the masked value embeds the ObjectId hex of user 1).
sample = client["users"].find({ "_id" => BSON::ObjectId.from_string(USER1_HEX) }).first
expected_email = "masked#{USER1_HEX}@example.com"
if sample && sample["email"] == expected_email
  puts "OK  users._id=#{USER1_HEX} email masked: #{sample["email"]}"
else
  puts "NG  users._id=#{USER1_HEX} email masking failed: #{sample.inspect}"
  failed = true
end

# Verify masking of embedded users.posts[].title (`masked-title-{_id}`).
embedded_titles = (sample && sample["posts"] || []).map { |p| p["title"] }
expected_titles = ["masked-title-#{POST1_HEX}", "masked-title-#{POST2_HEX}"]
if embedded_titles == expected_titles
  puts "OK  users._id=#{USER1_HEX} embedded posts titles masked: #{embedded_titles.inspect}"
else
  puts "NG  users._id=#{USER1_HEX} embedded posts titles unexpected: #{embedded_titles.inspect}"
  failed = true
end

# Verify the `references` propagation matched on the parent `uuid`, not `_id`:
# every dumped site's `business_entity_uuid` must be one of the dumped
# business_entities' uuids, and the other shop's uuid (be-uuid-0003) must be
# absent. This guards against a future regression silently dumping the wrong
# rows (or, with the pre-fix behaviour, none) while the counts happen to align.
dumped_be_uuids = client["business_entities"].find({}).map { |d| d["uuid"] }.sort
site_fk_uuids = client["sites"].find({}).map { |d| d["business_entity_uuid"] }.uniq.sort
if dumped_be_uuids == ["be-uuid-0001", "be-uuid-0002"] &&
   site_fk_uuids == ["be-uuid-0001", "be-uuid-0002"]
  puts "OK  sites propagated via business_entities.uuid: entities=#{dumped_be_uuids.inspect}, site FKs=#{site_fk_uuids.inspect}"
else
  puts "NG  references propagation off: entities=#{dumped_be_uuids.inspect}, site FKs=#{site_fk_uuids.inspect}"
  failed = true
end

if verify_indexes
  expected_indexes = {
    "shops" => { "idx_shops_name" => { "key" => { "name" => 1 }, "unique" => true } },
    "users" => { "idx_users_email" => { "key" => { "email" => 1 } } },
    "orders" => { "idx_orders_shop_user" => { "key" => { "shop_id" => 1, "user_id" => 1 } } },
  }

  expected_indexes.each do |collection, indexes_by_name|
    actual = client[collection].indexes.to_a.each_with_object({}) { |idx, h| h[idx["name"]] = idx }
    indexes_by_name.each do |name, expected|
      idx = actual[name]
      if idx.nil?
        puts "NG  #{collection} missing index #{name}"
        failed = true
        next
      end
      mismatches = expected.reject { |k, v| idx[k] == v }
      if mismatches.empty?
        puts "OK  #{collection} has index #{name}: #{expected.inspect}"
      else
        puts "NG  #{collection} index #{name} mismatch: expected #{expected.inspect}, got #{idx.slice(*expected.keys).inspect}"
        failed = true
      end
    end
  end
end

client.close
exit(failed ? 1 : 0)

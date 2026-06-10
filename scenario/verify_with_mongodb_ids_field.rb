require_relative './mongodb_client'

database_name = ARGV.shift
raise "database name required" if database_name.nil? || database_name.empty?

client = MongodbScenario.client(database_name)

failed = false

# `--ids-field=uuid` targets business_entities by the String `uuid`, not by the
# ObjectId `_id`. Only the entity whose uuid is "be-uuid-0001" should be dumped
# (1 doc); the other two entities have different uuids. `sites` then propagates
# off that entity's uuid (the `references` chain) to Site 1 / Site 2 (2 docs).
expected = {
  "business_entities" => 1,
  "sites" => 2,
}
expected.each do |collection, want|
  got = client[collection].count_documents({})
  if got == want
    puts "OK  #{collection}: #{got}"
  else
    puts "NG  #{collection}: expected #{want}, got #{got}"
    failed = true
  end
end

# The single dumped business_entity must be exactly the uuid we targeted —
# proving --ids matched the `uuid` field, not `_id` (where the textual id is not
# even a valid ObjectId and would match nothing).
entities = client["business_entities"].find({}).to_a
if entities.size == 1 && entities.first["uuid"] == "be-uuid-0001"
  puts "OK  business_entities targeted by uuid: #{entities.first["uuid"]}"
else
  puts "NG  business_entities not targeted by uuid: #{entities.map { |d| d["uuid"] }.inspect}"
  failed = true
end

# Downstream `references` propagation from the uuid-targeted root: every dumped
# site references be-uuid-0001, and the sites pointing at the other entities
# (be-uuid-0002 / be-uuid-0003) are absent.
site_fk_uuids = client["sites"].find({}).map { |d| d["business_entity_uuid"] }.uniq
if site_fk_uuids == ["be-uuid-0001"]
  puts "OK  sites propagated via business_entities.uuid: #{site_fk_uuids.inspect}"
else
  puts "NG  sites propagation off: #{site_fk_uuids.inspect}"
  failed = true
end

client.close
exit(failed ? 1 : 0)

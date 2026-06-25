require_relative './mongodb_client'

# Seeds the dedicated source DB for the parallel-dump scenario. The schema graph
# (e2e/mongodb-parallel-schema) is deliberately shaped so the fork schedule's
# static classification (MongodbParallelPlan) puts work in ALL three phases when
# dumping with --target-table=shops:
#
#   genuine (reachable to shops): shops (target), products
#   leaves  (no belongs_to):      brands, regions
#   ref_bt  (belongs_to, NOT reachable to shops): region_settings, region_locales
#
# - products belongs_to a leaf (brands) as well as the genuine anchor (shops),
#   so it lands in direct_leaf_genuine and exercises the Phase-2 cascade.
# - region_settings <- region_locales form one Phase-3 reference component,
#   processed by a forked worker in topological order, seeded with the `regions`
#   leaf @state handed back by the Phase-1 leaf pool.

database_name = ARGV.first
raise "database name required" if database_name.nil? || database_name.empty?

# Deterministic ObjectIds: a 4-hex per-collection tag + the zero-padded integer,
# matching the convention used by the main scenario's seed.
def oid(tag, n)
  BSON::ObjectId.from_string(tag + format("%020x", n))
end

client = MongodbScenario.client(database_name)
client.database.drop

# Genuine target. shop 1 is the dump target; shop 2's data must be excluded.
client["shops"].insert_many([
  { "_id" => oid("d001", 1), "name" => "Target Shop" },
  { "_id" => oid("d001", 2), "name" => "Other Shop" },
])

# Leaf reference data (dumped in full), consumed by a genuine collection.
client["brands"].insert_many([
  { "_id" => oid("d002", 1), "name" => "Brand A" },
  { "_id" => oid("d002", 2), "name" => "Brand B" },
  { "_id" => oid("d002", 3), "name" => "Brand C" },
])

# Genuine: anchored on shops, but also belongs_to the brands leaf (=> cascade).
# Only the two products of the target shop are in scope.
client["products"].insert_many([
  { "_id" => oid("d003", 1), "shop_id" => oid("d001", 1), "brand_id" => oid("d002", 1), "name" => "P1" },
  { "_id" => oid("d003", 2), "shop_id" => oid("d001", 1), "brand_id" => oid("d002", 2), "name" => "P2" },
  { "_id" => oid("d003", 3), "shop_id" => oid("d001", 2), "brand_id" => oid("d002", 1), "name" => "P3 (other shop)" },
])

# Reference cluster NOT reachable to shops: regions(leaf) <- region_settings <- region_locales.
# region_settings/region_locales are ref_bt and become one Phase-3 component.
client["regions"].insert_many([
  { "_id" => oid("d004", 1), "name" => "JP" },
  { "_id" => oid("d004", 2), "name" => "US" },
])
client["region_settings"].insert_many([
  { "_id" => oid("d005", 1), "region_id" => oid("d004", 1), "currency" => "JPY" },
  { "_id" => oid("d005", 2), "region_id" => oid("d004", 2), "currency" => "USD" },
])
client["region_locales"].insert_many([
  { "_id" => oid("d006", 1), "region_setting_id" => oid("d005", 1), "locale" => "ja-JP" },
  { "_id" => oid("d006", 2), "region_setting_id" => oid("d005", 1), "locale" => "ja" },
  { "_id" => oid("d006", 3), "region_setting_id" => oid("d005", 2), "locale" => "en-US" },
])

client.close

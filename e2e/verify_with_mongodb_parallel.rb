require_relative './mongodb_client'

# Verifies the parallel-dump scenario landed correctly after import. The byte
# diff in the shell script already proves parallel output == serial output; this
# adds a semantic check that the dump is meaningful (in particular that the
# Phase-3 ref_bt collections produced their full reference rows rather than the
# adapter's "match nothing" fallback, which would also be byte-identical between
# serial and parallel and thus invisible to the diff alone).

database_name = ARGV.shift
raise "database name required" if database_name.nil? || database_name.empty?

client = MongodbScenario.client(database_name)

expected = {
  "shops" => 1,            # target shop only (other shop excluded)
  "products" => 2,         # genuine: only the target shop's products
  "brands" => 3,           # leaf: dumped in full
  "regions" => 2,          # leaf: dumped in full
  "region_settings" => 2,  # ref_bt (Phase 3): scoped by the full regions set
  "region_locales" => 3,   # ref_bt (Phase 3): scoped by the full region_settings set
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

client.close
exit(failed ? 1 : 0)

# frozen_string_literal: true

# Benchmark harness for the MongoDB dump path.
#
# Reproduces the "large / embed-heavy collection is slow and memory-hungry"
# report by seeding a synthetic dataset into a local MongoDB and timing the two
# phases the Runner drives per collection:
#
#   1. execute        -- Mongo find + `.to_a` (whole result set into memory) plus
#                        building the @state propagation-key arrays.
#   2. to_bulk_insert  -- per-doc masking + extended_json + JSON.generate, joined
#                        into one giant JSONL string (single chunk, since the
#                        MongoDB config carries no bulk_insert_chunk_size).
#
# For each phase it reports wall time, peak RSS (sampled), and GC allocation
# deltas, so future iterations can measure improvements against a baseline.
#
# Usage:
#   bundle exec ruby script/bench_mongodb_dump.rb
#
# Tunables (env):
#   BENCH_USERS           number of users in the large/embed-heavy collection (default 20000)
#   BENCH_POSTS_PER_USER  embedded posts per user                              (default 30)
#   BENCH_DB              database name                                        (default exwiw_bench)
#   BENCH_KEEP            "1" to keep the seeded DB after the run              (default drop)

require 'json'
require 'logger'
require 'tmpdir'

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def realtime
  t0 = monotonic
  yield
  monotonic - t0
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'exwiw'
require 'mongo'
require 'bson'

require_relative './database_config'

USERS          = Integer(ENV.fetch('BENCH_USERS', 20_000))
POSTS_PER_USER = Integer(ENV.fetch('BENCH_POSTS_PER_USER', 30))
DB_NAME        = ENV.fetch('BENCH_DB', 'exwiw_bench')
KEEP           = ENV.fetch('BENCH_KEEP', '') == '1'

cfg = database_config('mongodb')
HOST = cfg.fetch(:host)
PORT = cfg.fetch(:port)

Mongo::Logger.logger.level = ::Logger::WARN

def rss_mb
  # macOS / Linux `ps` returns RSS in KiB.
  `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
end

# Sample RSS in the background so we capture the peak, not just the value at
# phase boundaries (the giant string is transient).
class RssSampler
  def initialize
    @peak = rss_mb
    @stop = false
  end

  def start
    @thread = Thread.new do
      until @stop
        r = `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
        @peak = r if r > @peak
        sleep 0.01
      end
    end
    self
  end

  def stop
    @stop = true
    @thread&.join
    r = rss_mb
    @peak = r if r > @peak
    @peak
  end
end

def measure(label)
  GC.start
  before_alloc = GC.stat(:total_allocated_objects)
  before_rss = rss_mb
  sampler = RssSampler.new.start
  result = nil
  wall = realtime { result = yield }
  peak = sampler.stop
  after_alloc = GC.stat(:total_allocated_objects)
  printf(
    "%-22s  time=%7.3fs  rss_before=%7.1fMB  rss_peak=%7.1fMB  alloc=%12d objs\n",
    label, wall, before_rss, peak, after_alloc - before_alloc
  )
  result
end

# ---------------------------------------------------------------------------
# Seed
# ---------------------------------------------------------------------------

client = Mongo::Client.new(["#{HOST}:#{PORT}"], database: DB_NAME)
client.database.drop

shop_id = BSON::ObjectId.new
now = Time.now.utc

puts "Seeding #{USERS} users x #{POSTS_PER_USER} embedded posts into #{DB_NAME} ..."
client['shops'].insert_one('_id' => shop_id, 'name' => 'Bench Shop', 'updated_at' => now, 'created_at' => now)

seed_wall = realtime do
  USERS.times.each_slice(2_000) do |slice|
    docs = slice.map do |i|
      posts = POSTS_PER_USER.times.map do |j|
        {
          '_id' => BSON::ObjectId.new,
          'title' => "Post title #{i}-#{j} with some representative body length text",
          'body' => 'lorem ipsum ' * 8,
          'likes' => j,
          'created_at' => now,
        }
      end
      {
        '_id' => BSON::ObjectId.new,
        'name' => "User #{i}",
        'email' => "user#{i}@example.com",
        'shop_id' => shop_id,
        'posts' => posts,
        'updated_at' => now,
        'created_at' => now,
      }
    end
    client['users'].insert_many(docs)
  end
end
printf("Seed complete in %.1fs\n\n", seed_wall)

# ---------------------------------------------------------------------------
# Build the configs (users collection + embedded posts), mirroring Runner
# ---------------------------------------------------------------------------

users_config = Exwiw::MongodbCollectionConfig.from(
  'name' => 'users',
  'primary_key' => '_id',
  'belongs_tos' => [{ 'table_name' => 'shops', 'foreign_key' => 'shop_id' }],
  'fields' => [
    { 'name' => '_id' },
    { 'name' => 'name', 'replace_with' => 'masked{_id}' },
    { 'name' => 'email', 'replace_with' => 'masked{_id}@example.com' },
    { 'name' => 'shop_id' },
    { 'name' => 'posts' },
    { 'name' => 'updated_at' },
    { 'name' => 'created_at' },
  ],
)
posts_config = Exwiw::MongodbCollectionConfig.from(
  'name' => 'posts',
  'primary_key' => '_id',
  'embedded_in' => { 'collection_name' => 'users', 'path' => 'posts' },
  'belongs_tos' => [],
  'fields' => [
    { 'name' => '_id' },
    { 'name' => 'title', 'replace_with' => 'masked-title-{_id}' },
  ],
)
config_by_name = { 'users' => users_config, 'posts' => posts_config }

connection_config = Exwiw::ConnectionConfig.new(adapter: 'mongodb', host: HOST, port: PORT, database_name: DB_NAME)
logger = Logger.new($stdout)
logger.level = Logger::WARN
adapter = Exwiw::Adapter::MongodbAdapter.new(connection_config, logger)

# Build a Find that pulls every user in the seeded shop, mirroring a scoped dump
# that hits a large embed-heavy collection. Reuses the adapter's real projection
# / embedded-children / propagation-key setup so execute + to_bulk_insert behave
# exactly as in a Runner-driven dump.
def adapter.build_query_all(config, config_by_name, shop_id)
  @embedded_children_by_parent = index_embedded_children(config_by_name)
  @propagation_keys = propagation_keys_for(config, config_by_name)
  Exwiw::MongoQuery::Find.new(
    collection: config.name,
    primary_key: config.primary_key,
    filter: { 'shop_id' => shop_id },
    projection: build_projection(config, @propagation_keys),
  )
end

puts "=== Full dump: execute + chunked write (users: #{USERS} docs, #{POSTS_PER_USER} embedded posts each) ==="

query = adapter.build_query_all(users_config, config_by_name, shop_id)
chunk_size = adapter.default_bulk_insert_chunk_size

# Compare the two execute strategies as a *full* execute+write — the unit the
# Runner actually drives — since #execute is now lazy (StreamingResult) and does
# no work until the result is consumed. Each is measured as wall time, peak RSS,
# and allocations over the whole phase.
#
# NEW is the production path: adapter.execute returns a StreamingResult that
# streams the cursor; the Runner pulls chunks via each_slice so at most one chunk
# of documents is resident at a time. OLD is the pre-iteration-3 behavior: `.to_a`
# the entire result set into memory before writing.
#
# NEW (streaming) is measured FIRST so its peak RSS is not polluted by the OLD
# path's leftover full-result-set array (RSS is sticky — the OS reclaims lazily).
# Masking is idempotent for these templates and each strategy reads its own fresh
# docs, so both produce byte-identical output.
def write_chunked(adapter, results, config, chunk_size, path)
  File.open(path, 'w') do |file|
    first = true
    results.each_slice(chunk_size) do |chunk|
      file.print("\n") unless first
      file.print(adapter.to_bulk_insert(chunk, config))
      first = false
    end
    file.print("\n")
  end
end

tmp_new = File.join(Dir.tmpdir, "exwiw_bench_new.jsonl")
measure("NEW streaming execute+write (n=#{chunk_size})") do
  results = adapter.execute(query) # StreamingResult — no query until consumed
  write_chunked(adapter, results, users_config, chunk_size, tmp_new)
end
new_mb = File.size(tmp_new) / 1024.0 / 1024.0
File.delete(tmp_new)

tmp_old = File.join(Dir.tmpdir, "exwiw_bench_old.jsonl")
measure('OLD to_a execute+write') do
  view = adapter.send(:db)[query.collection].find(query.filter).projection(query.projection)
  docs = view.to_a
  keys = adapter.instance_variable_get(:@propagation_keys)
  keys.each_with_object({}) { |k, acc| acc[k] = docs.map { |d| d[k] } } # mirror @state cost
  write_chunked(adapter, docs, users_config, chunk_size, tmp_old)
end
old_mb = File.size(tmp_old) / 1024.0 / 1024.0
File.delete(tmp_old)
printf("  -> output %.1fMB (new) / %.1fMB (old); byte-identical: %s\n",
       new_mb, old_mb, (new_mb == old_mb).to_s)

# Microbench: isolate the serialization sub-steps on a single representative doc
# to attribute the embed-heavy cost (masking vs as_extended_json vs JSON.generate).
sample = adapter.send(:db)[query.collection].find(query.filter).projection(query.projection).first
N = 5_000
puts "\n=== Per-doc serialization microbench (#{N} iterations on one #{POSTS_PER_USER}-post doc) ==="
def microbench(label, n)
  t = realtime { n.times { yield } }
  printf("  %-28s %7.3fs total  %8.1f us/op\n", label, t, t / n * 1_000_000)
end
# Masking alone (apply_replace_with! + apply_embedded_masking!) on a fresh dup,
# isolating the cost the precompiled-template path targets — it runs once per
# masked field of the doc AND of every embedded subdocument, so it scales with
# embedding count.
microbench('masking only (dup+replace_with)', N) do
  d = sample.dup
  adapter.send(:apply_replace_with!, d, users_config)
  adapter.send(:apply_embedded_masking!, d, users_config)
end
microbench('as_extended_json only', N) { sample.as_extended_json(mode: :relaxed) }
ext = sample.as_extended_json(mode: :relaxed)
microbench('JSON.generate(ext) only', N) { JSON.generate(ext) }
microbench('full to_bulk_insert(1 doc)', N) { adapter.to_bulk_insert([sample.dup], users_config) }

client.database.drop unless KEEP
client.close
puts "\nDone#{KEEP ? " (kept #{DB_NAME})" : " (dropped #{DB_NAME})"}."

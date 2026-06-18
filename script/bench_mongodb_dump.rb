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

puts "=== Dump phases (users: #{USERS} docs, #{POSTS_PER_USER} embedded posts each) ==="

query = adapter.build_query_all(users_config, config_by_name, shop_id)

results = measure('execute (find+to_a)') { adapter.execute(query) }
puts "  -> #{results.size} documents loaded"

jsonl = measure('to_bulk_insert (1 chunk)') { adapter.to_bulk_insert(results, users_config) }
puts "  -> #{(jsonl.bytesize / 1024.0 / 1024.0).round(1)}MB JSONL"

# Microbench: isolate the serialization sub-steps on a single representative doc
# to attribute the embed-heavy cost (masking vs as_extended_json vs JSON.generate).
sample = results.first
N = 5_000
puts "\n=== Per-doc serialization microbench (#{N} iterations on one #{POSTS_PER_USER}-post doc) ==="
def microbench(label, n)
  t = realtime { n.times { yield } }
  printf("  %-28s %7.3fs total  %8.1f us/op\n", label, t, t / n * 1_000_000)
end
microbench('as_extended_json only', N) { sample.as_extended_json(mode: :relaxed) }
ext = sample.as_extended_json(mode: :relaxed)
microbench('JSON.generate(ext) only', N) { JSON.generate(ext) }
microbench('full to_bulk_insert(1 doc)', N) { adapter.to_bulk_insert([sample.dup], users_config) }

client.database.drop unless KEEP
client.close
puts "\nDone#{KEEP ? " (kept #{DB_NAME})" : " (dropped #{DB_NAME})"}."

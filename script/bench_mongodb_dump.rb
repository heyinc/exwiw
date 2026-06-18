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
#   BENCH_PARALLEL_WORKERS  comma-separated worker counts to compare against the
#                           serial write_bulk_insert baseline                 (default "4,8")

require 'json'
require 'logger'
require 'tmpdir'
require 'digest'
require 'etc'

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
WORKER_COUNTS  = ENV.fetch('BENCH_PARALLEL_WORKERS', '4,8').split(',').map { |s| Integer(s.strip) }
# Skip the NEW/OLD streaming-vs-.to_a comparison so the serial-vs-parallel
# section runs from a fresh, low-RSS process. The NEW/OLD passes leave the
# process at ~1GB resident (Ruby reclaims to the OS lazily), which puts the
# serial baseline under more GC/memory pressure than the later parallel runs and
# inflates the apparent speedup. Set BENCH_SKIP_BASELINE=1 for a clean number.
SKIP_BASELINE  = ENV.fetch('BENCH_SKIP_BASELINE', '') == '1'

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
    "%-42s  time=%7.3fs  rss_before=%7.1fMB  rss_peak=%7.1fMB  alloc=%12d objs\n",
    label, wall, before_rss, peak, after_alloc - before_alloc
  )
  # Return the wall time (not the block result) so callers can derive a speedup;
  # no caller depends on the block's return value.
  wall
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

# Configure `adapter` exactly as a Runner-driven build_query call would — set the
# embedded-children index and propagation keys it stashes on the instance — and
# return the Find that pulls every user in the seeded shop, mirroring a scoped
# dump against a large embed-heavy collection. Standalone (not a singleton method)
# so the serial and parallel adapter instances below can each be set up the same
# way, making execute + to_bulk_insert/write_bulk_insert behave as in a real dump.
def setup_query(adapter, config, config_by_name, shop_id)
  adapter.instance_variable_set(:@embedded_children_by_parent, adapter.send(:index_embedded_children, config_by_name))
  keys = adapter.send(:propagation_keys_for, config, config_by_name)
  adapter.instance_variable_set(:@propagation_keys, keys)
  Exwiw::MongoQuery::Find.new(
    collection: config.name,
    primary_key: config.primary_key,
    filter: { 'shop_id' => shop_id },
    projection: adapter.send(:build_projection, config, keys),
  )
end

query = setup_query(adapter, users_config, config_by_name, shop_id)
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

unless SKIP_BASELINE
puts "=== Full dump: execute + chunked write (users: #{USERS} docs, #{POSTS_PER_USER} embedded posts each) ==="

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
end

# ---------------------------------------------------------------------------
# Production write_bulk_insert: serial vs fork-parallel
# ---------------------------------------------------------------------------
#
# This drives the EXACT production seam the Runner uses for a MongoDB dump
# (runner.rb: results.each_slice(chunk_size) { adapter.write_bulk_insert(file,
# chunk, table) }, with one "\n" between chunks and a trailing "\n"). Unlike the
# NEW/OLD comparison above (which calls to_bulk_insert directly), this exercises
# the fork-parallel path that --parallel-workers / EXWIW_MONGODB_PARALLEL_WORKERS
# turns on, through the real StreamingResult cursor — the path that had only been
# measured by the DB-free probe and a light e2e smoke, never on this embed-heavy
# dataset end to end.
#
# Each worker count gets its own adapter instance because both the resolved
# worker count and default_bulk_insert_chunk_size are memoized per adapter (the
# parallel chunk is workers*4000 to amortize fork). Output is SHA256'd and
# compared to the serial baseline to prove byte-identity. Note: the RSS sampler
# only sees the PARENT process — the parent holds the resident chunk (the memory
# trade-off), while the forked children serialize in separate address spaces, so
# the parent's alloc count drops sharply on the parallel runs.
def write_via_runner_loop(adapter, results, config, chunk_size, path)
  statement_count = 0
  File.open(path, 'w') do |file|
    results.each_slice(chunk_size) do |chunk|
      file.print("\n") if statement_count.positive?
      adapter.write_bulk_insert(file, chunk, config)
      statement_count += 1
    end
    file.print("\n")
  end
  statement_count
end

puts "\n=== Production write_bulk_insert: serial vs fork-parallel (the Runner's chunk loop) ==="
puts "  host cores: #{Etc.nprocessors}"

serial_adapter = Exwiw::Adapter::MongodbAdapter.new(connection_config, logger, parallel_workers: 1)
serial_query = setup_query(serial_adapter, users_config, config_by_name, shop_id)
serial_chunk = serial_adapter.default_bulk_insert_chunk_size
serial_path = File.join(Dir.tmpdir, "exwiw_bench_serial.jsonl")
serial_secs = measure("serial write_bulk_insert (n=#{serial_chunk})") do
  write_via_runner_loop(serial_adapter, serial_adapter.execute(serial_query), users_config, serial_chunk, serial_path)
end
serial_sha = Digest::SHA256.file(serial_path).hexdigest
serial_adapter.send(:db).close rescue nil

# Serial floor: how much of the serial dump is the Mongo cursor's BSON->Ruby
# decode — which runs in the parent regardless of worker count — versus the
# per-doc masking + extended_json + JSON.generate that forking parallelizes.
# each_slice drains the cursor exactly as the dump does, but each chunk is only
# counted, not serialized. The non-decode remainder is the parallelizable
# fraction, which (via Amdahl) caps the achievable fork-parallel speedup — this
# is why the embed-heavy production speedup falls well short of the DB-free
# probe's serialization-only number.
drain_adapter = Exwiw::Adapter::MongodbAdapter.new(connection_config, logger, parallel_workers: 1)
drain_query = setup_query(drain_adapter, users_config, config_by_name, shop_id)
drained = 0
drain_secs = measure("cursor drain only (decode, no serialize)") do
  drain_adapter.execute(drain_query).each_slice(serial_chunk) { |chunk| drained += chunk.size }
end
drain_adapter.send(:db).close rescue nil
serialize_frac = (serial_secs - drain_secs) / serial_secs
printf("    -> drained %d docs; decode ≈ %.3fs, serialize ≈ %.3fs of the %.3fs serial dump " \
       "(%.0f%% parallelizable -> Amdahl cap %.2fx)\n",
       drained, drain_secs, serial_secs - drain_secs, serial_secs,
       serialize_frac * 100, 1.0 / (1.0 - serialize_frac))

WORKER_COUNTS.each do |w|
  pa = Exwiw::Adapter::MongodbAdapter.new(connection_config, logger, parallel_workers: w)
  pq = setup_query(pa, users_config, config_by_name, shop_id)
  chunk = pa.default_bulk_insert_chunk_size
  path = File.join(Dir.tmpdir, "exwiw_bench_parallel_#{w}.jsonl")
  secs = measure("parallel write_bulk_insert (workers=#{w}, n=#{chunk})") do
    write_via_runner_loop(pa, pa.execute(pq), users_config, chunk, path)
  end
  sha = Digest::SHA256.file(path).hexdigest
  printf("    -> workers=%d  speedup=%5.2fx vs serial  byte-identical: %s\n",
         w, serial_secs / secs, (sha == serial_sha).to_s)
  File.delete(path)
  pa.send(:db).close rescue nil
end
File.delete(serial_path)

# Microbench: isolate the serialization sub-steps on a single representative doc
# to attribute the embed-heavy cost (masking vs as_extended_json vs JSON.generate).
sample = adapter.send(:db)[query.collection].find(query.filter).projection(query.projection).first
N = 5_000
puts "\n=== Per-doc serialization microbench (#{N} iterations on one #{POSTS_PER_USER}-post doc) ==="
def microbench(label, n)
  t = realtime { n.times { yield } }
  printf("  %-28s %7.3fs total  %8.1f us/op\n", label, t, t / n * 1_000_000)
end
# Masking alone (apply_mask_plan! over the precompiled per-config plan) on a fresh
# dup, isolating the cost the precompiled-template/plan path targets — it runs once
# per masked field of the doc AND of every embedded subdocument, so it scales with
# embedding count.
mask_plan = adapter.send(:mask_plan, users_config)
microbench('masking only (dup+mask_plan)', N) do
  d = sample.dup
  adapter.send(:apply_mask_plan!, d, mask_plan)
end
microbench('as_extended_json only', N) { sample.as_extended_json(mode: :relaxed) }
ext = sample.as_extended_json(mode: :relaxed)
microbench('JSON.generate(ext) only', N) { JSON.generate(ext) }
microbench('full to_bulk_insert(1 doc)', N) { adapter.to_bulk_insert([sample.dup], users_config) }

client.database.drop unless KEEP
client.close
puts "\nDone#{KEEP ? " (kept #{DB_NAME})" : " (dropped #{DB_NAME})"}."

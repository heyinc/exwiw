# frozen_string_literal: true

# Feasibility probe: can RANGE-PARTITIONING the cursor across forked workers
# break the serial BSON->Ruby decode floor?
#
# Iteration 10 found that the shipped fork-parallel *serialization* path
# (ParallelSerializer behind --parallel-workers) delivers only ~1.0-1.4x
# end-to-end on embed-heavy data, far below the DB-free serialization probe's
# ~2.5x, because ~40% of the dump wall time is the Mongo cursor's BSON->Ruby
# decode. That decode runs SERIALLY in the parent regardless of worker count, so
# parallelizing only serialization is Amdahl-capped (~2.5x) and most of that is
# then eaten by COW + concat overhead.
#
# The one untried lever (notes, iter 10) is to parallelize the cursor fetch
# itself: split the query into W disjoint `_id` ranges, fork W workers that EACH
# open their own connection + cursor and decode+mask+serialize their range. Then
# the decode is parallel too, not just the serialization. This probe measures
# whether that actually beats the serialization-only number — BEFORE paying for
# the (much larger) productionization (per-worker connections, distributed
# @state propagation-key capture, changed output ordering).
#
# Unlike script/bench_mongodb_parallel_probe.rb (DB-free, serialization only),
# this probe REQUIRES a live MongoDB because the whole point is the cursor
# decode. The dev sandbox blocks 127.0.0.1:27017, so run with the sandbox
# disabled.
#
# Distributed @state: each worker also captures its range's FK-propagation keys
# (via the shipping Exwiw::PropagationCapture), Marshal-ships them back, and the
# parent merges them in range order. The probe asserts the merged @state equals
# the serial sorted-cursor capture (`state-identical`) — validating the
# cursor-parallel path's "main productionization blocker" (notes, iter 11) on
# live data, not just the output bytes.
#
# Byte-identity: both paths sort by `_id`, so the serial output (one sorted
# cursor) and the parallel output (disjoint sorted `_id` ranges concatenated in
# range order) are byte-for-byte identical. NOTE this is a DIFFERENT byte stream
# than the production dump, which streams in natural (unsorted) order — adopting
# cursor-parallel fetch in production would change the dump's row ordering
# (still a semantically equivalent re-import). The probe asserts serial==parallel
# under the sorted contract it measures.
#
# Usage:
#   bundle exec ruby script/bench_mongodb_cursor_parallel_probe.rb
#
# Tunables (env):
#   BENCH_USERS           users in the embed-heavy collection   (default 20000)
#   BENCH_POSTS_PER_USER  embedded posts per user               (default 30)
#   BENCH_DB              database name                          (default exwiw_cursor_probe)
#   BENCH_WORKERS         comma-separated worker counts to try   (default 4,8)
#   BENCH_REUSE           "1" to skip seeding if the collection already has the
#                         expected doc count (faster repeat runs)
#   BENCH_KEEP            "1" to keep the seeded DB after the run

require 'json'
require 'logger'
require 'tmpdir'
require 'digest'
require 'etc'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'exwiw'
require 'mongo'
require 'bson'

require_relative './database_config'

USERS          = Integer(ENV.fetch('BENCH_USERS', 20_000))
POSTS_PER_USER = Integer(ENV.fetch('BENCH_POSTS_PER_USER', 30))
DB_NAME        = ENV.fetch('BENCH_DB', 'exwiw_cursor_probe')
WORKER_COUNTS  = ENV.fetch('BENCH_WORKERS', '4,8').split(',').map { |s| Integer(s.strip) }
REUSE          = ENV.fetch('BENCH_REUSE', '') == '1'
KEEP           = ENV.fetch('BENCH_KEEP', '') == '1'

cfg  = database_config('mongodb')
HOST = cfg.fetch(:host)
PORT = cfg.fetch(:port)

Mongo::Logger.logger.level = ::Logger::WARN

# Connect directly to the single node. The local dev mongo is a one-node replica
# set that self-identifies as `localhost`, so a default (replica-set-aware)
# client connecting to 127.0.0.1 churns through SDAM rediscovery — a dev
# artifact that would inflate each worker's connection-setup cost and is NOT
# representative of the steady-state per-worker cursor cost this probe measures.
# `connect: :direct` skips topology monitoring and reads straight from the node.
def mongo_client
  Mongo::Client.new(["#{HOST}:#{PORT}"], database: DB_NAME, connect: :direct)
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def realtime
  t0 = monotonic
  yield
  monotonic - t0
end

# ---------------------------------------------------------------------------
# Seed (same shape as script/bench_mongodb_dump.rb so docs decode identically)
# ---------------------------------------------------------------------------

client  = mongo_client
shop_id = nil

if REUSE && client['users'].find('posts.0' => { '$exists' => true }).count_documents == USERS
  shop_id = client['users'].find.first&.fetch('shop_id')
  puts "Reusing existing #{DB_NAME}.users (#{USERS} docs)."
end

unless shop_id
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
  printf("Seed complete in %.1fs\n", seed_wall)
end
puts

# ---------------------------------------------------------------------------
# Adapter setup (mirror a Runner-driven build_query so masking + serialization
# go through the real production code; only the cursor fetch is custom here)
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

# Set the instance state a real build_query would stash, so #mask_plan and
# #build_projection behave as in a dump.
adapter.instance_variable_set(:@embedded_children_by_parent, adapter.send(:index_embedded_children, config_by_name))
keys = adapter.send(:propagation_keys_for, users_config, config_by_name)
adapter.instance_variable_set(:@propagation_keys, keys)

PROJECTION  = adapter.send(:build_projection, users_config, keys)
BASE_FILTER = { 'shop_id' => shop_id }.freeze
SEPARATOR   = "\n"
# Warm the mask plan in the parent so forked workers COW-inherit it instead of
# recompiling it (matches how write_bulk_insert warms it before fork).
PLAN = adapter.send(:mask_plan, users_config)
# The FK-propagation keys a real build_query would capture for this collection
# (children $in-match against these). Each forked range worker captures its own
# slice and the parent merges them — the distributed-@state path this probe now
# also validates (see cursor_parallel below).
KEYS = keys.freeze

COLL = 'users'

def serial_view(client)
  client[COLL].find(BASE_FILTER).projection(PROJECTION).sort('_id' => 1)
end

# The propagation @state a serial dump would publish: capture KEYS over the whole
# sorted cursor. The cursor-parallel path must reproduce this exactly by merging
# per-worker captures in range order.
def serial_captured(client)
  capture = Exwiw::PropagationCapture.new(KEYS)
  serial_view(client).each { |doc| capture.observe(doc) }
  capture.to_h
end

def write_view(adapter, view, path)
  File.open(path, 'w') do |file|
    first = true
    view.each do |doc|
      file.write(SEPARATOR) unless first
      file.write(adapter.send(:serialize_document, doc, PLAN))
      first = false
    end
  end
end

# ---------------------------------------------------------------------------
# Serial baseline (single cursor, sorted by _id) + decode-floor measurement
# ---------------------------------------------------------------------------

puts "=== Cursor-parallel fetch probe (users: #{USERS} docs x #{POSTS_PER_USER} posts) ==="
puts "  host cores: #{Etc.nprocessors}; workers tried: #{WORKER_COUNTS.inspect}"

serial_path = File.join(Dir.tmpdir, 'exwiw_cursor_serial.jsonl')
# Warm up, then keep the faster of two passes (machine load is noisy).
write_view(adapter, serial_view(client), serial_path)
serial_wall = [realtime { write_view(adapter, serial_view(client), serial_path) },
               realtime { write_view(adapter, serial_view(client), serial_path) }].min
serial_sha   = Digest::SHA256.file(serial_path).hexdigest
serial_bytes = File.size(serial_path)
serial_state = serial_captured(client)
printf("serial (sorted cursor)            time=%7.3fs  output=%.1fMB  state-keys=%s  (baseline)\n",
       serial_wall, serial_bytes / 1024.0 / 1024.0, KEYS.inspect)

# Decode floor: drain the same sorted cursor WITHOUT serializing. This is the
# part fork-parallel SERIALIZATION cannot touch (it runs serially in the parent)
# but cursor-parallel fetch SPLITS across workers.
drained = 0
decode_wall = [realtime { drained = 0; serial_view(client).each { drained += 1 } },
               realtime { drained = 0; serial_view(client).each { drained += 1 } }].min
serialize_frac = (serial_wall - decode_wall) / serial_wall
printf("  decode-only (no serialize)      time=%7.3fs  (%.0f%% of serial is decode; " \
       "serialization-only fork Amdahl cap %.2fx)\n",
       decode_wall, (decode_wall / serial_wall) * 100, 1.0 / (1.0 - serialize_frac))
puts "  -> cursor-parallel fetch aims to split that decode floor too."

# ---------------------------------------------------------------------------
# Cursor-parallel fetch via the SHIPPING MongodbAdapter#write_inserts override.
#
# As of iteration 16 the cursor-parallel recipe (split into _id ranges, fork one
# worker per range with its own connection, concat parts in range order, merge
# per-range PropagationCaptures into @state) lives in the production adapter,
# gated by EXWIW_MONGODB_CURSOR_PARALLEL + parallel_workers>1. This probe now
# drives THAT method instead of an inline copy — the same "re-point at the
# shipping component" move iterations 11–14 made for the partitioner / capture /
# fork-writer. It hands the adapter a StreamingResult exactly as the Runner would
# (the cursor-parallel path ignores that result's single cursor and re-issues the
# query partitioned by _id range), then reads back the @state the adapter
# republished to assert it matches the serial sorted-cursor capture.
#
# Caveat vs iterations 11–14: those used a `connect: :direct` client to strip the
# dev single-node-replica-set SDAM rediscovery artifact. The shipping
# #build_client (production-correct) does NOT force :direct, so each forked
# worker pays one SDAM/server-selection round on the dev box — overhead a real
# replica-set dump also pays but that iter 11's :direct probe hid. So the speedup
# printed here may read LOWER than iter 11's ~3.4x@4 / ~5.5x@8 on the same data;
# byte- and state-identity (the integration's correctness) are the primary guard,
# and any speedup well above the serialization-only path's ~1.0–1.2x validates it.
# ---------------------------------------------------------------------------

ENV['EXWIW_MONGODB_CURSOR_PARALLEL'] = '1'

# Build a fully-primed adapter for `workers` cursor-parallel processes — the
# instance state a Runner-driven build_query would have stashed (embedded-children
# index, propagation keys, warmed mask plan), so #write_inserts behaves as in a
# real dump. A lambda (not a def) so it closes over the probe's local config.
build_primed_adapter = lambda do |workers|
  a = Exwiw::Adapter::MongodbAdapter.new(connection_config, logger, parallel_workers: workers)
  a.instance_variable_set(:@embedded_children_by_parent, a.send(:index_embedded_children, config_by_name))
  a.instance_variable_set(:@propagation_keys, KEYS)
  a.send(:mask_plan, users_config) # warm in the parent so forked workers COW-inherit it
  a
end

# Run the shipping cursor-parallel write for `workers` to `path`, returning the
# @state the adapter republished from the merged per-range captures.
run_cursor_parallel = lambda do |workers, path|
  a = build_primed_adapter.call(workers)
  parent = a.send(:db)
  query = Exwiw::MongoQuery::Find.new(
    collection: COLL, primary_key: '_id', filter: BASE_FILTER, projection: PROJECTION
  )
  # The cursor-parallel path never consumes this view's cursor; it only needs the
  # query metadata off the StreamingResult, so an unsorted find is fine here.
  view = parent[COLL].find(BASE_FILTER).projection(PROJECTION)
  state = a.instance_variable_get(:@state)
  results = Exwiw::Adapter::MongodbAdapter::StreamingResult.new(
    view: view, collection: COLL, keys: KEYS, state: state, query: query
  )
  File.open(path, 'w') { |io| a.write_inserts(io, results, users_config) }
  parent.close
  state[COLL]
end

WORKER_COUNTS.each do |w|
  par_path = File.join(Dir.tmpdir, "exwiw_cursor_parallel_#{w}.jsonl")
  merged_state = nil
  par_wall = [realtime { merged_state = run_cursor_parallel.call(w, par_path) },
              realtime { merged_state = run_cursor_parallel.call(w, par_path) }].min
  sha = Digest::SHA256.file(par_path).hexdigest
  state_ok = merged_state == serial_state
  printf("cursor-parallel fork x %-2d         time=%7.3fs  speedup=%5.2fx vs serial  byte-identical=%s  state-identical=%s\n",
         w, par_wall, serial_wall / par_wall, (sha == serial_sha).to_s, state_ok.to_s)
  warn "  !! output DIVERGED for fork x #{w}" unless sha == serial_sha
  warn "  !! merged @state DIVERGED for fork x #{w}" unless state_ok
  File.delete(par_path)
end

File.delete(serial_path)
client.database.drop unless KEEP
client.close
puts
puts "Note: parallel timings INCLUDE the _id-range coordination scan + fork +"
puts "part-file IO + concat + per-worker connect, so the speedup reflects what the"
puts "shipping cursor-parallel dump path would actually pay. byte-identical=true /"
puts "state-identical=true is the integration's correctness guard."
puts KEEP ? "Done (kept #{DB_NAME})." : "Done (dropped #{DB_NAME})."

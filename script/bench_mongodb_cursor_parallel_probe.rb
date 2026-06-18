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

COLL = 'users'

def serial_view(client)
  client[COLL].find(BASE_FILTER).projection(PROJECTION).sort('_id' => 1)
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
printf("serial (sorted cursor)            time=%7.3fs  output=%.1fMB  (baseline)\n",
       serial_wall, serial_bytes / 1024.0 / 1024.0)

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
# Cursor-parallel fetch: W disjoint _id ranges, one forked worker (+ its own
# connection + cursor) per range, parent concatenates parts in range order.
# ---------------------------------------------------------------------------

# Compute W contiguous, disjoint, exhaustive [first_id, last_id] ranges over the
# sorted _ids via the shipping Exwiw::MongoIdPartitioner (so this probe exercises
# the production splitting logic, not a throwaway copy — the same role
# script/bench_mongodb_parallel_probe.rb plays for ParallelSerializer). Fetching
# the _ids (index-only, projection {_id:1}) is the coordination cost a production
# impl would pay (or optimize via $bucketAuto / splitVector); it is INCLUDED in
# the parallel timing so the speedup is honest.
def id_ranges(client, workers)
  Exwiw::MongoIdPartitioner.ranges_for(client[COLL].find(BASE_FILTER), '_id', workers)
end

# Fork one worker per range. Each opens its OWN Mongo::Client (the driver is not
# fork-safe — a forked child must not reuse the parent's client/sockets) and
# serializes its range to a part file, exit! to skip finalizers in the child.
def fork_range_worker(adapter, range, part, err)
  first_id, last_id = range
  fork do
    begin
      c = mongo_client
      filter = Exwiw::MongoIdPartitioner.range_filter(BASE_FILTER, '_id', first_id, last_id)
      view = c[COLL].find(filter).projection(PROJECTION).sort('_id' => 1)
      File.open(part, 'w') do |f|
        firstdoc = true
        view.each do |doc|
          f.write(SEPARATOR) unless firstdoc
          f.write(adapter.send(:serialize_document, doc, PLAN))
          firstdoc = false
        end
      end
      c.close
      exit!(0)
    rescue Exception => e
      File.write(err, "#{e.class}: #{e.message}") rescue nil
      exit!(1)
    end
  end
end

def cursor_parallel(adapter, client, workers, path)
  Dir.mktmpdir('exwiw_cursor_parallel') do |tmpdir|
    ranges = id_ranges(client, workers)
    jobs = ranges.each_with_index.map do |range, idx|
      part = File.join(tmpdir, "part_#{idx}")
      err  = File.join(tmpdir, "err_#{idx}")
      [fork_range_worker(adapter, range, part, err), part, err]
    end

    failures = []
    jobs.each do |(pid, _part, err)|
      Process.waitpid(pid)
      next if $?.success?

      detail = (File.read(err) if File.exist?(err)) || "exit #{$?.exitstatus.inspect}"
      failures << "worker #{pid}: #{detail}"
    end
    raise "cursor-parallel failed: #{failures.join('; ')}" unless failures.empty?

    File.open(path, 'w') do |io|
      jobs.each_with_index do |(_pid, part, _err), i|
        io.write(SEPARATOR) unless i.zero?
        File.open(part, 'r') { |f| IO.copy_stream(f, io) }
      end
    end
  end
end

WORKER_COUNTS.each do |w|
  par_path = File.join(Dir.tmpdir, "exwiw_cursor_parallel_#{w}.jsonl")
  par_wall = [realtime { cursor_parallel(adapter, client, w, par_path) },
              realtime { cursor_parallel(adapter, client, w, par_path) }].min
  sha = Digest::SHA256.file(par_path).hexdigest
  printf("cursor-parallel fork x %-2d         time=%7.3fs  speedup=%5.2fx vs serial  byte-identical=%s\n",
         w, par_wall, serial_wall / par_wall, (sha == serial_sha).to_s)
  warn "  !! output DIVERGED for fork x #{w}" unless sha == serial_sha
  File.delete(par_path)
end

File.delete(serial_path)
client.database.drop unless KEEP
client.close
puts
puts "Note: parallel timings INCLUDE the _id-range coordination scan + fork +"
puts "part-file IO + concat, so the speedup reflects what a cursor-parallel dump"
puts "path would actually pay. A win here (well above the serialization-only"
puts "~1.0-1.2x) is what would justify productionizing per-worker cursors."
puts KEEP ? "Done (kept #{DB_NAME})." : "Done (dropped #{DB_NAME})."

# frozen_string_literal: true

# Benchmark for the Ruby-side masking modes (RowTransformer: `map` /
# `replace_with_fake_data`) — the first per-row Ruby cost on the SQL dump
# path (replace_with/raw_sql run in the database, so the pipeline had none).
#
# Part A (no DB) drives Adapter#write_inserts over a synthesized result set,
# comparing a baseline (no transformer) against map / fake-data variants, so
# the reported delta is exactly the transform overhead on the serialization
# path. Rows are materialized once and frozen (the transformer dups frozen
# rows, matching sqlite's frozen cursor rows), so every variant streams the
# same array and row generation stays out of the measurement.
#
# Part B (live sqlite, BENCH_DB=0 to skip) seeds a temp sqlite file and runs
# execute + wrap + write_inserts end-to-end, where the DB fetch cost dilutes
# the per-row transform overhead — the number closest to a real dump.
#
# Usage:
#   bundle exec ruby script/bench_row_transform.rb
#   BENCH_ROWS=2000000 bundle exec ruby script/bench_row_transform.rb
#   BENCH_DB=0 BENCH_ROWS=5000000 bundle exec ruby script/bench_row_transform.rb
#
# Needs `ps` for RSS sampling (disable the sandbox), and the faker gem
# (Gemfile dev dependency).

require 'logger'
require 'tmpdir'
require 'zlib'
require 'digest'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'exwiw'
require 'faker'

ROWS   = Integer(ENV.fetch('BENCH_ROWS', 200_000))
RUN_DB = ENV.fetch('BENCH_DB', '1') != '0'
# BENCH_PART_A=0 runs only the live-DB Part B — useful at high BENCH_ROWS,
# where Part A's materialized rows array (~0.7GB per 1M rows) would otherwise
# leave the heap enlarged and add GC noise to the end-to-end numbers.
RUN_PART_A = ENV.fetch('BENCH_PART_A', '1') != '0'

COLUMNS = %w[id name email bio status amount created_at updated_at].freeze

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def realtime
  t0 = monotonic
  yield
  monotonic - t0
end

def rss_mb
  `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
end

# NOTE: unlike script/bench_sql_dump.rb, there is no background `ps` RSS
# sampler here. Each backtick forks the whole process, and with the multi-GB
# rows array a 5M-row run needs, that fork dominates the measurement (measured
# 10.8s -> 502s for the same 2M-row write with a 10ms sampler on a ~1GB heap).
# The transform adds no data structure that grows with the table — the
# streaming memory profile is the unchanged write_inserts one — so
# before/after RSS plus the allocation counts tell the story.
def measure(label)
  GC.start
  before_alloc = GC.stat(:total_allocated_objects)
  before_rss = rss_mb
  result = nil
  wall = realtime { result = yield }
  after_alloc = GC.stat(:total_allocated_objects)
  printf(
    "%-34s  time=%7.3fs  rss_before=%7.1fMB  rss_after=%7.1fMB  alloc=%12d objs\n",
    label, wall, before_rss, rss_mb, after_alloc - before_alloc
  )
  [result, wall]
end

def microbench(label, n)
  t = realtime { n.times { yield } }
  printf("  %-40s %7.3fs total  %8.3f us/op\n", label, t, t / n * 1_000_000)
end

# Rows shaped like driver output (String|nil values), frozen so each variant
# can stream the same array without cross-variant mutation.
def build_row(i)
  [
    i.to_s,
    "masked-name-#{i}",
    "user#{i}@example.com",
    "Some representative bio text for record #{i}; it isn't short and includes a quote.",
    (i.even? ? 'active' : 'inactive'),
    "#{i}.45",
    '2026-06-19 12:00:00',
    '2026-06-19 12:00:00',
  ].map(&:freeze).freeze
end

def build_table(extra_by_column = {})
  Exwiw::TableConfig.from(
    'name' => 'bench_records',
    'primary_key' => 'id',
    'columns' => COLUMNS.map { |c| { 'name' => c }.merge(extra_by_column.fetch(c, {})) },
  )
end

VARIANTS = {
  'baseline (no transform)' => {},
  'map x1 (email)' => {
    'email' => { 'map' => %q(proc { |r| 'user' + r['id'].to_s + '@masked.example' }) },
  },
  'fake x1 (email)' => {
    'email' => { 'replace_with_fake_data' => { 'seed' => 'id', 'type' => 'email' } },
  },
  'fake x3 (name/email/bio)' => {
    'name' => { 'replace_with_fake_data' => { 'seed' => 'id', 'type' => 'human_name' } },
    'email' => { 'replace_with_fake_data' => { 'seed' => 'id', 'type' => 'email' } },
    'bio' => { 'replace_with_fake_data' => { 'seed' => 'id', 'type' => 'address' } },
  },
}.freeze

logger = Logger.new($stdout)
logger.level = Logger::WARN

sqlite_path = File.join(Dir.tmpdir, 'exwiw_row_transform_bench.sqlite3')
connection_config = Exwiw::ConnectionConfig.new(adapter: 'sqlite', database_name: sqlite_path)
adapter = Exwiw::Adapter.build(connection_config, logger)

puts "=== exwiw row-transform bench (rows=#{ROWS}, faker #{Faker::VERSION}, ruby #{RUBY_VERSION}) ==="
puts

# ---------------------------------------------------------------------------
# Part A: write_inserts over synthesized rows (no DB) — isolated overhead
# ---------------------------------------------------------------------------

out_path = File.join(Dir.tmpdir, 'exwiw_row_transform_bench.sql')

if RUN_PART_A

puts "--- Part A: write_inserts over synthesized rows (no DB) ---"

rows = Array.new(ROWS) { |i| build_row(i) }

# Unmeasured warm pass over the FULL row set so the first measured variant
# does not absorb the one-time costs (Ruby heap expansion for the write
# churn, method caches, page cache for the output file). With a partial warm
# pass the first variant measured ~10-15% slower than the rest from heap
# growth alone.
warm_table = build_table
File.open(out_path, 'w') { |f| adapter.write_inserts(f, rows, warm_table, nil) }

baseline_wall = nil
baseline_size = nil
VARIANTS.each do |label, extra|
  table = build_table(extra)
  transformer = Exwiw::RowTransformer.build(table)
  raise 'baseline must not build a transformer' if extra.empty? && !transformer.nil?

  # Warm the fake pools outside the measurement: a real dump pays this once
  # per (type, locale), not per row. (Pool build is ~0.2s per type.)
  transformer&.wrap([rows.first.dup])&.to_a

  results = transformer ? transformer.wrap(rows) : rows
  _, wall = measure(label) do
    File.open(out_path, 'w') { |f| adapter.write_inserts(f, results, table, nil) }
  end
  if extra.empty?
    baseline_wall = wall
    baseline_size = File.size(out_path)
    # The unused path must be free: wrapping is skipped entirely (nil), so
    # output equality with a plain run is trivially byte-identical.
  else
    per_row = (wall - baseline_wall) / ROWS * 1_000_000
    printf("  -> overhead vs baseline: %+6.1f%%  (%+.3f us/row)\n", (wall / baseline_wall - 1) * 100, per_row)
  end
end
printf("  output size (baseline): %.1fMB\n\n", baseline_size / 1024.0 / 1024.0)
File.delete(out_path)

# ---------------------------------------------------------------------------
# Per-operation microbench
# ---------------------------------------------------------------------------

N = 200_000
puts "=== Per-operation microbench (#{N} iterations) ==="

seed_value = '1234567'
microbench('Digest::SHA256 -> u64 index + hex token', N) do
  digest = Digest::SHA256.digest(seed_value)
  digest[0, 8].unpack1('Q>') % 10_000
  digest[8, 8].unpack1('H*')
end
microbench('Zlib.crc32 (comparison only)', N) { Zlib.crc32(seed_value) % 10_000 }

fake_table = build_table('email' => { 'replace_with_fake_data' => { 'seed' => 'id', 'type' => 'email' } })
fake_transformer = Exwiw::RowTransformer.build(fake_table)
fake_transformer.wrap([build_row(0).dup]).to_a # warm pool
sample = build_row(42)
microbench('fake pipeline (transform 1 row, email)', N) { fake_transformer.transform(sample.dup) }

map_table = build_table('email' => { 'map' => %q(proc { |r| 'user' + r['id'].to_s + '@masked.example' }) })
map_transformer = Exwiw::RowTransformer.build(map_table)
microbench('map dispatch (transform 1 row)', N) { map_transformer.transform(sample.dup) }

# The rejected design: seeding Faker per row instead of the pool. Kept here to
# document why the pool exists.
naive_n = 20_000
microbench("naive per-row Faker::Name.name (#{naive_n} iters)", naive_n) do
  Faker::Config.random = Random.new(1_234_567)
  Faker::Name.name
end
puts

rows = nil # rubocop:disable Lint/UselessAssignment
GC.start

else
  puts '--- Part A + microbench skipped (BENCH_PART_A=0) ---'
end

# ---------------------------------------------------------------------------
# Part B: live sqlite end-to-end (execute + wrap + write_inserts)
# ---------------------------------------------------------------------------

unless RUN_DB
  puts '--- Part B skipped (BENCH_DB=0) ---'
  exit
end

puts '--- Part B: live sqlite end-to-end (execute + wrap + write_inserts) ---'

require 'sqlite3'
File.delete(sqlite_path) if File.exist?(sqlite_path)
db = SQLite3::Database.new(sqlite_path)
db.execute(<<~SQL)
  CREATE TABLE bench_records (
    id INTEGER PRIMARY KEY, name TEXT, email TEXT, bio TEXT,
    status TEXT, amount TEXT, created_at TEXT, updated_at TEXT
  )
SQL
puts "  seeding #{ROWS} rows into #{sqlite_path}..."
insert = db.prepare('INSERT INTO bench_records VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
seed_wall = realtime do
  i = 0
  while i < ROWS
    db.transaction
    [10_000, ROWS - i].min.times do
      insert.execute(build_row(i))
      i += 1
    end
    db.commit
  end
end
insert.close
db.close
printf("  seeded in %.1fs\n", seed_wall)

ast = Exwiw::QueryAst::Select.new
ast.from('bench_records')
ast.select(build_table.columns)

# Unmeasured full warm pass (page cache for the sqlite file + output file,
# heap expansion) — same reasoning as Part A.
File.open(out_path, 'w') { |f| adapter.write_inserts(f, adapter.execute(ast), build_table, nil) }

{ 'baseline (no transform)' => {},
  'fake x1 (email)' => { 'email' => { 'replace_with_fake_data' => { 'seed' => 'id', 'type' => 'email' } } },
}.each do |label, extra|
  table = build_table(extra)
  transformer = Exwiw::RowTransformer.build(table)
  transformer&.wrap([build_row(0).dup])&.to_a # warm pool
  _, wall = measure("E2E #{label}") do
    File.open(out_path, 'w') do |f|
      results = adapter.execute(ast)
      results = transformer.wrap(results) if transformer
      adapter.write_inserts(f, results, table, nil)
    end
  end
  if extra.empty?
    baseline_wall = wall
  else
    printf("  -> E2E overhead vs baseline: %+6.1f%%  (%+.3f us/row)\n",
           (wall / baseline_wall - 1) * 100, (wall - baseline_wall) / ROWS * 1_000_000)
  end
end

File.delete(out_path) if File.exist?(out_path)
File.delete(sqlite_path) if File.exist?(sqlite_path)

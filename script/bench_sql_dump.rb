# frozen_string_literal: true

# Benchmark harness for the SQL (mysql / postgresql / sqlite) dump path.
#
# The SQL adapters drive the same two Runner phases the MongoDB adapter does,
# and — before any SQL-side optimization — carry the same two hotspots the
# MongoDB work removed (see docs/optimization-notes.md):
#
#   1. execute         -- the adapter materializes the ENTIRE result set into
#                         memory (pg: PG::Result#values, mysql2: res.to_a.map,
#                         sqlite3: Database#execute). For a large table this is
#                         a Ruby array-of-arrays as big as the table.
#   2. to_bulk_insert  -- SQL adapters set NO default_bulk_insert_chunk_size, so
#                         the Runner builds the whole table's INSERT as ONE giant
#                         string before writing (one chunk = all rows), held in
#                         memory simultaneously with the result set above.
#
# This harness measures both, so a future iteration can show a SQL-side chunked
# / streaming win the same way the MongoDB bench did (whole-string vs chunked).
#
# Two parts:
#
#   A. Serialization bench (NO database connection needed; still needs `ps`,
#      which the dev sandbox blocks, so disable the sandbox).
#      Synthesizes a result set of the shape the drivers hand back (array of
#      arrays of String|nil) and measures to_bulk_insert + write as ONE giant
#      string (current behavior) vs a STREAMED single INSERT (the bounded-memory
#      alternative). Both emit ONE `INSERT INTO ... VALUES ...;` statement, so
#      the bytes are identical (asserted) — unlike a naive chunk size, which for
#      SQL would split into multiple INSERT statements and change the output.
#      This is the controllable memory lever.
#
#   B. Live-DB execute bench (needs a reachable DB; the dev sandbox blocks
#      localhost, so disable the sandbox for this part). Seeds a synthetic table
#      and measures adapter.execute — the full-result-set materialization cost.
#      Skipped automatically (with a warning) if the DB is unreachable, so part
#      A always produces numbers.
#
# Usage:
#   bundle exec ruby script/bench_sql_dump.rb                 # postgresql, both parts
#   BENCH_ADAPTER=mysql bundle exec ruby script/bench_sql_dump.rb
#   BENCH_ADAPTER=sqlite bundle exec ruby script/bench_sql_dump.rb
#   BENCH_DB=0 bundle exec ruby script/bench_sql_dump.rb      # part A only (sandbox-safe)
#
# Tunables (env):
#   BENCH_ADAPTER   sqlite | mysql | postgresql   (default postgresql)
#   BENCH_ROWS      number of rows                (default 200000)
#   BENCH_DB        "0" to skip the live-DB part  (default run it)
#   BENCH_TABLE     bench table name              (default exwiw_bench_records)

require 'json'
require 'logger'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'exwiw'
require_relative './database_config'

ADAPTER   = ENV.fetch('BENCH_ADAPTER', 'postgresql')
ROWS      = Integer(ENV.fetch('BENCH_ROWS', 200_000))
RUN_DB    = ENV.fetch('BENCH_DB', '1') != '0'
TABLE     = ENV.fetch('BENCH_TABLE', 'exwiw_bench_records')

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
    "%-34s  time=%7.3fs  rss_before=%7.1fMB  rss_peak=%7.1fMB  alloc=%12d objs\n",
    label, wall, before_rss, peak, after_alloc - before_alloc
  )
  result
end

# A representative masked row as the drivers hand it back: every value a String
# (pg text format / mysql2 cast:false) or nil. Includes a single quote so the
# per-value escape work is exercised.
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
  ]
end

logger = Logger.new($stdout)
logger.level = Logger::WARN

cfg = database_config(ADAPTER)
connection_config =
  case ADAPTER
  when 'sqlite'
    Exwiw::ConnectionConfig.new(adapter: 'sqlite', database_name: cfg.fetch(:database))
  else
    Exwiw::ConnectionConfig.new(
      adapter: ADAPTER,
      host: cfg[:host], port: cfg[:port], user: cfg[:username],
      password: cfg[:password], database_name: cfg.fetch(:database)
    )
  end

adapter = Exwiw::Adapter.build(connection_config, logger)

table = Exwiw::TableConfig.from(
  'name' => TABLE,
  'primary_key' => 'id',
  'columns' => COLUMNS.map { |c| { 'name' => c } },
)

puts "=== exwiw SQL dump bench (adapter=#{ADAPTER}, rows=#{ROWS}) ==="
puts "SQL adapter default_bulk_insert_chunk_size = #{adapter.default_bulk_insert_chunk_size.inspect} " \
     "(nil => Runner builds one giant INSERT string per table)"
puts

# ---------------------------------------------------------------------------
# Part A: serialization + write (no database)
# ---------------------------------------------------------------------------

puts "--- Part A: to_bulk_insert + write (synthesized result set, no DB) ---"

rows = Array.new(ROWS) { |i| build_row(i) }

def write_whole(adapter, rows, table, path)
  # Mirrors the Runner with nil chunk_size: the entire table is one chunk, so
  # to_bulk_insert builds the whole INSERT string before it is written.
  File.open(path, 'w') do |file|
    file.print(adapter.to_bulk_insert(rows, table))
    file.print("\n")
  end
end

# The shipped bounded-memory path: the SQL adapters' #write_inserts (mixed in
# from Adapter::SqlBulkInsert) streams the same single
# `INSERT INTO ... VALUES <tuples>;` statement to the file in ~1 MiB buffers, so
# the whole INSERT string (and the per-row String array to_bulk_insert builds) is
# never resident at once. The bytes are identical to to_bulk_insert over the
# whole table (asserted below); the buffer keeps writes coarse so this does NOT
# pay the per-row IO penalty a naive row-at-a-time IO#print would.
def write_streamed(adapter, rows, table, path)
  File.open(path, 'w') do |file|
    adapter.write_inserts(file, rows, table, nil)
    file.print("\n") # match the Runner, which appends a newline after write_inserts
  end
end

# STREAMED first so its peak RSS is not polluted by the whole-string path's
# transient giant String (RSS is sticky — the OS reclaims lazily).
tmp_streamed = File.join(Dir.tmpdir, 'exwiw_sql_bench_streamed.sql')
measure('STREAMED single-INSERT write') { write_streamed(adapter, rows, table, tmp_streamed) }

tmp_whole = File.join(Dir.tmpdir, 'exwiw_sql_bench_whole.sql')
measure('WHOLE-string write (current default)') { write_whole(adapter, rows, table, tmp_whole) }

identical = File.size(tmp_streamed) == File.size(tmp_whole) &&
            File.read(tmp_streamed) == File.read(tmp_whole)
printf("  -> output %.1fMB; streamed/whole byte-identical: %s\n\n",
       File.size(tmp_whole) / 1024.0 / 1024.0, identical.to_s)
File.delete(tmp_streamed)
File.delete(tmp_whole)

# Per-row microbench: isolate the escape + statement-building cost.
sample = build_row(42)
N = 50_000
puts "=== Per-row serialization microbench (#{N} iterations) ==="
def microbench(label, n)
  t = realtime { n.times { yield } }
  printf("  %-32s %7.3fs total  %8.3f us/op\n", label, t, t / n * 1_000_000)
end
microbench('escape_value (one value)', N) { adapter.send(:escape_value, sample[3]) }
microbench('to_bulk_insert(1 row)', N) { adapter.to_bulk_insert([sample], table) }
rows = nil # release before the DB part
GC.start
puts

# ---------------------------------------------------------------------------
# Part B: live-DB execute (needs a reachable DB; disable the sandbox)
# ---------------------------------------------------------------------------

unless RUN_DB
  puts "--- Part B skipped (BENCH_DB=0) ---"
  return
end

puts "--- Part B: adapter.execute (full result-set materialization, live DB) ---"

def reachable?(adapter)
  adapter.send(:connection)
  true
rescue => e
  warn "  DB unreachable (#{e.class}: #{e.message.lines.first&.strip}); skipping Part B."
  warn "  (localhost is blocked under the sandbox — run with the sandbox disabled.)"
  false
end

return unless reachable?(adapter)

# Seed a synthetic table directly through the adapter's raw connection.
def seed!(adapter, kind, table, rows)
  conn = adapter.send(:connection)
  ddl_cols = "id BIGINT PRIMARY KEY, name TEXT, email TEXT, bio TEXT, status TEXT, amount NUMERIC, created_at TEXT, updated_at TEXT"

  case kind
  when 'postgresql'
    conn.exec("DROP TABLE IF EXISTS #{table}")
    conn.exec("CREATE TABLE #{table} (#{ddl_cols})")
    conn.copy_data("COPY #{table} (#{COLUMNS.join(', ')}) FROM STDIN") do
      rows.each { |r| conn.put_copy_data(r.join("\t") + "\n") }
    end
  when 'mysql'
    raw = conn.send(:raw)
    raw.query("DROP TABLE IF EXISTS #{table}")
    raw.query("CREATE TABLE #{table} (#{ddl_cols.sub('TEXT', 'VARCHAR(255)')})")
    rows.each_slice(5_000) do |slice|
      values = slice.map { |r| '(' + r.map { |v| "'#{v.gsub("'", "''")}'" }.join(', ') + ')' }.join(',')
      raw.query("INSERT INTO #{table} (#{COLUMNS.join(', ')}) VALUES #{values}")
    end
  when 'sqlite'
    conn.execute("DROP TABLE IF EXISTS #{table}")
    conn.execute("CREATE TABLE #{table} (#{ddl_cols})")
    conn.transaction do
      stmt = conn.prepare("INSERT INTO #{table} (#{COLUMNS.join(', ')}) VALUES (#{(['?'] * COLUMNS.size).join(', ')})")
      rows.each { |r| stmt.execute(r) }
      stmt.close
    end
  end
end

def drop!(adapter, kind, table)
  conn = adapter.send(:connection)
  case kind
  when 'postgresql' then conn.exec("DROP TABLE IF EXISTS #{table}")
  when 'mysql'      then conn.send(:raw).query("DROP TABLE IF EXISTS #{table}")
  when 'sqlite'     then conn.execute("DROP TABLE IF EXISTS #{table}")
  end
end

begin
  seed_rows = Array.new(ROWS) { |i| build_row(i) }
  puts "Seeding #{ROWS} rows into #{TABLE} ..."
  seed_wall = realtime { seed!(adapter, ADAPTER, TABLE, seed_rows) }
  seed_rows = nil
  GC.start
  printf("Seed complete in %.1fs\n\n", seed_wall)

  query = Exwiw::QueryAst::Select.new
  query.from(TABLE)
  query.select(table.columns)

  results = measure('execute (SELECT -> rows in memory)') { adapter.execute(query) }
  puts "  rows materialized: #{results.size}"

  tmp_full = File.join(Dir.tmpdir, 'exwiw_sql_bench_full.sql')
  measure('  + WHOLE-string write') { write_whole(adapter, results, table, tmp_full) }
  File.delete(tmp_full)
ensure
  drop!(adapter, ADAPTER, TABLE)
  puts "\nDone (dropped #{TABLE})."
end

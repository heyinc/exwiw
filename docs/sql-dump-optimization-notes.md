# SQL dump performance: investigation notes

Companion to [`optimization-notes.md`](./optimization-notes.md) (which covers the
MongoDB adapter). This records the speed/memory bottlenecks of the **SQL**
adapters' dump path (mysql / postgresql / sqlite), measured against a baseline,
so a future iteration can address them. **Nothing is fixed yet** — this is the
measurement + bottleneck-analysis step.

The reproducible harness is `script/bench_sql_dump.rb`. It seeds a synthetic
table and measures the two Runner phases per table; it also measures the
serialization step with no DB at all. The correctness anchor for any future fix
is `spec/insert_output_snapshot_spec.rb` — the **byte-exact** snapshot of dump
output.

> **Status:** hotspot #2 (the whole-table INSERT string) is **fixed** — see
> [Resolution](#resolution-hotspot-2-streamed-single-insert) below. Hotspot #1
> (full result-set materialization in `execute`) is still open.

## The two hotspots (same shape as MongoDB had pre-optimization)

The Runner drives, per table:

1. **execute** — the adapter materializes the **entire** result set into a Ruby
   array-of-arrays before anything is written:
   - postgresql: `connection.exec(sql).values`
   - mysql: `res.to_a.map { |row| row.map { stringify } }` (also re-allocates
     every value as a normalized String)
   - sqlite: `connection.execute(sql)`

   Memory here is proportional to the **table size**, independent of any chunking
   downstream.

2. **to_bulk_insert** — SQL adapters set **no** `default_bulk_insert_chunk_size`
   (it is `nil`), so the Runner treats the whole table as one chunk and
   `to_bulk_insert` builds the **entire** `INSERT INTO ... VALUES (...),(...);`
   as one giant String — first an `Array` of N per-row tuple strings, then the
   joined result — held simultaneously with the result set from step 1.

## Baseline (200,000 rows, 8 columns, ~41.2 MB output)

Measured via `bench_sql_dump.rb` (sandbox disabled — it needs `ps` for RSS and
localhost for the live DB). RSS is sticky across in-process phases, so read the
peaks as upper bounds and the *deltas* as the signal.

| adapter | execute peak (Δ) | + whole-string write peak | result-set objs |
|---------|------------------|---------------------------|-----------------|
| postgresql | 471.7 MB (+65)  | 494.0 MB | 1.8M |
| mysql      | 413.4 MB (+52)  | 554.9 MB | 2.4M |
| sqlite     | 434.5 MB        | 526.6 MB | 1.4M |

For a **41 MB** dump the process peaks near **0.5 GB** — ~12× the output size —
because the full result set *and* the whole-table INSERT string are resident at
once. Both costs scale linearly with the table, so a large table OOMs the same
way the embed-heavy MongoDB collection did.

Per-value serialization is cheap and not the bottleneck: `escape_value` is
~0.4–1.3 µs/op and a one-row `to_bulk_insert` ~5.5 µs/op. The cost is **memory**
(holding everything at once), not CPU.

## The byte-identity catch (why this differs from MongoDB)

MongoDB's fix was a `default_bulk_insert_chunk_size`, which is byte-identical
because JSONL chunks join with the same `"\n"` `to_bulk_insert` already inserts
between docs. **That does not transfer to SQL.** Each `to_bulk_insert` call wraps
its rows in its own `INSERT INTO ... VALUES ...;` statement, so a chunk size > 0
turns one INSERT into *many* INSERT statements — semantically equivalent on
re-import, but a **different byte stream** that breaks the snapshot guard.

The byte-identical lever for SQL is instead to **stream the tuples into a single
INSERT statement**: emit the adapter's exact `INSERT ... VALUES\n` header once,
then write each row's `(...)` tuple (reusing the adapter's own `escape_value`)
separated by `",\n"`, then `;`. The bench implements this as `write_streamed`
and asserts byte-for-byte identity with the whole-string path — confirmed
**true** for all three adapters (the header must reuse the adapter's quoting,
e.g. MySQL's backticks, or it diverges).

`write_streamed` cuts the to_bulk_insert peak by ~110–120 MB, **but** naive
per-row `IO#print` makes it ~2–2.4× slower than building one string and writing
it once. So the production fix wants **chunk-buffered streaming**: build an
N-row substring in memory, write it, repeat — managing the `",\n"` separator
across chunk boundaries — to bound memory *without* the per-row IO penalty,
while still emitting a single INSERT statement (byte-identical).

## Resolution: hotspot #2 (streamed single INSERT)

Implemented. The Runner no longer builds the per-table INSERT as one giant
String; it delegates writing to a new adapter seam `Adapter#write_inserts(io,
results, table, chunk_size)`:

- `Adapter::Base#write_inserts` keeps the old behavior (write `to_bulk_insert`
  per chunk, joined by `"\n"`), so MongoDB and any future adapter are unchanged.
- The SQL adapters mix in `Adapter::SqlBulkInsert`, which **streams** the single
  `INSERT INTO ... VALUES <tuples>;` statement to the file `STREAM_FLUSH_ROWS`
  (2,000) tuples at a time. Each flush is one fast `map`+`join` (the same path
  `to_bulk_insert` uses), and the `",\n"` printed between slices reproduces the
  exact separator between tuples — so the bytes are **identical** to the
  whole-table build. The three duplicate `to_bulk_insert` methods collapsed into
  the shared module; each adapter now only supplies `insert_header` (its
  identifier quoting) and `escape_value`.

Verified byte-for-byte by `spec/insert_output_snapshot_spec.rb` (live DB, all
three adapters) and a flush-boundary sanity check; full suite green.

Measured (`bench_sql_dump.rb`, 200k rows / ~41.2 MB output):

| adapter | whole-string peak | streamed peak | Δ peak |
|---------|-------------------|---------------|--------|
| postgresql | 367 MB | 226 MB | −141 MB |
| mysql      | 325 MB | 214 MB | −111 MB |
| sqlite     | 353 MB | 207 MB | −146 MB |

So hotspot #2's contribution (~110–145 MB on a 41 MB dump — the whole INSERT
string *plus* the transient 200k-tuple `Array` and its join) is gone; the write
buffer is now bounded to ~2,000 tuples regardless of table size.

**Speed:** streaming is *not* slower than the whole-string build. Measured in
isolation (post-`GC.start`, no sampler thread) the streamed write at
`flush_rows=2000` was ~0.67 s vs ~0.83 s for the one giant `map`+`join` — small
chunks stay in cache and avoid repeatedly growing/copying a 41 MB String. The
~1.3× "slowdown" the in-process bench shows is an artifact of its background RSS
sampler thread (`ps` every 10 ms) plus run-ordering (streamed runs first, cold),
not the algorithm. The earlier worry about a per-row `IO#print` penalty only
applied to the naive row-at-a-time prototype, which `flush_rows` slicing avoids.

## Fix direction for the next iteration

1. ~~**Bounded-memory write.**~~ **Done** — see Resolution above.
2. **Streaming result fetch (removes hotspot #1, more invasive).** Avoid
   materializing the whole result set: mysql2 supports `stream: true`
   (`cache_rows: false`), pg supports single-row mode (`set_single_row_mode` /
   `get_result`). sqlite3 has no streaming cursor API, so it would keep the
   current behavior. This is the larger, per-driver change and mirrors the
   MongoDB `StreamingResult` work.

## Methodology notes

- The serialization hotspot reproduces **with no database** (Part A): synthesize
  the array-of-String-arrays the drivers return and measure `to_bulk_insert`.
  The live-DB part (Part B) measures `execute` and needs a reachable DB; the dev
  sandbox blocks localhost (and `ps`), so disable the sandbox for bench runs.
- Run order matters: the bench measures the STREAMED path **before** the WHOLE
  path so the transient giant String doesn't pollute the streamed peak (RSS is
  reclaimed lazily). For defensible absolute numbers, isolate phases in fresh
  processes.
- Ruby 4.0 removed the `benchmark` stdlib; the harness uses
  `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.

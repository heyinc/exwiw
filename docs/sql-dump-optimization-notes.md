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

## Fix direction for the next iteration

1. **Bounded-memory write (high value, byte-identical, lower risk).** Add an
   adapter seam that streams one INSERT statement to the open file in row-chunks
   instead of returning one giant String, and have the Runner use it for SQL.
   Removes hotspot #2. Verified against `insert_output_snapshot_spec`.
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

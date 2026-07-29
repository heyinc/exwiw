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

> **Status:** **both hotspots are fixed for all three SQL adapters.** Hotspot #2
> (the whole-table INSERT string) — see
> [Resolution #2](#resolution-hotspot-2-streamed-single-insert). Hotspot #1
> (full result-set materialization in `execute`) — postgresql, mysql, and sqlite
> all stream the fetch now; see
> [Resolution #1](#resolution-hotspot-1-streaming-fetch-postgresql--mysql).

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
   (it was `nil` at measurement time; since then the default is 10_000 —
   large tables emit multiple bounded INSERT statements), so at the time the Runner treats the whole table as one chunk and
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

## Resolution: hotspot #1 (streaming fetch, postgresql + mysql)

Implemented for **postgresql**. `PostgresqlAdapter#execute` no longer returns
`connection.exec(sql).values` (the whole result set as a Ruby array-of-arrays);
it returns a lazy `PostgresqlAdapter::StreamingResult` that pulls rows off the
wire one at a time via libpq **single-row mode** (`send_query` +
`set_single_row_mode` + a `get_result` loop, each yielding one row's
text-format `Array<String|nil>`). The Runner drives it exactly like the old
array — `#size` then a single `each_slice` pass — so nothing else changed and
the output is byte-identical (verified by `insert_output_snapshot_spec`, both
the `insert` and `copy` pg scenarios).

It mirrors `MongodbAdapter::StreamingResult`, with two SQL-specific points:

- **`#size`** can't be answered cheaply from the cursor, so it runs a separate
  `SELECT COUNT(*) FROM (<query>) AS exwiw_count_src` (comment-prefixed, like
  the data query). Postgres prunes the wrapped subquery's unused projection, so
  the COUNT transfers no row data — but it does re-run the query plan. This is
  the deliberate cost of keeping the Runner contract (`#size` before iteration,
  used to skip empty tables and log the count) unchanged, so MongoDB and the
  other SQL adapters are untouched. (MongoDB's `count_documents` is an
  index-only walk and cheaper; the SQL COUNT is the analogue.)
- the streaming pass ties up the connection until fully drained. The Runner
  always drains it (`write_inserts`) before issuing `post_insert_sql` / DELETE
  on the same connection, so the ordering holds. `StreamingResult#each` also
  drains any queued results if iteration is abandoned mid-stream (a SQL error
  surfaced by `#check`, or the consumer raising), so the connection stays
  usable.

Measured in **isolated fresh processes** (one per path, so the peak is not
polluted by other phases — RSS is sticky), 200k rows / ~41.2 MB output:

| pg fetch path | peak RSS | Δ over baseline |
|---------------|----------|-----------------|
| materialize (`exec(sql).values`) + streamed write (OLD) | ~360 MB | ~320 MB |
| **single-row stream + streamed write (NEW)** | **~48 MB** | **~12 MB** |

So the full result set (~320 MB of Ruby strings/arrays for 200k×8) is no longer
resident: peak drops ~**310 MB (~87%)** and is now *below* the 41 MB output
size, because the row is pulled one at a time and the write buffer is bounded to
~2,000 tuples (hotspot #2's fix). Speed is unchanged (~1.8 s both paths on the
in-process bench; the COUNT is cheap on an indexed seed). The reproducible A/B
is in `bench_sql_dump.rb` Part B (`execute(stream)` vs `execute(materialize)`,
with a byte-identity assertion).

Implemented for **mysql** too. `MysqlAdapter#execute` now returns a
`MysqlAdapter::StreamingResult` (an Enumerable mirroring the pg one) instead of
`connection.query(sql).rows`. The new `MysqlClient#stream_rows` pulls rows off
the wire one at a time via mysql2's server-side stream (`stream: true` +
`cache_rows: false`), yielding the same `Array<String|nil>` rows `#query`
buffered — so the generated INSERT is byte-identical (verified by
`insert_output_snapshot_spec`).

Two MySQL specifics differ from the pg path:

- **`#size`** is a separate `SELECT COUNT(*)` of the same query, but **not** a
  subquery wrap. MySQL rejects a derived table with duplicate column names,
  which a rails-managed `SELECT *` joined to another table produces
  (`Duplicate column name 'id'`); Postgres tolerates it, MySQL does not. So
  mysql replaces the projection with `COUNT(*)` instead
  (`compile_ast(count_only: true)`) — exact because exwiw's extraction queries
  have no DISTINCT/GROUP BY/LIMIT, so the count is independent of the projected
  columns (confirmed against live data: `COUNT(*)` over the bare FROM/JOIN/WHERE
  equals the streamed row count for both plain and `SELECT *`+join queries).
- **abandoned streams.** mysql2 requires a streamed result to be fully consumed
  before the next query on the connection, or it raises "Commands out of sync".
  `stream_rows` drains the remainder (re-entering `res.each`, which continues
  from where it stopped) if the consumer block raises, so the connection stays
  usable for the next table. `trilogy` has no streaming cursor
  (no `QUERY_FLAGS_STREAMING`), so it buffers and yields — parity, no memory
  win; trilogy is a test-only driver, production uses mysql2.

Measured in **isolated fresh processes** (one per path), 200k rows / ~40.7 MB
output:

| mysql fetch path | peak RSS | Δ over baseline |
|------------------|----------|-----------------|
| materialize (`query(sql).rows`) + streamed write (OLD) | ~340 MB | ~300 MB |
| **single-row stream + streamed write (NEW)** | **~50 MB** | **~10 MB** |

So peak drops ~**290 MB (~85%)**, now just above the 40.7 MB output — the same
shape as the pg result. Speed is unchanged-to-faster (the materialize path also
builds the whole array first). `bench_sql_dump.rb` Part B now shows the delta
for mysql too (it was equivalent before, when mysql still materialized).

Implemented for **sqlite** too, closing hotspot #1 for all three SQL adapters.
`SqliteAdapter#execute` no longer returns `connection.execute(sql)` (which
buffers the whole result into a Ruby array); it returns a
`SqliteAdapter::StreamingResult` (Enumerable, mirroring the pg/mysql ones) whose
`#each` walks the result one row at a time through SQLite's **statement cursor**
— `connection.prepare(data_sql)` then `Statement#each` (which maps to
`sqlite3_step`), closing the statement in an `ensure` so an abandoned mid-stream
iteration still releases the cursor. The rows are the same `Array` of
native-typed values `Database#execute` produced, so the generated INSERT is
byte-identical (verified by `insert_output_snapshot_spec` and a direct cursor
vs. `#execute` comparison).

SQLite specifics vs. the pg/mysql paths:

- **`#size`** runs a separate `SELECT COUNT(*)` of the same query with the
  projection replaced by `COUNT(*)` (`compile_ast(count_only: true)`, the same
  trick mysql uses) — exact because exwiw's extraction queries have no
  DISTINCT/GROUP BY/LIMIT. SQLite would also tolerate a duplicate-column
  subquery wrap (unlike mysql), but the `count_only` form is shared and avoids
  the extra subquery.
- **no connection contention.** SQLite is an embedded, single-connection engine
  that allows multiple active prepared statements at once, so the `#size` COUNT
  and the data cursor don't fight over the connection the way the pg/mysql
  single-row streams tie up the wire. No drain dance is needed; just close the
  statement.

Measured in **isolated fresh processes** (one per path), 200k rows / ~40.5 MB
output:

| sqlite fetch path | peak RSS | Δ over baseline |
|-------------------|----------|-----------------|
| materialize (`Database#execute`) + streamed write (OLD) | ~298 MB | ~257 MB |
| **statement-cursor stream + streamed write (NEW)** | **~59 MB** | **~18 MB** |

So peak drops ~**240 MB (~80%)**, the same shape as pg/mysql, and it is
**faster** (~0.84 s vs ~1.68 s) — the materialize path pays to build the whole
Ruby array up front, the cursor does not. `bench_sql_dump.rb` Part B now shows a
real delta for sqlite too (it was equivalent before, when sqlite still
materialized).

## Status: both hotspots closed for all three SQL adapters

1. **Bounded-memory write** (hotspot #2) — done for mysql / postgresql / sqlite;
   see [Resolution #2](#resolution-hotspot-2-streamed-single-insert).
2. **Streaming result fetch** (hotspot #1) — done for postgresql (libpq
   single-row mode), mysql (mysql2 `stream: true`), and sqlite (statement
   cursor); see Resolution #1 above.

There is no remaining materialization hotspot in the SQL dump path: peak RSS is
now bounded (well below the output size) and independent of table size for every
SQL adapter, the same property the MongoDB streaming work achieved. The
`trilogy` driver still buffers (it has no streaming cursor flag), but it is a
test-only driver — production mysql uses mysql2.

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

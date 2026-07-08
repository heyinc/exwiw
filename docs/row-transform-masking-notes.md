# Ruby-side masking (`map` / `replace_with_fake_data`): design & benchmark notes

Companion to [`sql-dump-optimization-notes.md`](./sql-dump-optimization-notes.md).
That document records how the SQL dump path became a bounded-memory streaming
pipeline; this one records the cost of the first **per-row Ruby work** added on
top of it — the `RowTransformer` that implements the `map` and
`replace_with_fake_data` masking modes — and the design decisions the numbers
drove.

The reproducible harness is `script/bench_row_transform.rb`. The correctness
anchors are `spec/row_transformer_spec.rb` (determinism contract) and
`spec/insert_output_snapshot_spec.rb` (byte-exact output for `map`).

## Why these modes cost anything at all

`replace_with` / `raw_sql` compile into the `SELECT` and run **in the
database**; the Ruby pipeline (streaming fetch → `write_inserts`) previously
did zero per-row transform work. `map` (arbitrary Ruby proc) and
`replace_with_fake_data` (faker values) cannot be pushed into SQL, so they run
in the exwiw process, per row, between the cursor and the INSERT/COPY writer:

```
adapter.execute --> StreamingResult --(RowTransformer::TransformedResult#each)--> write_inserts / to_copy_from_stdin
```

The wrapper delegates `#size` (so the COPY path's upfront count and
`each_slice`'s allocation-hint COUNT are unchanged) and transforms rows one at
a time off `#each`, so the bounded-memory profile of the streaming dump is
preserved. When no column opts in, `RowTransformer.build` returns nil and the
pipeline is byte-for-byte the pre-existing one.

## Design decisions the measurements drove

### Fake values come from a pre-generated pool, not per-row faker calls

A naive deterministic design — per row, seed faker's RNG with the hash and
call the generator —

```ruby
Faker::Config.random = Random.new(seed_hash)
Faker::Name.name
```

measures **~30 µs/row** (I18n lookups + regex templating per call). At 5M rows
that is ~150 s for one column: unacceptable.

Instead, `RowTransformer` pre-generates a pool of `POOL_SIZE = 10_000`
candidate values per `(type, locale)` under a fixed RNG seed (~0.2 s, once),
and per row only hashes the seed value and indexes the pool:

```ruby
digest = Digest::SHA256.digest(seed_value.to_s)
pool[digest[0, 8].unpack1("Q>") % POOL_SIZE]
```

That is ~1.4 µs/row — **~21× cheaper** — and just as deterministic (values are
stable for a given faker version + locale; the pool regenerates identically).

### One SHA-256 digest supplies both the pool index and the uniqueness token

`Zlib.crc32` is ~16× faster than SHA-256 (0.055 vs 0.87 µs/op), but 32 bits is
unusable for the uniqueness token the `email`/`username` types embed: a
birthday collision is even money at ~77k distinct seeds, far below the
multi-million-row target. One SHA-256 per row provides 64 bits for the pool
index (bytes 0–7) and an independent 64-bit hex token (bytes 8–15) whose
collision probability at 5M distinct seeds is ≈ 7e-7. The hash is not the
bottleneck (see numbers below), so there is no fast-path variant.

### Zero-allocation row accessor for `map`

The proc receives a single reused accessor object (`r['column']` resolves
through a frozen name→index Hash built once per table), not a per-row Hash of
the whole row. Replacements are computed from the original row before any is
written back, so transformed columns can read each other's *pre*-transform
values regardless of column order. Rows are mutated in place when the driver
allows it; sqlite3's `Statement#each` yields **frozen** rows, which are duped
first (the one extra allocation on that adapter).

## Measurements

Environment: Apple Silicon (arm64, 64 GB), Ruby 4.0.5, faker 3.8.0, sqlite
adapter for serialization. 8-column rows, ~211 B/row of output. Run:

```bash
BENCH_ROWS=2000000 bundle exec ruby script/bench_row_transform.rb
BENCH_ROWS=5000000 BENCH_PART_A=0 bundle exec ruby script/bench_row_transform.rb  # E2E only
```

### Part A — serialization path only (2M rows, 422 MB output)

The rows are pre-materialized, so the delta is exactly the transform cost on
the `write_inserts` path — the *most pessimistic* relative view, since a real
dump also pays the DB fetch.

| variant | wall | vs baseline | per row |
|---|---|---|---|
| baseline (no transform) | 6.99 s (286k rows/s) | — | — |
| `map` ×1 column | 8.27 s | +18% | +0.64 µs |
| fake ×1 column (email) | 10.17 s | +45% | +1.59 µs |
| fake ×3 columns | 13.85 s | +98% | +3.43 µs (~1.1 µs/col) |

### Per-operation microbench

| operation | µs/op |
|---|---|
| SHA-256 digest → u64 index + hex token | 0.87 |
| `Zlib.crc32` (comparison only) | 0.055 |
| fake pipeline, transform 1 row (email) | 1.42 |
| `map` dispatch, transform 1 row | 0.83 |
| naive per-row `Faker::Name.name` (rejected design) | ~30 |

### Part B — end-to-end against live sqlite (5M rows, ~1.06 GB output)

`execute` + wrap + `write_inserts`, fresh process (`BENCH_PART_A=0`; see
pitfalls below):

| variant | wall | vs baseline | per row |
|---|---|---|---|
| baseline | 19.97 s (250k rows/s) | — | — |
| fake ×1 column (email) | 27.98 s | +40% | +1.60 µs |

RSS stayed flat at ~70–100 MB for both variants across the whole 5M-row /
1 GB dump — the transform does not disturb the streaming memory profile.

The 2M-row E2E run reproduces the same per-row cost (+1.55 µs/row).

### Reading the numbers

- **The stable metric is µs/row per masked column**: ~0.6–0.8 µs for `map`
  (plus whatever the user's proc does), ~1.5–1.6 µs for fake data
  (SHA-256 + pool lookup + compose + the sqlite frozen-row dup).
- At **5M rows, one fake column costs ~8 s** of wall clock.
- The relative percentages above are worst-case: a local sqlite fetch is the
  fastest possible source (baseline ~4 µs/row), so +1.6 µs reads as +40%.
  Against a network mysql/postgresql source the same absolute overhead is a
  much smaller fraction; on the fully-diluted end (2M E2E measured in a
  process with a large heap) it read as +21%. Unused tables/columns cost
  exactly zero (`build` returns nil; nothing is wrapped).

## Benchmarking pitfalls found on the way

Recorded because both would silently corrupt a rerun:

1. **A 10 ms `ps` RSS sampler is catastrophic on a large heap.** The
   `script/bench_sql_dump.rb`-style background sampler forks the whole process
   per sample; with the ~1 GB rows array a 2M-row `write_inserts` went from
   10.8 s to **502 s**. This script reports before/after RSS (2 forks per
   phase) instead; peak-transient capture matters less here because the
   transform adds no table-sized structure.
2. **The first measured variant absorbs one-time heap expansion.** With only a
   partial warm pass, the baseline (measured first) ran ~15% slower than the
   later variants — enough to make `map` appear *faster* than no transform.
   The script now does a full-size unmeasured warm pass first. Relatedly,
   running Part A's materialized array before Part B in one process inflates
   Part B's GC costs (the 5M E2E overhead read +6.0 µs/row instead of
   +1.6 µs/row); hence `BENCH_PART_A=0` for clean E2E numbers.

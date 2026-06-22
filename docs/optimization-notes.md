# MongoDB dump performance: investigation notes

This records what was learned while making the MongoDB adapter's dump faster and
lighter, **what shipped**, and **what was explored and deliberately removed**.
It exists so the removed work isn't re-discovered from scratch and so the
trade-offs behind the current design are legible.

The reproducible harness is `script/bench_mongodb_dump.rb` (seeds a synthetic
large/embed-heavy dataset and measures the dump phases). The correctness anchor
throughout is `spec/insert_output_snapshot_spec.rb` — a **byte-exact** snapshot
of the dump output; every change below was required to keep it green.

## The two hotspots

On an embed-heavy benchmark (20k users × 30 embedded posts → ~154 MB JSONL):

1. **Memory.** Two compounding costs. `MongodbAdapter#execute` did `.to_a`,
   loading the entire result set onto the heap (~600–900 MB / ~9.5M Ruby
   objects for 20k docs). Separately, with no chunking the Runner built the whole
   collection's JSONL output as **one giant string** before writing, held
   simultaneously with the result set.
2. **CPU.** `doc.as_extended_json(mode: :relaxed)` is ~82% of per-document
   serialization (~104µs of ~124µs for a 30-post doc). It recursively rebuilds
   the document into a new intermediate Hash tree, so cost scales with embedding
   depth/count; `JSON.generate` over that tree is comparatively cheap (~10µs).

## What shipped (default, no flags, byte-identical)

- **Chunked output streaming.** The Runner writes each bulk-insert chunk straight
  to the file instead of joining the whole table's output into one string.
  `MongodbAdapter` sets a positive `default_bulk_insert_chunk_size` (1000) so
  MongoDB output is chunked by default while SQL adapters keep one statement per
  table. Cut peak RSS ~112 MB and was ~30% faster, byte-identical.
- **Streaming result set.** `#execute` returns a lazy `StreamingResult` wrapping
  the Mongo cursor instead of `.to_a`. The Runner pulls documents through
  `each_slice`, so only one chunk is resident at a time. `#size` is answered with
  a cheap `count_documents` (index-only) rather than draining the cursor, and the
  FK-propagation `@state` is captured *as the cursor streams* and published once
  the pass completes (the Runner always fully consumes a non-empty result, so
  propagation is unaffected). Cut peak RSS growth ~360 MB and wall time ~40%.
- **Precompiled masking (`MaskPlan`).** Masking runs over every document **and**
  every embedded subdocument, so per-config decisions (which fields carry a
  `replace_with`, how each template splits, where embedded children live) were
  recomputed many times per document. Compiling a `MaskPlan` once per collection
  config dropped per-document masking ~17–22% and ~35 allocations/doc, scaling
  down with embedding count. Byte-identical.

Net default result: memory is bounded by chunk size rather than collection size,
with a meaningful wall-time improvement and no API/flag surface.

## What was explored and removed

After the memory work, the remaining cost was almost entirely the pure-Ruby
`as_extended_json`. Threads give **zero** speedup (it holds the GVL), and a
hand-rolled pure-Ruby fused encoder is **slower** than `as_extended_json +
JSON.generate` (per-leaf `.to_json` C-call overhead; `JSON.generate` does the
whole tree in one C pass). `bson` 5.2.0 has no native Extended-JSON serializer to
borrow (`to_extended_json` is literally `as_extended_json(**opts).to_json`, all
pure Ruby). That left two levers, both of which were built, measured, and then
**removed for being disproportionately complex**:

### Fork-parallel serialization (`--parallel-workers=N`)

Forked `N` worker processes to serialize contiguous document slices in parallel,
parent concatenating parts in order (byte-identical). The *serialization step*
parallelized ~2–2.5× at 4–8 workers, **but the end-to-end dump speedup was only
~1.1–1.4×** on embed-heavy data. Reason (Amdahl): ~40% of dump wall time is the
**serial Mongo cursor BSON→Ruby decode** in the parent, which serialization
parallelism cannot touch — capping the win — and fork/concat overhead eroded most
of the rest.

### Cursor-parallel fetch (`--cursor-parallel`)

Went further: split each collection into `N` disjoint `_id` ranges, each fetched
by a forked worker with its own connection+cursor, so the **decode** was
parallelized too. Measured byte-identical at ~2.5–5.5× depending on dataset size
— a real, larger win. But it required a lot of machinery:

- `_id`-range partitioning (an index-only scan + range split) — `MongoIdPartitioner`.
- A fork orchestrator writing ordered part files + Marshal'd state sidecars — `ForkedPartWriter`.
- Distributed FK-propagation: each worker captures its range's `@state` slice and
  the parent merges them in range order — `PropagationCapture`.
- A per-worker fresh-connection builder (the Mongo driver is not fork-safe).
- New adapter seams (`write_bulk_insert`, `write_inserts`) and CLI→Runner→Adapter
  threading for two flags + their validations.
- A user-visible caveat: per-range cursors must `sort(_id)`, so the output is
  **ordered by `_id` rather than natural order** — a different byte stream
  (semantically equivalent re-import), so it could not be the snapshot-tested
  default.

### Why both were removed

The cursor-parallel win was real but bought with multi-process orchestration,
IPC, distributed state, a fresh-connection-per-worker requirement, fork
fallbacks for Windows/JRuby, and a non-default output ordering — a large,
permanently-maintained surface for a single adapter's export path. The
maintainer's call was that this is **over-engineered** for the benefit, and that
the CPU hotspot is better addressed by the lever every earlier iteration kept
pointing at: a native (C) Extended-JSON encoder. The memory wins above are
unrelated to the parallelism and were kept.

## Where the speedup goes next

A C extension can collapse `as_extended_json + JSON.generate` into one native
tree-walk (no intermediate tree, no second pass), as a flag-free, fork-free,
single-process win — bounded by the same serial-decode ceiling (~2.5×) the
`--parallel-workers` path hit, since it also doesn't touch the driver's decode.
The full design (byte-identity strategy, fast-path vs Ruby-delegate types,
optional-load + pure-Ruby fallback, packaging) is in
[`optimize-mongodb-export-with-native-ext.md`](./optimize-mongodb-export-with-native-ext.md).

The native ext shipped (0.6.1+) and the dump is now **decode-bound** (the driver's
BSON→Ruby decode is 64–92 % of per-collection cost). The single-process levers are
exhausted short of 2×. The lever that *was* measured past 2× — **byte-identical
inter-collection fork parallelism** (parallelize whole collections across
processes, so the decode itself runs in parallel while each collection keeps its
natural order) — is written up in
[`mongodb-dump-parallelism-2x-notes.md`](./mongodb-dump-parallelism-2x-notes.md).
Unlike the `--parallel-workers` attempt removed above (which parallelized
serialization only and so was capped at ~1.4×), this parallelizes the actual
bottleneck and reaches ~2.1× wall / ~2.5× compute on a real extraction, given
≥4 vCPU to spend.

## Methodology notes (for re-running)

- The CPU hotspot reproduces **with no database**: the Mongo driver hands back
  plain Ruby `Hash` + `BSON::ObjectId`/`Time`, so synthesizing that shape in
  memory yields the exact `as_extended_json + JSON.generate` cost and runs under
  the normal sandbox. DB-touching measurement needs live mongo on `localhost:27017`
  (the dev sandbox blocks it — disable the sandbox for those runs).
- In-process sequential bench passes accumulate RSS (Ruby reclaims to the OS
  lazily), which inflates a later serial baseline and overstates a parallel
  speedup; isolate sections in fresh processes for defensible numbers.
- Chunk size never changes output **bytes** — the Runner inserts the same `"\n"`
  between chunks that `to_bulk_insert` inserts between documents — so it is purely
  a memory/throughput knob, safe against the snapshot guard.
- Ruby 4.0 removed the `benchmark` stdlib from default gems; use
  `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.

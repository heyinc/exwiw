# MongoDB dump: reaching the 2× target with inter-collection fork parallelism

This continues [`optimization-notes.md`](./optimization-notes.md). That document
ends at "the remaining cost is the serial BSON→Ruby decode, and the lever left is
a native encoder bounded by the same serial-decode ceiling." This note records a
**different** lever that was measured to clear a **2× end-to-end** target on a
large real extraction, **byte-identically**, and explains why it succeeds where
the previously-removed `--parallel-workers` did not.

The measurements below are from a large staging extraction (~300 non-empty
collections, target → 1 store → ~hundreds of scoped rows, plus reference/master
data dumped in full). Reproduce with the bench harness against a restored backup
(see [`mongodb-scoping-fullscan-notes.md`](./mongodb-scoping-fullscan-notes.md)
for serving a WiredTiger backup as a standalone `mongod`).

## Where the time goes (warm cache, native ext compiled)

Serial baseline ≈ **6.8–7.0 s**. Per-collection instrumentation (wrapping
`build_query` / `execute` / `write_inserts`) attributes ~6.0 s to the write pass.
Splitting one collection's write pass into "drain the cursor only" vs
"drain + native-encode" shows **decode is 64–92 %** of per-collection cost — the
Mongo driver's BSON→Ruby-Hash decode dominates; the native Extended-JSON encode is
already cheap. The single heaviest collection (a 237k-doc reference table) is
**1.31 s by itself** and cannot be split without intra-collection partitioning.

Classifying every processed collection by how it is scoped (using the
genuine-anchor model from `mongodb-scoping-fullscan-notes.md`) gives three groups
with very different dependency shapes:

| group | meaning | count | time |
|---|---|---|---|
| **leaf** | no `belongs_to` → dumped in full, no input deps | 54 | ~3.5 s |
| **genuine** | reachable to the dump target via `belongs_to` (the scoped DAG) | 245 | ~0.8 s |
| **ref_bt** | has `belongs_to` but NOT reachable to target (reference data scoped by strict-AND fallback) | 23 | ~2.1 s |

The crucial structural facts, all derivable from the configs:

- **genuine never consumes leaf/ref_bt `@state`.** A genuine collection drops its
  reference (leaf) parents when it has a genuine anchor, and a ref_bt parent is by
  definition not genuine. So the whole scoped DAG is independent of the heavy
  reference dumps — it can run **concurrently** with them.
- **leaf has no input deps at all** (no `belongs_to`) → embarrassingly parallel.
- **ref_bt consumes only leaf `@state` and other ref_bt `@state`** (never genuine).
  Its internal edges form shallow weakly-connected components.

## Why process-level (not thread/serialization) parallelism is the right lever

`optimization-notes.md` removed two parallelism attempts. The distinction that
matters:

- `--parallel-workers` parallelized **serialization only** (the parent still did
  the single serial cursor decode), so it was capped at ~1.1–1.4× — decode is the
  bottleneck and it was untouched.
- `--cursor-parallel` parallelized **decode within a collection** (≈2.5–5.5×) but
  forced `sort(_id)`, changing row order → not byte-identical, could not be the
  default.

Forking **whole collections** across processes parallelizes the decode (each
worker decodes its own collections) **while preserving each collection's natural
order** — so it is both decode-parallel and byte-identical. That is the property
neither removed approach had.

## The schedule that was measured at ≥2×

One parent process plus a fork pool of `N` workers:

1. **Phase 1 (concurrent).** Fork the leaf pool (`N` workers, leaves assigned by
   LPT bin-packing on output-size weight so the 1.31 s collection sits alone).
   Concurrently the parent (a) dumps the schema (parent-only, needs no `@state`)
   and (b) processes the **whole genuine DAG optimistically** — without leaf
   `@state` yet — recording each collection's row count.
2. **Barrier + leaf `@state`.** Wait for the leaf pool; load the small Marshal
   sidecars each consumed leaf wrote (only the ~11 leaves a downstream collection
   references need one; the heavy 1.31 s table is not referenced, so no sidecar).
3. **Phase 2 (cascade reprocess).** Only **8** genuine collections reference a leaf
   at all, and **0** are statically forced to use it — a genuine collection only
   falls back to a leaf clause at runtime when its genuine anchor turns out empty
   (e.g. an empty intermediate parent). Reprocess those 8 with leaf `@state` now
   present; if a reprocessed collection's row count changes, enqueue its genuine
   children and repeat. Non-fallback collections (e.g. the DAG root one level below
   the dump target, which has a genuine anchor and drops its leaf parents)
   reprocess to an identical result and stop the cascade,
   so this terminates after re-touching only the genuinely affected handful.
4. **Phase 3 (ref_bt components).** Fork the 23 ref_bt collections as
   **dependency-closed weakly-connected components** (over intra-ref_bt edges) in a
   single pool — no level barriers, no cross-worker IPC. Each worker owns whole
   components and processes their members in topological order, seeded with the
   (sliced) leaf `@state` its members reference. Components are assigned by LPT.

`@state` IPC is just Marshal sidecars for the ~11 referenced leaves; everything
else is COW-inherited at fork or kept inside a component.

## Measured result (warm cache, same backup)

Internal compute timer (excludes the fixed ~0.5 s Ruby/bundler startup both paths
pay):

| workers | compute | speedup |
|---|---|---|
| serial | 7.01 s | 1.00× |
| N=2 | 3.87 s | 1.81× |
| N=4 | 2.80 s | **2.50×** |
| N=6 | 2.79 s | **2.51×** |

Full wall-clock (includes Ruby startup — the honest end-to-end number):

| workers | wall | speedup |
|---|---|---|
| serial | 6.79 s | 1.00× |
| N=2 | 4.06 s | 1.67× |
| N=4 | 3.24 s | **2.10×** |
| N=6 | 3.21 s | **2.12×** |

**Byte-identical:** all 189 output files (schema + inserts) match the serial run
exactly — same filenames (the insert index is taken over the full ordering,
including `ignore:true` collections, exactly as the Runner numbers them) and same
content (0/189 cmp mismatches).

The curve **saturates at N≈4**: past that the wall time is bounded by the single
1.31 s leaf decode plus the longest ref_bt chain (~0.6 s) plus startup. Going
beyond ~2.5× needs **intra-collection** decode parallelism (the `_id`-range cursor
split that was removed for changing row order) or a **native BSON→Extended-JSON
transcoder** that skips the Ruby-Hash decode for unmasked reference collections
(decode being 64–92 % of the cost, this is the largest single-process lever left
and composes with the fork approach).

## Operational note: this needs vCPUs to spend

The win is real cores doing real decode in parallel. On the current ECS task
(`cpu: 2048` = **2 vCPU**) the schedule reaches only ~1.67× (N=2). Clearing 2×
requires scaling to **≥4 vCPU** (`cpu: 4096`); 8 vCPU does not help further given
the N≈4 saturation. Memory is unchanged — the existing streaming keeps each worker
bounded by chunk size, and `N×` that stays well under the 7 GiB container limit.

## Status

**Integrated and shipped behind an opt-in flag.** The schedule lives in
`Exwiw::MongodbParallelPlan` (the static, DB-free classification) and
`Exwiw::MongodbParallelDumper` (the fork orchestrator: per-group pools, LPT
bin-packing, the `@state` Marshal-sidecar IPC, and the Phase-2 cascade). The
`Runner` delegates the whole schema+inserts pass to the dumper when the mongodb
adapter is used with `--parallel-workers=N` (N≥2), a genuine-anchor dump target is
present, and the runtime can `fork`; otherwise it runs the serial loop unchanged.
The CLI exposes `--parallel-workers` / config-file `parallel_workers` (mongodb +
`export` only). The after-insert hook runs identically on both paths.

End-to-end verification through the real `exwiw export` CLI on the same staging
restore: **189/189 output files byte-identical** to the serial CLI run (same
filenames, 0 content mismatches), at **2.19× wall-clock** (serial 7.13 s → N=4
3.25 s; N=2 3.99 s = 1.81×; N=6 saturates at 3.25 s). Per the curve above the win
materializes from ~4 real cores.

This was the machinery `optimization-notes.md` deliberately removed as
over-engineered for a flag — re-introduced here because, unlike that removed work,
this schedule is byte-identical by construction, measured past the 2× target on a
real extraction, and the lever the task explicitly invited (scale the task to go
faster). It is **strictly opt-in**: the default remains the serial path.

# MongoDB scoping full-scan diagnosis (nullable-FK belongs_to)

Why a related collection's dump can be "especially slow" — dumping far more
records than the scope implies and scanning the whole collection — when running
an exwiw config against a MongoDB backup. The headline finding: the slowness is a
**symptom of a scoping bug**, not of serialization/decode cost.

## Reproduction setup

- Backup: serve a raw WiredTiger dbpath with a standalone `mongod` (the same
  `mongo:7` image the repo's `compose.yml` uses) on a spare port:

  ```
  docker run -d --name exwiw-restore-mongo --user 0:0 --entrypoint mongod \
    -p 27018:27017 -v "<backup-dbpath>:/data/db" \
    mongo:7 --dbpath /data/db --bind_ip_all
  ```

  Notes: run as root (`--user 0:0`) so mongod can read a backup's `0600` files;
  bypass the image entrypoint (`--entrypoint mongod`) so it does not `gosu`-drop
  back to the `mongodb` user. A backup carrying a `WiredTiger.backup` marker runs
  recovery on the first start and **writes into the backup dir** (expected for a
  restore). Starting a standalone from a replica-set backup yields a harmless
  `system.replset` warning. Local DB connections may be blocked by a dev sandbox —
  run measurement commands with the sandbox disabled.

- Run: `bundle exec exwiw export --config <app>/exwiw/exwiw.yml
  --adapter=mongodb --host=localhost --port=27018 --database=<database>
  --ids=<target-id> --output-dir=… --log-level=debug`.
  (The optional-argument CLI flags — `--ids`, `--output-dir` — must use `=`; the
  space form passes `nil` and crashes in the option callback.)

## Baseline measurement (worked example, warm cache)

Full run ≈ **69s** over a few hundred non-empty collections. Per-collection wall
time (gap between consecutive `Processing table` log markers) was dominated by a
single collection:

| collection | time | records |
|---|---|---|
| **items** | **41.0s (59% of the whole run)** | 18,739 |
| (other collections) | ~5s and below each | — |

A "full run ≈ 10 min" figure is the **cold-cache** version (first read pages the
`items` data off the backup over the bind mount). The *relative* shape (items
dominates) is the same warm or cold.

## Root cause: nullable belongs_to FK used as a hard `$in` AND constraint

The scope is tiny: one parent entity (`<target-id>`) → **1 store** (linked by
`business_entity_id` = the entity's **`uuid`**, correctly configured with
`references: uuid`) → **127 items** (`{store_id: <that store>}`, indexed, ~2ms).

But the run dumped **18,739** items, not 127, and scanned the whole collection.
Why:

1. `MongodbAdapter#related_collection_filter` ANDs **every** belongs_to whose
   parent produced ids. The `stores` filter became:

   ```
   { user_id:             {$in: [580 ids]},
     deleted_user_id:     {$in: [96 ids]},     # nullable FK
     business_entity_id:  {$in: ["<target-id>"]} }
   ```

   The one matching store has **`deleted_user_id` absent (null)**, so it can never
   satisfy `deleted_user_id ∈ {96 ids}`. The AND yields **0 stores** → `stores`
   logs "No records matched. skip this table."

2. With `stores` empty, `@state["stores"]` carries no ids, so when `items` is
   built its `store_id` belongs_to contributes nothing. The remaining belongs_tos
   are to **reference/master data that is dumped in full** —
   `large_categories` and `medium_categories`. So the items filter degenerated to:

   ```
   { large_category_id:   {$in: [98 ids]},
     medium_category_id:  {$in: [846 ids]} }
   ```

3. `items` has **no index on `large_category_id` / `medium_category_id`** (it does
   have `store_id_1`). So this filter forces a **full COLLSCAN of all 2.43M items**
   — and the Runner scans it **twice**: once for `StreamingResult#size`
   (`count_documents`) and again for the fetch.

Isolated phase breakdown of the degenerate items query (warm): `count_documents`
3.58s + fetch/decode 1.47s + serialize 0.26s. Serialization (the native
`Exwiw::ExtJson` C ext) is **not** the bottleneck — the COLLSCAN is, and it is far
worse cold.

The same nullable-FK problem applies one level down: the store's 127 items
themselves have `*_category_id` = null, so even `{store_id, large_category,
medium_category}` ANDed returns **0**. The only filter that yields the correct 127
is `{store_id: {$in: [store]}}` **alone**.

## Implemented fix: genuine-anchor scoping (MongodbAdapter#related_collection_filter)

Scope flows from the dump target along belongs_to edges. The fix classifies each
belongs_to parent of a non-target collection by whether it is **genuinely scoped**
— reachable back to the dump target through belongs_to chains
(`#genuine_scope_set`, a fixpoint over the configs) — and applies the constraint
accordingly:

- **Anchor (strict).** Among the genuine parents, the most selective one (fewest
  captured ids) is applied strictly (`{fk: {$in: [...]}}`). It carries the real
  narrowing and, being strict, bounds the result to a small set — which keeps both
  this query and the `$in` sets it feeds downstream from ballooning.
- **Other genuine parents (null-aware).** `{fk: {$in: [nil, ...]}}` (Mongo's
  `$in: [nil]` matches both explicit nulls and missing fields), so a row whose
  nullable refinement FK is null is not excluded by it.
- **Reference parents (dropped).** A parent NOT reachable to the dump target is
  reference/master data dumped in full; its id set is "all/most of a table" and is
  not a real scope, so when a genuine anchor exists it is dropped entirely.
- **No genuine parent:** fall back to the historical strict-AND of whatever
  constraints exist (preserves prior behaviour for unreachable collections).

For this extraction: `stores` → `{business_entity_id ∈ {<target-id>}}` (anchor;
`user_id`/`deleted_user_id` → reference leaks, dropped) → **1 store**; `items` →
`{store_id ∈ {store}}` strict anchor with the nullable refinement FKs null-aware
and the `*_category` references dropped → **127** via the `store_id_1` index.

### Measured result (warm, same cache)

Full run **58.8s → 11.0s ≈ 5.4×**; `items` 41s double COLLSCAN → ~11ms indexed
(≈3700×). Correctness also fixed: `stores` 0→1, `items` 18,739 (leaked COLLSCAN)
→127. Byte-identical existing snapshots (the seed graph is fully genuine and has no
null FKs, so anchor-strict + null-aware ≡ the prior strict-AND).

### Approaches considered and rejected

- **Unconditional null-aware on every belongs_to** (the original iter-1 direction):
  catastrophic. A collection that belongs_to only reference data dumped in full
  becomes ~the whole table once null-aware; the resulting child `$in` then exceeds
  Mongo's **48 MB max message size** and the run crashes. Null-awareness must NOT
  be applied to a collection's only/anchor scope.
- **Null-aware on all genuine parents (no anchor distinction):** makes the genuine
  *anchor* itself null-aware too — `stores` then matched every store with a null
  `business_entity_id` (a not-fully-backfilled column) → hundreds of thousands of
  stores → a ~39 MB child filter on a downstream collection (**MaxBSONSize**).
  Hence the anchor stays strict.
- **Scope by the single most-selective genuine parent alone (drop other genuine):**
  fast and correct here, but drops legitimate AND-narrowing for multi-parent
  collections (e.g. `order_items` ∈ orders AND products) and moves seed snapshots.
- Pure-performance tweaks that keep the (incorrect) 18,739-row output —
  `--cursor-parallel` (changes row order, treats the symptom) or skipping the
  redundant `count_documents` scan (~½ only) — were rejected as the primary fix.

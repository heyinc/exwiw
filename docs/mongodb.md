# MongoDB support

exwiw can export a MongoDB database with `--adapter=mongodb`. This document collects everything MongoDB-specific: setup, CLI flags, output format, masking, scoping on collections, embedded documents, `explain`, and generating config from Mongoid models. Everything else (masking reference, `reverse_scope` semantics, config file, hooks, ...) is shared with the SQL adapters and documented in the [README](../README.md).

## Setup

- Add `gem "mongo"` to your Gemfile in addition to `exwiw` (it is not declared as a runtime dependency of the gem).
- Set `--adapter=mongodb`. `--user` / `DATABASE_PASSWORD` are optional and only needed when your MongoDB requires authentication.

## Connecting and selecting the target

- `--uri=URI` connects with a full MongoDB connection string (`mongodb://...` or `mongodb+srv://...`) instead of `--host`/`--port`. Use it for managed/replica-set deployments (e.g. Atlas) where TLS, `replicaSet`, `authSource`, and credentials must be expressed — put them in the URI's query string (e.g. `mongodb+srv://user:pass@cluster.example.com/?authSource=admin&tls=true`). The URI takes precedence: when given, `--host`/`--port`/`--user`/`DATABASE_PASSWORD` are ignored, and `--host`/`--port`/`--database` are no longer required on the CLI. `--database`, if still passed, overrides the database in the URI path; otherwise the database from the URI is used. This flag is **mongodb-only** (the SQL adapters shell out to their own client binaries and have no equivalent). The URI may carry credentials, so it is never written to logs.
- The MongoDB adapter consumes a separate config type, `MongodbCollectionConfig`, with MongoDB-native naming. Use `fields` (instead of the SQL adapters' `columns`), and set `"primary_key": "_id"`. Foreign keys (`shop_id`, `user_id`, ...) stay as ordinary fields.
- `--ids` values are coerced to the type actually stored in `_id` before filtering: integer-looking ids become `Integer`, 24-char hex ids become `BSON::ObjectId` (Mongoid's default `_id` type — a plain String would never match an ObjectId), and any other string is left as-is.
- `--target-collection=COLLECTION` is a mongodb-only alias of `--target-table` (use whichever reads better for MongoDB). Specifying both, or using `--target-collection` with a non-mongodb adapter, is an error.
- `--ids-field=FIELD` matches `--ids` against `FIELD` on the target collection instead of its primary key (e.g. `--target-collection=users --ids=a@example.com --ids-field=email`). Downstream foreign-key propagation still keys off the primary key, so only the target collection's filter changes. Unlike the primary-key path, the supplied ids are **not** type-coerced (the stored type of a custom field is unknown), so pass values matching the field's actual type. This flag is **mongodb-only** (the SQL adapters have no equivalent).

## Performance and safety

- Large or embedded-document-heavy dumps are streamed automatically: the adapter reads the collection through a lazy cursor (not `.to_a`) and writes JSONL in chunks, so peak memory is bounded by the chunk size rather than the collection size — no flag to set. Encoding each document to MongoDB Extended JSON is accelerated by an **optional native (C) extension** that compiles automatically on `gem install`; where it cannot compile, exwiw falls back to a byte-identical pure-Ruby encoder. See [`optimization-notes.md`](optimization-notes.md) for the performance investigation and [`optimize-mongodb-export-with-native-ext.md`](optimize-mongodb-export-with-native-ext.md) for the native encoder's design. Benchmark your own data with `script/bench_mongodb_dump.rb`.
- `--mongodb-query-timeout-ms=N` sets a global, **server-enforced** timeout (in milliseconds) on every query exwiw issues — the find cursor's whole lifetime (the initial batch and every `getMore` the streaming dump walks), the count, and an executing `explain`. Past the deadline the server aborts the operation and exwiw fails the run, so an accidentally heavy or unscoped query cannot keep pinning the (often production) source. It is **mongodb-only** (the SQL adapters shell out to their own clients) and may also be set as `mongodb_query_timeout_ms:` in the config file. The default is no timeout. A single collection can opt to a different limit with a `query_timeout_ms` key in its schema config (a sibling of `bulk_insert_chunk_size`), which overrides the global for that collection's find/count — use it to give a known-large collection more headroom, or to cap one that tends to run away. Hand-edited `query_timeout_ms` values are preserved across schema regeneration.
- `--parallel-workers=N` (opt-in, `export` only) forks `N` worker processes that decode whole collections in parallel — the dominant cost on a large dump is the driver's BSON→Ruby decode, and each worker decodes its own collections in their natural order, so the output stays **byte-identical** to a serial run (same filenames and content). It needs a dump target (the schedule is built around the scoped DAG) and a `fork`-capable runtime (CRuby on POSIX), falling back to the serial path otherwise; it also accepts `parallel_workers:` in the config file. The speedup needs real cores to spend — it reaches ~2× from 4 workers and saturates there. The default is serial. See [`mongodb-dump-parallelism-2x-notes.md`](mongodb-dump-parallelism-2x-notes.md) for the schedule and measurements.

## Output

- Output is JSON Lines (`insert-{idx}-{collection}.jsonl`) using MongoDB Extended JSON (relaxed mode). Import with `mongoimport`:
  ```bash
  mongoimport --db app_dev --collection users --file dump/insert-002-users.jsonl
  ```
- A Ruby [after-insert hook](../README.md#after-insert-hook) can seed extra documents into named collections with `insert_jsonl(collection, template)`; each targeted collection gets its own `insert-NNN-<collection>.jsonl` file numbered after the dump's own files, so the filename-based `mongoimport` convention above applies to hook output unchanged.
- The leading `dump/insert-000-schema.js` contains `db.createCollection(...)` and `db.<col>.createIndex(...)` calls for every top-level collection (indexes are introspected from the source via `listIndexes`; the auto-created `_id_` index is skipped). Apply it with mongosh **before** running `mongoimport`:
  ```bash
  mongosh "mongodb://localhost/app_dev" dump/insert-000-schema.js
  ```
- Unlike SQL adapters, the MongoDB adapter does not emit `delete-*.jsonl` files (drop the database / collection yourself before importing if needed).

## Masking

- `replace_with_fake_data` is supported on a field ([full reference](../README.md#replace_with_fake_data)) — its `seed` names a field of the same collection (bare or `collection.`-qualified) or the primary key (`_id`), and it derives the same fake value as the SQL adapters for the same seed. It is applied document-side after `replace_with` (so a fake seed reads the already-masked value, matching the SQL adapters where `replace_with` runs in the database first), works inside embedded subdocuments, and is exclusive with `replace_with` on the same field. Add `gem "faker"` to use it (except a config using only `ja` person types). `raw_sql` and `map` are **not** supported (the `MongodbField` schema does not declare them; such keys are rejected on load — see [Unknown keys are rejected](../README.md#unknown-keys-are-rejected)); use `replace_with` for template masking.
- The MongoDB adapter does not support the collection-level `filter` field (it raises `NotImplementedError` if set, since the SQL-string filter cannot be applied to MongoDB).
- A field marked [`ignore: true`](../README.md#ignore--annotate-a-column-or-belongs_to) is absent from the dump on an embedded config too, though it gets there differently: a top-level collection's ignored field is left out of the projection and never fetched, while an embedded one arrives inside the parent's document and is deleted from the subdocument during masking. It is deleted before the collection's own `replace_with` / `replace_with_fake_data` run, so — as on a top-level collection — nothing masking the same subdocument can read it. The primary key cannot be marked `ignore: true` (that raises `ArgumentError` on load): dropping it would leave the dumped documents with no identifier, so a restore would assign fresh ids and break every reference pointing at them.

## `reverse_scope` on collections

[Multi-referencer reverse scoping](../README.md#reverse-scope-for-multi-referencer-tables-reverse_scope) works on `MongodbCollectionConfig` with the same config shape and the same semantics as the SQL adapters — a global-identity collection (say `accounts`) with no `belongs_to` path to the dump target, but referenced by several scoped collections, is constrained to the union of the ids those referencers actually point at instead of being dumped in full:

```json
{
  "name": "accounts",
  "primary_key": "_id",
  "reverse_scope": {
    "via": [
      { "table": "articles", "column": "author_account_id" },
      { "table": "invitations", "column": "invitee_account_id" }
    ]
  },
  "belongs_tos": [],
  "fields": [{ "name": "_id" }, { "name": "name" }]
}
```

Where the SQL adapters emit a `UNION` subquery, MongoDB has no cross-collection joins, so the adapter captures each arm's column values **at runtime** while the referencer collection streams (the same mechanism that already propagates parent ids to children), then filters the reverse-scoped collection with `{"_id": {"$in": [<union of captured ids>]}}`. Consequences of that runtime capture:

- **Processing order**: a reverse-scoped collection is dumped **after** all of its `via` referencers (an arm's own `belongs_to` back to the reverse-scoped collection is inverted rather than kept — the declaration states ids flow referencer → collection). If the arms form a genuine ordering cycle with the `belongs_to` graph, the export aborts with an error naming the cycle members. SQL processing order is unchanged (its INSERT output must stay loadable in foreign-key order).
- **Arm hygiene mirrors SQL**: an arm whose referencer is unknown, embedded, not dumped, or itself unscoped (no path to the dump target and no `reverse_scope` of its own) is **skipped with a warning** — an unscoped referencer's ids span every scope and would silently widen the dump. Per-arm `null`/absent foreign keys are dropped (the SQL `IS NOT NULL`), an array-valued foreign-key column contributes one id per element, and captured values keep their native BSON types (an `ObjectId` foreign key matches an `ObjectId` `_id` with no coercion).
- **Precedence mirrors SQL**: a collection with its own `belongs_to` path to the dump target is scoped by that path; a `reverse_scope` declared on it is ignored.
- **Satellites need no config**, as in SQL: a collection that `belongs_to` the reverse-scoped collection tightens to the kept ids automatically through the ordinary captured-parent-id mechanism.
- **`--parallel-workers` falls back to serial** (with a warning) when any collection declares `reverse_scope` — the parallel schedule does not express the referencers-first ordering constraint yet.
- **`exwiw explain`** shows the real `{"_id": {"$in": [...]}}` filter shape with a placeholder id, like the other runtime-captured scopes.

Masking (`replace_with`) and `fields` behavior on a reverse-scoped collection are unchanged. Like the SQL key, `reverse_scope` is user-owned: `exwiw:mongoid:schema:generate` never emits it and regeneration preserves a hand-added value.

## Embedded documents

MongoDB models often store one-to-many relationships as embedded subdocument arrays (e.g. `users` documents with a `posts: [...]` field). To mask fields inside embedded subdocuments, declare a separate config with `embedded_in`:

```jsonc
// e2e/users.json — top-level collection
{
  "name": "users",
  "primary_key": "_id",
  "belongs_tos": [{ "table_name": "shops", "foreign_key": "shop_id" }],
  "fields": [
    { "name": "_id" },
    { "name": "name", "replace_with": "masked{_id}" },
    { "name": "shop_id" }
  ]
}

// e2e/posts.json — embedded under users.posts
{
  "name": "posts",
  "primary_key": "_id",
  "embedded_in": { "collection_name": "users", "path": "posts" },
  "belongs_tos": [],
  "fields": [
    { "name": "_id" },
    { "name": "title", "replace_with": "masked-{_id}" }
  ]
}
```

At runtime:

- `posts` is **not** dumped as its own jsonl file. Its `replace_with` rules are applied to the subdocuments inside the parent `users` document at the path `posts`.
- `path` accepts dot-separated paths for nested fields (e.g. `"profile.contacts"`).
- Both arrays of subdocuments and a single Hash subdocument at `path` are supported. Multiple levels of nesting work via embedded chains.
- Cross-collection references from inside an embedded subdocument (`belongs_tos` on an embedded config) are not supported and raise `ArgumentError` on load.
- Specifying an embedded config as `--target-table` raises `NotImplementedError`; pass the top-level collection name instead.

### Excluding an embedded path (`ignore: true`)

A parent collection fetches an embedded path only because some config claims it, so marking the embedded config [`ignore: true`](../README.md#ignore-a-table) leaves the path out of the parent's projection: the **whole subdocument is absent from the dump**, and any embedded chain hanging off it goes with it.

```jsonc
// posts is embedded in users.posts, but its content is not wanted in the dump
{
  "name": "posts",
  "primary_key": "_id",
  "ignore": true,
  "comment": "subdocument is environment-specific; drop it rather than mask it",
  "embedded_in": { "collection_name": "users", "path": "posts" },
  "belongs_tos": [],
  "fields": [{ "name": "_id" }, { "name": "title" }]
}
```

This is the only way to keep an embedded path out of the dump — MongoDB does not allow mixing exclusions into the inclusion projection exwiw builds — and it is how to drop a subdocument that must not survive into the restored database at all, rather than be masked into a fake value. Two consequences worth knowing:

- Dropping is not masking: a field that must keep a plausible value belongs in `replace_with` / `replace_with_fake_data`, not here. An absent path also means an application reading it sees "not set", which is a different state from "set to a masked value".
- The path is only excluded when *no* config asks for it. If the parent collection also declares the path in its own `fields`, that declaration still pulls the raw subdocument into the dump — now with no masking applied to it, since the ignored config's rules no longer run. Remove the parent's field entry (or mark it `ignore: true`) as well.

Like every other `ignore`, it is preserved across `exwiw:mongoid:schema:generate` regenerations, so the exclusion survives a config refresh.

## `exwiw explain` verbosity

The mongodb explain runs the server's [explain command](https://www.mongodb.com/docs/manual/reference/command/explain/) at a configurable verbosity. The default, **`queryPlanner`, only plans the query and does not execute it**, so it is safe to point at a production source. Set it with the `EXWIW_MONGODB_EXPLAIN_VERBOSITY` environment variable or the `explain_verbosity:` config key (the env var wins):

| verbosity | behaviour |
|---|---|
| `queryPlanner` (default) | Plans the query only. **The query is not executed** — no documents are scanned. |
| `executionStats` | **Runs the query** and reports runtime statistics (docs examined, time, etc.). |
| `allPlansExecution` | Runs the winning plan **and the rejected candidate plans** to gather their stats. |

```bash
# inspect index usage of the real extraction query (executes it)
EXWIW_MONGODB_EXPLAIN_VERBOSITY=executionStats exwiw explain \
  --adapter=mongodb \
  --uri="mongodb+srv://reader@cluster/app_production" \
  --schema-dir=exwiw/schema \
  --target-collection=shops --ids=...
```

`executionStats` and `allPlansExecution` execute the extraction query against the source, so use them deliberately on large/production collections.

> **Scoped collections use a placeholder id.** A non-target collection is scoped by its parents' ids, which a real dump captures while running each parent query — but `explain` runs nothing. So for scoped collections, `explain` fills the real foreign-key filter (e.g. `users` → `{ shop_id: { $in: [...] } }`) with a placeholder id rather than real values. The plan still reflects the real dump: `queryPlanner` chooses an index by the queried *field*, not its value, so whether a scoped extraction does an `IXSCAN` or a `COLLSCAN` is reported correctly. Only the bound *values* are fake. (The target collection uses the real `--ids`; reference collections with no `belongs_to` use the real `{}` full scan.)

## Generating config from Mongoid models

For MongoDB applications backed by [Mongoid](https://www.mongodb.com/docs/mongoid/), a separate rake task introspects Mongoid document models and emits `MongodbCollectionConfig` files (the `fields` / `_id` / `embedded_in` shape described in this document):

```bash
bundle exec rake exwiw:schema:generate_mongoid
```

It is a distinct task and class (`Exwiw::MongoidSchemaGenerator`) from the ActiveRecord generator because the two ORMs expose entirely different metadata. Every application document model is described, except one declared `store_in collection: nil` — the way an application says a document class is never persisted and only wants Mongoid's casting: it has no collection name to describe, so it is skipped (and does not count as a live collection when tidying). From each remaining model it derives:

- the collection name and the `_id` primary key,
- `fields` from the declared Mongoid fields (referenced `belongs_to` foreign keys such as `shop_id`, and the `created_at` / `updated_at` columns added by `Mongoid::Timestamps`, are ordinary fields — their BSON `ObjectId` / `Date` values serialize as MongoDB Extended JSON at dump time). For an aliased field (`field :ctry, as: :country`), the generator emits the **stored** document key (`ctry`), never the Ruby accessor (`country`), so masking and projection target the key that actually appears in the document, and additionally records the accessor as `mongoid_field_name` on that field so the short key stays understandable (association aliases such as `shop => shop_id` and the built-in `id => _id` are not field renames and are not annotated),
- `belongs_tos` from referenced `belongs_to` associations (`{ table_name, foreign_key }`). A referenced `belongs_to` declared on an *embedded* document is dropped (cross-collection refs from inside embedded subdocuments are unsupported — see [Embedded documents](#embedded-documents)), but its foreign-key column is still kept as an ordinary field. A `has_and_belongs_to_many` association is also dropped (its foreign keys are stored as an array field, e.g. `tag_ids`, which exwiw cannot follow as a single-valued foreign key), while that `*_ids` array column is kept as an ordinary field,
- `embedded_in` from `embedded_in` / `embeds_many` / `embeds_one` associations. Each embedded config names its *immediate* parent collection and the document key it lives under (`store_as`, defaulting to the relation name); nested embedding is represented as a chain (`comments` → `embedded_in` `posts`, `posts` → `embedded_in` `users`) rather than a flattened dot-path, matching how the adapter recurses through array and Hash subdocuments. The document key is resolved by locating the parent's `embeds_one` / `embeds_many` that stores this collection. (Mongoid's computed inverse is frequently `nil` when no explicit `inverse_of:` is set, so exwiw matches by the collection the parent's embedding relations store rather than trusting that inverse — this also resolves an STI subclass embedded through a relation declared against its base class.) When the same collection is embedded under several keys in the parent, the path is ambiguous and treated as unrepresentable (see below). A *polymorphic* `embedded_in` (`embedded_in :addressable, polymorphic: true`) has no single embedding parent collection and so cannot be expressed as an `embedded_in` config. A *self-referential / cyclic* embedding (Mongoid's `recursively_embeds_many` / `recursively_embeds_one`) makes a collection both a top-level document and embedded inside documents of its own type; exwiw represents a collection as either top-level or embedded, not both, so it cannot emit an `embedded_in` config that would silently make the collection undumpable. These unrepresentable shapes are handled best-effort by default and abort only in strict mode (see below).

Models in an inheritance hierarchy whose subclasses share the base's collection (Mongoid STI, distinguished by the auto-added `_type` discriminator) collapse into a single config: the generator discovers the subclasses via `descendants` (Mongoid registers only the base class in `Mongoid.models`) and unions every class's `fields` and `belongs_tos` into the collection config, so subclass-only fields and associations are not lost.

A collection name can also be shared by embedded and non-embedded models, in two shapes the generator tells apart. `embedded?` only answers "does this class declare an `embedded_in`", which is not the same question as "does this collection have root documents":

- **An embedded family under a plain base class** — `Address` holding the shared fields and declaring no `embedded_in`, with `BillingAddress < Address` declaring one and inheriting the collection name. Nothing is stored at the root under the base; it is part of the embedded family, and its fields describe subdocuments. The collection stays **embedded**, exactly as before: one `embedded_in` config unioning the base's fields with its subclasses', derived from a class that actually declares the embedding. (A non-embedded model whose embedded descendants are in the same group is always read as their base — conservatively so, even if the application also stored root documents under it, since the alternative would silently delete the config masking those subdocuments.)
- **A genuine collision** — an unrelated top-level model stores into a collection whose name an embedded class derives from its own class name. Such a collection is genuinely **top-level**: it has root documents that must be dumped, so its config is built from the root models only (their fields and `belongs_tos`) with no `embedded_in`. An embedded base in the same group does not contribute its fields. Representing the group as embedded would make `dumpable?` skip the collection and silently drop those documents from the export.

The collision is reported on stderr, because the embedded documents of the same name are **not** covered by that config: to mask them, add a config by hand with an `embedded_in` and a `name` / file name of your own choosing (generation and `tidy_mongoid` both leave `embedded_in` configs alone, so a hand-written one is stable). This is deliberately not recorded as a `comment` on the generated config — a generated comment takes precedence when merging, so it would overwrite a note you wrote about this very situation on every run.

Regeneration preserves hand-edited `replace_with`, `filter`, `ignore`, `bulk_insert_chunk_size`, and `query_timeout_ms` values, like the ActiveRecord generator. Indexes are not written to the config — they are introspected from the live database at dump time (see [Output](#output)). Polymorphic `belongs_to` is not yet expanded by this task.

### Safe mode, `tidy_mongoid` and `check_mongoid`

Like the ActiveRecord task, `generate_mongoid` runs in [safe mode](../README.md#safe-mode-masking-new-columns-by-default) by default (`EXWIW_NEW_COLUMNS=plain` opts out for a first bootstrap): a field the config does not have yet is emitted masked — as far as its Mongoid type allows — and flagged `needs_mask_decision: true`, so a field added to a model does not start being exported before somebody has judged whether it holds personal data. The `_id` primary key, the `_type` STI discriminator and every `belongs_to` foreign key are flagged but never masked (masking them would rewrite the very references the dump is assembled from), and neither is a field whose type no constant fits (`Hash`, `Array`, a typeless field, a BSON type) or one covered by a unique index unless its mask varies per document. A field's own `default:` is preferred over the per-type constant. A decision recorded on disk — a mask kept, replaced, dropped, or the flag removed — wins over every later regeneration.

```bash
bundle exec rake exwiw:schema:tidy_mongoid   # delete the config of a collection no model stores into
bundle exec rake exwiw:schema:check_mongoid  # report the difference, writing nothing
```

`tidy_mongoid` is the counterpart `generate_mongoid` cannot be: it deletes the config file of a collection no model stores into any more. It reconciles against the **models**, not a live connection — MongoDB has no schema to read, and a collection exists only once a document is written to it — using exactly the grouping `generate_mongoid` writes files from, embedded collections included. Fields are left alone, since `generate_mongoid` already tracks them through the model.

`check_mongoid` mirrors [`schema:check`](../README.md#checking-the-config-against-the-schema): it regenerates (safe mode + tidy) into a throwaway copy of the config directory, prints the same sorted JSON report — collections and fields under the same keys as tables and columns — honors `EXWIW_SCHEMA_CHECK_OUTPUT`, and exits non-zero while anything is out of date or undecided, so it can gate a pull request. It regenerates in strict mode: a newly introduced construct exwiw cannot represent fails the task rather than reporting clean.

By default the task **aborts** when a model uses a construct exwiw cannot represent: a `belongs_to` whose target class can no longer be resolved (a stale relation left behind after its model was removed), or a polymorphic / self-referential-cyclic / ambiguous / unresolvable-parent `embedded_in` (see the cases above).

### Honoring an explicit `ignore` (the recommended way to keep these out)

When you have reviewed such a construct and decided exwiw should leave it alone, mark it `ignore: true` in its config on disk. The generator **honors an explicit `ignore` and skips re-introspecting it**, so it never aborts the run on something you have already triaged — and your annotation survives regeneration. Two granularities:

- A whole **collection** exwiw cannot represent (e.g. a polymorphic / ambiguous `embedded_in`) — mark the collection config `"ignore": true`. To actually dump/mask it later, define its `embedded_in` config by hand (see [Embedded documents](#embedded-documents)).
- A single **`belongs_to`** that no longer resolves while the rest of its collection is fine (e.g. a stale relation pointing at a removed model) — mark that entry `"ignore": true`, with no `table_name`. The relation is dropped from extraction (`#reject_ignored_members!`) while its foreign-key column stays an ordinary field, and the collection keeps dumping.

Record *why* with the optional **`ignore_type`** (a free-form tag exwiw never interprets — e.g. `"need_code_fix"` for an application-side bug, `"unsupported"` for a shape exwiw cannot express) and a **`comment`**. Both are user-owned and preserved across regeneration; the generator never emits `ignore_type` itself.

```json
// orders.json — a stale belongs_to flagged for a code fix; the collection still dumps
{
  "name": "orders",
  "primary_key": "_id",
  "belongs_to": [
    { "table_name": "shops", "foreign_key": "shop_id" },
    {
      "foreign_key": "coupon_id",
      "ignore": true,
      "ignore_type": "need_code_fix",
      "comment": "FIXME: belongs_to :coupon -> Coupon does not exist (dead relation)."
    }
  ],
  "fields": [ /* ... coupon_id is kept as an ordinary field ... */ ]
}
```

### First bootstrap pass: `EXWIW_SKIP_UNSUPPORTED=1`

For the very first pass against a large app — before any `ignore` annotations exist — set `EXWIW_SKIP_UNSUPPORTED=1` to keep going past *un-annotated* unrepresentable constructs instead of aborting one at a time:

```bash
EXWIW_SKIP_UNSUPPORTED=1 bundle exec rake exwiw:schema:generate_mongoid
```

- An unresolvable `belongs_to` is dropped from the collection's `belongs_tos` (its foreign-key column is still kept as an ordinary field, like the polymorphic / HABTM cases) and a warning naming the relation is printed to stderr.
- An unrepresentable `embedded_in` collection is emitted as a **top-level** config marked `"ignore": true` with a `comment` recording why, and a warning is printed.

Review the stderr warnings, annotate the affected configs (`ignore` / `ignore_type` / `comment`), and subsequent runs complete without the flag because the generator honors those explicit ignores.

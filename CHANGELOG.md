# Changelog

## [Unreleased]

### Added

- **Hybrid extraction: `--target-table` may now be combined with `--scope-column`.** Each table is resolved as the union (`OR`) of however it is reachable from the single target anchor and however it is reachable by the shared scope column, and the scope values are *derived from the target* (`scope_column IN (SELECT target.scope_column FROM target WHERE <target ids>)`) so one `--ids` in the target's id-space drives both. This handles a foreign key that cannot be joined — most importantly a cross-database `belongs_to` (its join is impossible, but the FK column is still filterable): the table is reached via the scope column instead of being dropped or dumped in full. A table reachable by only one anchor is filtered by just that one, so single-anchor extraction is byte-identical to before. The target table must carry the scope column; every table must still be reachable by some anchor (a table reachable by neither aborts the run, as in pure scope-column mode); and hybrid runs are insert-only (`--insert-only` is required, since the `OR`-composed queries have no `delete-*.sql` form). Because each row is matched via `pk IN (<branch>)` subqueries there is no join fan-out, so no row is emitted twice. SQL adapters only.
- **`schema:generate` detects a cross-database `belongs_to` and ignores just the relation — not the table, not the foreign-key column.** A `belongs_to` whose target model lives in a different database (Rails multi-database `connects_to`) cannot be joined — each database is exported separately — so the *belongs_to entry* is emitted with `ignore: true` and `ignore_type: "cross_database"` and a `comment` recording why and pointing at `--scope-column` for cross-boundary extraction. The owning table is still exported normally and its foreign-key column is still exported as a plain column; only the join/dependency edge is dropped at load (otherwise the dangling cross-database target would crash dependency resolution). Polymorphic associations are handled per target. The task prints a summary of every cross-database relation it ignored. (`ignore_type` is now also preserved across regeneration by `TableConfig#merge`.) Single-database applications are unaffected.

### Changed

- **A per-table `scope_column` now requires `--scope-column`.** A per-table `scope_column` override is only consulted in scope-column mode; running without `--scope-column` while any loaded config sets one is now an error (previously it was silently ignored), so the misconfiguration surfaces instead of producing an unintendedly unscoped dump.

## [0.6.2] - 2026-06-21

## [0.6.1] - 2026-06-20

## [0.6.0] - 2026-06-20

### Added

- Optimize memory usage https://github.com/heyinc/exwiw/pull/118 
- **MongoDB: optional native (C) encoder for the Extended-JSON dump path** (no flag, byte-identical output, pure-Ruby fallback). Encoding each document to MongoDB Relaxed Extended JSON — previously `JSON.generate(doc.as_extended_json(mode: :relaxed))`, which rebuilds the whole document into an intermediate transformed Hash tree and then walks it again — was the dominant per-document CPU cost (~82% of serialization on embed-heavy data). A new C extension (`ext/exwiw/ext_json/`) emits the JSONL line in a single native tree-walk. It formats the structural bulk plus the leaves that dominate a dumped document — `Hash`, `Array`, `String`, fixnum `Integer`, `true`/`false`/`nil`, `BSON::ObjectId` (`_id`), and in-range `Time` (the Mongoid `created_at`/`updated_at` timestamps) — and delegates everything else (`Float`, out-of-int64 `Integer`, out-of-range `Time`, `Symbol`, `Decimal128`, …) back to the exact pure-Ruby path, so the output is provably byte-for-byte identical. On a 30-embedded-post timestamp-heavy document this serializes ~2.8× faster. With `gem install exwiw` the extension compiles automatically; hosts that cannot compile (JRuby/TruffleRuby, no toolchain) fall back to the pure-Ruby encoder, so exwiw stays installable as a pure-Ruby gem. See [`docs/optimize-mongodb-export-with-native-ext.md`](docs/optimize-mongodb-export-with-native-ext.md).

## [0.5.3] - 2026-06-19

### Changed

- **MongoDB: dumps now stream, bounding peak memory regardless of collection size** (default; no flag, byte-identical output). The adapter previously loaded each collection's entire result set into memory (`.to_a`) and built the whole collection's JSONL output as one string, so peak memory scaled with collection size. It now wraps the Mongo cursor in a lazy streaming result and writes output in chunks, so at most one chunk of documents (plus the small FK-propagation key arrays) is resident at a time. On a 20k-document × 30-embed collection this cut peak RSS by hundreds of MB and was also faster (less GC pressure). The per-document Extended-JSON masking was also precompiled per collection config, trimming per-document encoding cost. See [`docs/optimization-notes.md`](docs/optimization-notes.md) for the full investigation, and [`docs/optimize-mongodb-export-with-native-ext.md`](docs/optimize-mongodb-export-with-native-ext.md) for the proposed native-encoder follow-up.

## [0.5.2] - 2026-06-18

### Fixed

- **PostgreSQL: an extension the restore target cannot create no longer aborts the restore, and `pglogical` is never emitted.** `dump_schema` prepends `CREATE EXTENSION IF NOT EXISTS` for every extension installed on the source, wrapped in a `DO` block that previously swallowed only `feature_not_supported` (the extension's binaries are unavailable on the target). A source on managed Postgres/AlloyDB carrying `pglogical` (logical replication) emitted `CREATE EXTENSION ... SCHEMA "pglogical"`, which on a target lacking that schema fails with `invalid_schema_name` — an error the handler did not catch, so the whole restore aborted. The handler now also catches `invalid_schema_name`, and instead of silently discarding the skip it re-raises it as a `WARNING` (carrying SQLSTATE and the original message) so the skip is visible in the restore logs rather than vanishing. `insufficient_privilege` is intentionally **not** caught: a restore role lacking `CREATE` privilege is a misconfiguration that must fail loudly. Separately, `pglogical` is now excluded from the prepended extensions entirely (alongside `plpgsql` and the `google_*`/`rds_*`/`aiven_*` managed-platform extensions) — it is a replication mechanism of the source, not part of the copied data.
- **Table processing order no longer aborts on `belongs_to` cycles.** Two distinct problems made `export`/`explain` fail with "Circular belongs_to dependency detected" on schemas that have no resolvable order: (1) a `belongs_to` whose target table is **not part of the run** — most commonly an embedded MongoDB collection, which is masked through its parent and never dumped on its own — was treated as a dependency that could never be satisfied, so every table that (transitively) referenced one froze and was misreported as a cycle; such out-of-run targets are now ignored when ordering. (2) A **genuine** cycle (e.g. `a belongs_to b` and `b belongs_to a`) now **breaks deterministically with a warning** instead of raising: exwiw emits the cycle member (a table in a strongly-connected component of the unresolved-dependency graph) with the fewest unresolved dependencies, preferring one that still has an already-ordered parent so its extraction stays constrained, and logs which `belongs_to` edge was dropped. The dropped edge is not enforced while ordering, so for the mongodb adapter that table may match a superset of rows (the not-yet-processed parent contributes no `$in` filter); mark one of the `belongs_to` entries forming the cycle with `ignore: true` to break it explicitly instead. Acyclic tables that merely wait on a cycle are never reordered ahead of their parents.
- **MongoDB: `dump_schema` tolerates collections declared in the schema but absent from the source database.** Listing indexes for a non-existent collection makes the driver raise `NamespaceNotFound` (code 26), which aborted the whole export when the schema covered more collections than the connected database actually had (schema/DB drift, or a sparse development database). The existing collections are now resolved once up front and indexes are emitted only for those; `createCollection` is still emitted for every configured collection, so the target schema is created in full.
- **MongoDB: a related collection that cannot be scoped no longer falls back to dumping the whole collection.** When a non-target collection's `belongs_to` parents all yield no ids to filter by — because every parent matched nothing or is not dumped on its own (e.g. an embedded collection) — the assembled filter is empty. Previously that empty filter was sent as `find({})`, scanning and dumping the **entire collection across every scope** (a cross-scope data-exposure risk). Such a collection is now constrained to match no rows and a warning is logged instead. A collection with no `belongs_to` at all is still treated as reference/master data and dumped in full.

## [0.5.1] - 2026-06-18

### Added

- **Scope-column extraction mode** (`--scope-column`, SQL adapters only). For schemas where many independent top-level tables share the same scope/tenant column instead of converging on a single `belongs_to` root, exwiw can now filter **every** table by that shared column (`--scope-column=COLUMN` with `--ids` as its values) rather than anchoring on one `--target-table`. A table that carries the column is filtered directly; a table that lacks it but `belongs_to` a table that has it is joined up to the nearest such table and filtered there. A table that `belongs_to` a parent which is itself scoped but carries no scope column of its own (e.g. a *hub* table scoped only because an extractable child references it) is constrained to the parent's in-scope ids via a subquery (`fk IN (SELECT parent.pk FROM <parent's scoped query>)`), so the hub's other children ride along to just the in-scope rows — limited to a single forward hop and a single unambiguous scopable parent. A table that cannot be scoped at all (no column and no path to one) makes the run **abort with a list of the offending tables**, so an unscoped table is never silently dumped in full. Two user-owned table-config keys support this and are preserved across `schema:generate` regeneration: **`scope_exempt: true`** exports a genuine reference/master table in full (rails-managed tables are treated as exempt automatically), and **`scope_column`** overrides the filtered column name for a table that stores the same scope value under a different name. `--scope-column` is mutually exclusive with `--target-table`, `--target-collection`, `--ids-column`, and `--ids-field`, can be set in `exwiw.yml`, and works with `exwiw explain`.

## [0.5.0] - 2026-06-16

### Added

- A YAML **config file** (`exwiw.yml`) can now hold any option except the database connection settings, so they no longer have to be repeated on every invocation. Pass it with `--config=PATH`; when `--config` is omitted, `exwiw.yml` (or `exwiw.yaml`) is loaded automatically from the current directory if present. **Options passed on the CLI take precedence** over the file (the file only fills in options not given on the CLI). Connection settings — `host`, `port`, `user`, `database`, `uri`, `password` — are **rejected** in the file (they must come from the CLI/environment); `adapter` is the one connection-related key allowed. Relative paths in the file (`schema_dir`, `output_dir`, `after_insert_hook`) are resolved relative to the config file's own directory (so a root-level `exwiw.yml` with `schema_dir: exwiw/schema` reads naturally and an absolute `--config` works from any directory). Unknown keys are rejected to catch typos, and export-only keys (`output_dir`, `output_format`, `insert_only`, `after_insert_hook`) are ignored under `explain` so one file can be shared by both subcommands.

### Changed

- **BREAKING**: the `export`/`explain` CLI option `--config-dir` has been renamed to `--schema-dir` to distinguish the directory of schema JSON files from the new `--config` config file. Its short form `-c` is now `--config` (the config file); `--schema-dir` has no short form. The hook contract is renamed to match: the shell-hook environment variable `EXWIW_CONFIG_DIR` is now `EXWIW_SCHEMA_DIR`, and the Ruby-hook `cli_options[:config_dir]` is now `cli_options[:schema_dir]`. Update invocations, scripts, and hooks accordingly (`--config-dir` no longer exists). `--schema-dir` is still required and has no default unless `schema_dir` is set in the config file.
- **BREAKING**: the env var that overrides where `schema:generate`, `schema:tidy`, and `schema:generate_mongoid` write their config has been renamed from `OUTPUT_DIR_PATH` to `EXWIW_SCHEMA_DIR_PATH`, and the default output directory is now `exwiw/schema` (previously `exwiw`). The new name disambiguates it from the dump-side `--output-dir`, and the dedicated `schema/` subdirectory leaves `exwiw/` free for other artifacts (hooks, dumps). `OUTPUT_DIR_PATH` is no longer read. Existing repositories should set `EXWIW_SCHEMA_DIR_PATH` (e.g. `EXWIW_SCHEMA_DIR_PATH=exwiw` to preserve the old flat layout) and/or move their config under `exwiw/schema/`; otherwise a `generate` run will write a fresh copy into `exwiw/schema/` and leave the old files stale. The `export`/`explain` CLI is unaffected, but examples now point at `exwiw/schema`.

## [0.4.11] - 2026-06-15

### Fixed

- MongoDB: `schema:generate_mongoid` now resolves an embedded collection's `embedded_in` document key by locating the parent's `embeds_one` / `embeds_many` that stores the collection, instead of trusting Mongoid's computed `assoc.inverse`. Mongoid returns a `nil` inverse for many valid embeddings (when no explicit `inverse_of:` is declared and it declines to infer one), and previously such a model was wrongly reported as having an "unresolvable inverse" and skipped (or aborted the run). Matching by the embedded collection also resolves an STI subclass embedded through a relation declared against its base class. Genuinely ambiguous embeddings (the same collection stored under several keys in the parent) are still reported as unrepresentable.

### Added

- MongoDB: `schema:generate_mongoid` now **honors an explicit `ignore: true` on disk** and skips re-introspecting it, so a construct exwiw cannot represent that you have already triaged no longer aborts the (fail-loud, default) run — and the annotation survives regeneration. Works at two granularities: a whole **collection** marked `ignore: true` is preserved as-is without introspection, and a single **`belongs_to`** marked `ignore: true` (no `table_name` required) is preserved while the rest of its collection still generates and dumps (its foreign-key column stays an ordinary field). This lets you keep the generator strict by default while opting individual stale/unrepresentable constructs out by hand, rather than relying on `EXWIW_SKIP_UNSUPPORTED`.
- `MongodbCollectionConfig` and `BelongsTo` gain an optional, user-owned **`ignore_type`** tag (free-form; exwiw never interprets or emits it) to record *why* something is ignored — e.g. `"need_code_fix"` for an application-side bug, `"unsupported"` for a shape exwiw cannot express. Preserved across regeneration like `comment`. `BelongsTo#table_name` is now optional so an ignored, no-longer-resolvable relation can be recorded without a target collection (a non-ignored `belongs_to` still requires one).

## [0.4.10] - 2026-06-12

### Fixed

- PostgreSQL: schema dump now strips `CREATE TRIGGER` statements from `insert-000-schema.sql`. `pg_dump --table` includes triggers but not the standalone function definitions they reference, causing `PG::UndefinedFunction` errors on restore. Handles `CREATE CONSTRAINT TRIGGER` and `CREATE OR REPLACE TRIGGER` variants. ([#96](https://github.com/heyinc/exwiw/pull/96))

## [0.4.9] - 2026-06-11

### Fixed

- PostgreSQL: schema dump now filters cloud-provider-managed extensions (`google_%`, `rds_%`, `aiven_%`) and wraps remaining `CREATE EXTENSION` statements in exception handling (`EXCEPTION WHEN feature_not_supported THEN NULL`), so dumps extracted from GCP Cloud SQL can be restored on AWS RDS without manual intervention.

## [0.4.8] - 2026-06-11

### Added

- PostgreSQL: schema dump now includes `CREATE EXTENSION IF NOT EXISTS` statements for user-installed extensions (e.g. `btree_gist`, `pgcrypto`, `uuid-ossp`). Extensions are emitted before any `CREATE TYPE` or `CREATE TABLE` definitions so the dump can be restored on a clean database without manually pre-installing extensions. Non-public schema extensions include a `SCHEMA` clause. ([#92](https://github.com/heyinc/exwiw/pull/92))

## [0.4.7] - 2026-06-10

### Fixed

- PostgreSQL: `CREATE TYPE ... AS ENUM` statements in schema dumps no longer duplicate labels when the same enum type is used by multiple columns across the target tables. The `query_enum_types` query now filters by column in a subquery so the `pg_type` / `pg_enum` join produces each label exactly once.

### Added

- MongoDB: a `belongs_to` may now declare `references`, the parent field its foreign key actually points at, so foreign-key propagation can follow a relation that references a non-`_id` parent field (e.g. a `uuid`). Previously the adapter always stashed the parent's `primary_key` (`_id`, an ObjectId) and constrained children with `foreign_key $in [ObjectId(...)]`; a child whose FK stores the parent's `uuid` String never matched, so its slice (and everything below it) came back empty — making business-entity-scoped dumps unusable for models referenced by `primary_key: :uuid`. With `"references": "uuid"` on the child's `belongs_to`, the adapter captures the parent's `uuid` values during extraction and matches the child against those instead. `references` defaults to the parent's `primary_key` (so existing configs are unchanged). `schema:generate_mongoid` now auto-emits it by reading Mongoid's `belongs_to ..., primary_key:` (a non-`_id` primary key becomes `"references": "<field>"`; a default `_id` emits nothing), so no hand-editing is needed for `primary_key:`-declared associations — and a hand-added value still survives regeneration. The SQL adapters ignore it (they join on the parent primary key).
- MongoDB: `--uri=URI` connects with a full connection string (`mongodb://...` or `mongodb+srv://...`), letting you reach managed/replica-set deployments (e.g. Atlas) where TLS, `replicaSet`, `authSource`, and credentials must be specified — they live in the URI's query string. Previously the adapter was hard-coded to a single `host:port` with no TLS / `authSource` / `replicaSet` / SRV support, so such instances were unreachable. When given, the URI is the source of truth: `--host`/`--port`/`--user`/`DATABASE_PASSWORD` are ignored and `--host`/`--port`/`--database` are no longer required; `--database`, if still passed, overrides the database in the URI path. The flag is mongodb-only, and the URI is never written to logs (it may carry credentials).

## [0.4.6] - 2026-06-08

### Fixed

- MySQL: INSERT statements now escape backslashes (`\` → `\\`) in string literals. Previously, values containing backslashes — such as JSON columns with `\"` sequences — were corrupted on restore because MySQL interprets `\` as an escape character in single-quoted strings. ([#85](https://github.com/heyinc/exwiw/pull/85))

## [0.4.5] - 2026-06-08

### Fixed

- MySQL: INSERT statements now backtick-quote table and column names. Previously, columns whose name is a MySQL reserved word (e.g. `key` in `active_storage_blobs`) caused syntax errors on restore. ([#83](https://github.com/heyinc/exwiw/pull/83))

## [0.4.4] - 2026-06-05

### Fixed

- MySQL: generated schema and data files now wrap statements with `SET FOREIGN_KEY_CHECKS=0` / restore, following the `mysqldump` save/restore convention (`@OLD_FOREIGN_KEY_CHECKS`). Previously the FK check preamble was lost when exwiw split `mysqldump` output into per-file schema and data files, causing `Failed to open the referenced table` errors on restore when CREATE TABLE or INSERT order didn't satisfy FK dependencies. Each file is now self-contained and restorable regardless of load order. ([#81](https://github.com/heyinc/exwiw/pull/81))

## [0.4.3] - 2026-06-05

### Fixed

- MySQL: `mysqldump` no longer fails with `Access denied; you need (at least one of) the PROCESS privilege(s)` on RDS and other managed MySQL instances where the DB user lacks `PROCESS`. The `--no-tablespaces` flag is now always passed, skipping the tablespace query that requires the privilege. Both MySQL and MariaDB support the flag.

## [0.4.2] - 2026-06-05

### Fixed

- MySQL: `mysqldump` no longer fails with `unknown variable 'set-gtid-purged=OFF'` when the client binary is MariaDB's. The adapter detects the variant via `mysqldump --version` and omits the MySQL-specific flag for MariaDB.

## [0.4.1] - 2026-06-04

### Added

- `MongoidSchemaGenerator` gains an opt-in `skip_unsupported:` mode (via the rake task, `EXWIW_SKIP_UNSUPPORTED=1 bundle exec rake exwiw:schema:generate_mongoid`). When enabled, generation no longer aborts on a construct exwiw cannot represent: an unresolvable `belongs_to` (whose target class no longer exists — e.g. a stale relation left behind after the model was removed) is skipped with a stderr warning while its foreign-key column is still kept as a field, and a polymorphic / self-referential-cyclic / unresolvable-parent `embedded_in` collection is emitted as a top-level `ignore: true` config annotated with a `comment` explaining why — so it is not wrongly dumped as its own collection — instead of raising. Off by default, so the existing fail-loud behavior is unchanged for callers that do not opt in. `MongodbCollectionConfig` now also carries an optional collection-level `comment` attribute, preserved across regeneration like the field / belongs_to `comment`.

## [0.4.0] - 2026-06-04

### Fixed

- PostgreSQL: extraction no longer fails with `operator does not exist: character varying = uuid` when a `belongs_to` chain crosses a varchar foreign key and a uuid primary key. The adapter now introspects column types via `pg_attribute`/`pg_type` at query compile time and injects `::text` casts on both sides of the comparison when a uuid/varchar mismatch is detected. Covers JOIN ON conditions, WHERE IN subqueries, and bulk-delete IN clauses. ([#73](https://github.com/heyinc/exwiw/pull/73))

## [0.3.9] - 2026-06-03

### Added

- New `exwiw:schema:tidy` rake task. It reconciles the existing schema config against the live database (read through the database connection, not the models) and removes only what no longer exists there: a config file whose table has been dropped is deleted, and columns recorded in a surviving table's config that the table no longer has are dropped from that file. Because it reads the database directly, a table that still exists in the database but has lost (or never had) a model is kept — only a genuinely-dropped table is removed. Unlike `schema:generate` it never adds or regenerates entries, so hand-edited `comment` / `ignore` / `replace_with` on surviving tables/columns are preserved. It honors `OUTPUT_DIR_PATH` and the per-database subdirectory layout, and prints the tables/columns it removed.

## [0.3.8] - 2026-06-02

### Added

- ActiveStorage support is now complete. `schema:generate` follows `has_one_attached` / `has_many_attached` macros so `active_storage_attachments` is extracted correctly via its polymorphic `belongs_to`. `active_storage_blobs` is no longer dumped wholesale: a reverse "referenced_by" extraction (a `SELECT` subquery) narrows it to only the blobs referenced by the extracted attachments. `active_storage_variant_records` (derivative, regenerable variant-tracking rows) is now emitted with `ignore: true` instead of being dumped in full — it has no path to a dump target and its `blob_id` could otherwise reference blobs outside the narrowed set, causing a foreign-key violation on import. It is also dropped from the attachments `record` polymorphic expansion so the non-ignored attachments table carries no dangling belongs_to to it. ([#69](https://github.com/heyinc/exwiw/pull/69))

## [0.3.7] - 2026-06-01

- bug fix https://github.com/heyinc/exwiw/pull/67

## [0.3.6] - 2026-06-01

## [0.3.5] - 2026-06-01

### Fixed

- MySQL export no longer crashes with `IO#write: "\xE4" from ASCII-8BIT to UTF-8 (Encoding::UndefinedConversionError)` when a value comes from a binary-collation / `VARBINARY` / `BLOB` column but holds UTF-8 text (e.g. Japanese). Both the `mysql2` and `trilogy` drivers tag such values as `ASCII-8BIT`; writing them to the UTF-8 INSERT file failed inside host processes whose `Encoding.default_internal` is UTF-8 (a Rails app, or `RUBYOPT=-EUTF-8`). The driver-returned strings are now re-tagged UTF-8 (bytes unchanged) so the write is a no-op conversion.

## [0.3.4] - 2026-05-31

### Changed

- **Breaking:** the table/collection-level config attribute `skip` is renamed to `ignore`. There is no alias — config files using `"skip": true` must be updated to `"ignore": true` (`exwiw:schema:generate` / `exwiw:mongoid:schema:generate` now emit `ignore`, e.g. for composite-primary-key tables). The library accessors are renamed accordingly (`TableConfig#skip` → `#ignore`, `MongodbCollectionConfig#skip` → `#ignore`).

### Added

- `columns` / `fields` and `belongs_tos` entries now accept optional `comment` (a free-form note) and `ignore: true`. An ignored column/field is excluded from the `SELECT` and generated `INSERT`; an ignored `belongs_to` is removed from dependency ordering and query building. These user-owned values are preserved across `exwiw:schema:generate` / `exwiw:mongoid:schema:generate` regenerations (the hand-edited value wins over the auto-generated config), like `replace_with`. The ignored entries are dropped at runtime right after the config is loaded from file, so the JSON on disk keeps them. Applies to both the SQL `TableConfig` and the MongoDB `MongodbCollectionConfig`.

### Fixed

fixed HABTM relationship bug https://github.com/heyinc/exwiw/pull/56

## [0.3.3] - 2026-05-31

### Changed

- `export` now empties `--output-dir` before writing, so a run never mixes files from a previous export. When running interactively (stdin is a tty) and the dir already has contents, exwiw asks for confirmation before removing them; in non-interactive contexts (CI, pipes) it proceeds without prompting.

## [0.3.2] - 2026-05-31

### Changed

- Adapter names are now driver-agnostic: `--adapter=mysql` and `--adapter=sqlite` replace the driver-flavored `mysql2` / `sqlite3` as the canonical names (`postgresql` and `mongodb` are unchanged). The CLI stays backward compatible — `mysql2` and `sqlite3` are accepted as aliases and folded onto the canonical name, and the matching is case-insensitive so a Rails app's `connection.adapter_name` (e.g. `Mysql2`, `SQLite`) is absorbed too. There is intentionally no `trilogy` adapter *name*: the MySQL adapter now connects through whichever of the `mysql2` or `trilogy` gem is installed (preferring `mysql2`), so an app on either driver works by passing `--adapter=mysql`. trilogy's typed result values are normalized back to the same raw strings `mysql2`'s `cast: false` returns, so the generated SQL is identical regardless of driver. **Breaking** only for code using the library classes directly: `Exwiw::Adapter::Mysql2Adapter` → `Exwiw::Adapter::MysqlAdapter` and `Exwiw::Adapter::Sqlite3Adapter` → `Exwiw::Adapter::SqliteAdapter`. The `EXWIW_DATABASE_ADAPTER` value passed to `--after-insert-hook` is now the canonical name (`mysql` / `sqlite`).

## [0.3.1] - 2026-05-31

### Changed

- **Breaking:** the `dump` subcommand is renamed to `export` to match the gem name (Export What I Want). Invoke `exwiw export ...` (or omit the subcommand, which now defaults to `export`) instead of `exwiw dump ...`. There is no `dump` alias.

## [0.3.0] - 2026-05-31

### Added

- New `--ids-column=COLUMN` CLI option matches `--ids` against an arbitrary column on the target table instead of its primary key (e.g. `--target-table=users --ids=alice@example.com --ids-column=email`). This is the SQL-adapter (mysql2/postgresql/sqlite3) counterpart of the mongodb `--ids-field`; the two are mutually exclusive and each is rejected by the other adapter family (`--ids-field` is mongodb-only, `--ids-column` is sql-only), mirroring the existing `--target-table` / `--target-collection` split. Related tables are still extracted correctly: rather than propagating `--ids` directly onto foreign keys (which would be wrong when filtering on a non-primary-key column), each foreign key is resolved through the target via a subquery (`WHERE fk IN (SELECT pk FROM target WHERE COLUMN IN (...))`), so only the target table's filter column changes and direct / indirect / polymorphic relations all extract correctly. Note: if `COLUMN` is itself masked, re-running `delete-*` against an already-imported (masked) dump won't match, so prefer a stable natural key. ([#47](https://github.com/heyinc/exwiw/pull/47))

## [0.2.9] - 2026-05-31

### Added

- New `--ids-field=FIELD` CLI option matches `--ids` against an arbitrary field on the target collection instead of its primary key (e.g. `--target-collection=users --ids=a@example.com --ids-field=email`). Only the target collection's filter changes — downstream foreign-key propagation still keys off the primary key. Unlike the primary-key path, the supplied ids are **not** type-coerced (a custom field's stored type is unknown, so values are passed through as-is). This flag is **mongodb-only**.
- New `--target-collection=COLLECTION` CLI option, a mongodb-only alias of `--target-table`. Specifying both, or using `--target-collection` with a non-mongodb adapter, is rejected at validation time.
- New rake task `exwiw:schema:generate_mongoid` (backed by `Exwiw::MongoidSchemaGenerator`) generates `MongodbCollectionConfig` files by introspecting Mongoid document models — a separate task/class from the ActiveRecord `schema:generate` because the ORMs expose different metadata. It derives the collection name, the `_id` primary key, `fields` (including referenced `belongs_to` foreign keys), `belongs_tos` from referenced `belongs_to` associations, and `embedded_in` from `embedded_in` / `embeds_many` / `embeds_one` associations (each embedded config names its immediate parent collection and `store_as` document key; nested embedding is emitted as a chain — `comments` embedded_in `posts`, `posts` embedded_in `users` — so the adapter can recurse through both array and Hash subdocuments). Regeneration preserves hand-edited `replace_with` / `filter` / `skip` / `bulk_insert_chunk_size`. Polymorphic `belongs_to` is not yet expanded. Models in an inheritance hierarchy whose subclasses share the base's collection (Mongoid STI, `_type` discriminator) collapse into a single config: subclasses are discovered via `descendants` (Mongoid registers only the base in `Mongoid.models`) and every class's `fields` / `belongs_tos` are unioned, so subclass-only fields and associations are preserved. A referenced `belongs_to` declared on an *embedded* document (e.g. `Comment embedded_in :post, belongs_to :author`) is dropped from the embedded config's `belongs_tos` (cross-collection refs from inside embedded subdocuments are unsupported and rejected on load), while its foreign-key column is still kept as an ordinary field. A `has_and_belongs_to_many` association is likewise dropped from `belongs_tos` (its foreign keys are stored as an array field such as `tag_ids`, which exwiw cannot follow as a single-valued foreign key), while that `*_ids` array column is kept as an ordinary field. A *polymorphic* `embedded_in` (`embedded_in :addressable, polymorphic: true`) has no single embedding parent collection and cannot be expressed as an `embedded_in` config, so the generator raises a clear, actionable error rather than crashing on the unresolvable parent class. A *self-referential / cyclic* embedding (Mongoid's `recursively_embeds_many` / `recursively_embeds_one`) makes a collection both top-level and embedded inside documents of its own type; since exwiw represents a collection as either top-level or embedded (not both), the generator likewise raises a clear error rather than emit an `embedded_in` config that would silently make the collection undumpable. The `created_at` / `updated_at` columns added by `include Mongoid::Timestamps` are tracked as ordinary fields, and their BSON `ObjectId` / `Date` values (the shape a live `find` returns) serialize as MongoDB Extended JSON (`$oid` / `$date`) through the dump path — now covered end-to-end against the generated configs. An aliased field (`field :ctry, as: :country`) is emitted by its **stored** document key (`ctry`), never the Ruby accessor (`country`), so masking and projection target the key that actually appears in the document; the accessor is additionally surfaced as `mongoid_field_name` on that field so the otherwise cryptic short key stays understandable (association aliases such as `shop => shop_id` and the built-in `id => _id` are not field renames and are not annotated).

### Fixed

- MongoDB adapter: `--ids` filtering against an `ObjectId` `_id` now works. `--ids` arrives as text and MongoDB compares types strictly, so a 24-char hex id is coerced to `BSON::ObjectId` (a plain String would never match). Integer-looking ids are still coerced to `Integer` and other strings (e.g. a String/UUID `_id`) are left as-is. This makes the `MongoidSchemaGenerator`-emitted `"primary_key": "_id"` configs usable end-to-end for the common case where `_id` is Mongoid's default `ObjectId`.

## [0.2.8] - 2026-05-31

### Added

- `schema:generate` now supports polymorphic `belongs_to` associations. Each polymorphic relation (`belongs_to :reviewable, polymorphic: true`) is expanded into one `belongs_to` entry per concrete target table — discovered from the other models' `has_many` / `has_one ..., as:` declarations — carrying `foreign_type` (the type column, e.g. `reviewable_type`) and `type_value` (the stored type, e.g. `"Product"`). Targets are ordered by table name so the generated output is stable across Ruby versions. At dump time, a polymorphic `belongs_to` on the path to the dump target is constrained by both the foreign key and the type column — in both the `SELECT` and the `delete-*.sql` bulk-delete subquery — so only rows of the matching type are extracted. ([#43](https://github.com/heyinc/exwiw/pull/43))

## [0.2.7] - 2026-05-30

### Added

- `schema:generate` no longer crashes on models with a composite primary key (`primary_key` returns an Array). Such tables are emitted with `skip: true`, tagged `type: "unsupported_composite_primary_key"`, and annotated with a `comment` listing the key columns. `columns` / `belongs_tos` are retained so the entry can be wired up once composite-key support lands; for now `skip: true` excludes it from extraction. `skip: true` tables no longer require `primary_key` at load time.

### Notes

- `schema:generate` multi-database support: each database keeps its own Rails migration history, so a per-database `schema_migrations` / `ar_internal_metadata` entry is emitted for every database that has one. Known limitation: the rails-managed table *name* is resolved from the global `ActiveRecord::Base.schema_migrations_table_name` / `internal_metadata_table_name` accessors, so a per-database override of those names is not detected and the table will be missing from that database's generated configs.

## [0.2.6] - 2026-05-29

### Added

- `schema:generate` now supports Rails multiple-database setups (`connects_to`). Models are bucketed by their database (`connection_db_config.name`, e.g. `primary` / `analytics`) and each database's config files are written into its own subdirectory under `OUTPUT_DIR_PATH` (`exwiw/primary/`, `exwiw/analytics/`, ...). Rails-managed tables (`schema_migrations` / `ar_internal_metadata`) are emitted under whichever database actually owns them. Single-database apps are unaffected and still write flat into the output directory. This replaces the previous behavior of raising `MultipleDatabasesNotSupportedError`.

## [0.2.5] - 2026-05-29

### Added

- `schema:generate` now auto-emits config entries for Rails-managed tables (`schema_migrations` and `ar_internal_metadata`), tagged `type: "rails_managed_schema_migrations"` / `"rails_managed_internal_metadata"`. Extraction uses `SELECT *`, INSERT omits the column list, and DELETE is not generated. Defining `primary_key`, `columns`, or `belongs_tos` on such an entry is rejected at load time, and these tables cannot be used as `--target-table`.
- Added optional `type` and `comment` fields to `TableConfig`. `primary_key` is now optional in JSON (still required for non-rails-managed tables, enforced at load time).

## [0.2.4] - 2026-05-28

### Added

- Dump/explain queries issued against the source DB now carry an identifying comment (e.g. `/* exwiw table=shops */`) so exwiw-originated queries can be spotted in `processlist` / slow query log / `db.currentOp()` and killed by table when they run long. Added to the SELECT/EXPLAIN of the `mysql2`, `postgresql`, and `sqlite3` adapters and to MongoDB `find` (via `.comment(...)`); the `explain` subcommand's printed SQL matches the emitted form. The comment is applied only at the query-issuing boundary, so generated `insert-*` / `delete-*` files (and `to_bulk_delete` subqueries) stay comment-free, and the version is intentionally omitted to keep snapshots/diffs stable. ([#35](https://github.com/heyinc/exwiw/pull/35))

## [0.2.3] - 2026-05-27

### Fixed

- PostgreSQL: schema dump now includes `CREATE TYPE ... AS ENUM` for custom enum types referenced by dumped tables. Previously `pg_dump --table` excluded schema-level type definitions, causing `type "..." does not exist` errors on import. ([#22](https://github.com/heyinc/exwiw/pull/22))

## [0.2.2] - 2026-05-26

### Changed

- `skip: true` table config now still emits the table's DDL into `insert-000-schema.{sql,js}` so downstream schemas stay consistent; only data extraction (`insert-*` / `delete-*`) is skipped. Previously the table was excluded from the schema file as well.

## [0.2.1] - 2026-05-23

### Added

- `skip: true` table config attribute to explicitly exclude a table from the dump. Skipped tables produce no schema entry, no `insert-*` file, and no `delete-*` file. Using a skipped table as `--target-table`, or having another non-skipped table reference it via `belongs_to`, raises `ArgumentError` on load. Available for both SQL adapters (`TableConfig`) and the MongoDB adapter (`MongodbCollectionConfig`). ([#26](https://github.com/heyinc/exwiw/pull/26))
- `dump` / `explain` subcommands. `dump` is the default and preserves the existing behavior when no subcommand is given. `explain` prints the compiled SQL and its `EXPLAIN` output (estimate-only — `EXPLAIN QUERY PLAN` on SQLite) for each extraction query to stdout without executing the SELECTs. Supported for `mysql2`, `postgresql`, and `sqlite3`; `mongodb` is not yet supported. ([#28](https://github.com/heyinc/exwiw/pull/28))

## [0.2.0] - 2026-05-22

### Added

- `--insert-only` CLI flag to skip generating `delete-*.sql` files. ([#23](https://github.com/heyinc/exwiw/pull/23))
- `--after-insert-hook` CLI flag to run a hook after per-table insert/delete files are generated. `.rb` hooks evaluate `insert_sql` DSL via ERB and write the result to `insert-{N+1}-after_insert.{ext}`; other executables run as a child process with `EXWIW_*` environment variables for pure side-effect hooks. ([#24](https://github.com/heyinc/exwiw/pull/24))

## [0.1.9] - 2026-05-21

  Added

  - PostgreSQL: --output-format=copy — emits COPY FROM stdin blocks instead of
  INSERT statements. Faster restores for large dumps. (c026960)
  - PostgreSQL: dump-all-tables mode — running without --target-table / --ids now
   dumps every table in the scenario. (c026960)

  Fixed

  - PostgreSQL: value escape sequences — corrected escape handling in formatted
  values. (50e6772)

https://github.com/heyinc/exwiw/pull/21

## [0.1.8] - 2026-05-16

### Added

- Emit a leading `insert-000-schema.{sql,js}` file alongside the per-table `insert-*` files so the generated dump can be applied to an empty database in one go. ([#14](https://github.com/heyinc/exwiw/pull/14))
  - SQL adapters (`mysql2`, `postgresql`, `sqlite3`) write idempotent `CREATE TABLE IF NOT EXISTS` (and `CREATE INDEX IF NOT EXISTS` where the engine supports it) by shelling out to `mysqldump` / `pg_dump` / reading `sqlite_master`. PostgreSQL `ALTER TABLE ... ADD CONSTRAINT` is wrapped in a `DO $$ EXCEPTION WHEN duplicate_object` block.
  - MongoDB adapter writes `insert-000-schema.js` containing `db.createCollection(...)` (wrapped in `try/catch` for `NamespaceExists`) and `db.<col>.createIndex(...)` calls for every top-level collection. Apply with `mongosh < dump/insert-000-schema.js`.

### Fixed

- PostgreSQL adapter now appends a `setval` for each table's sequence at the end of the `insert-*.sql` file, transcribing the source DB's `last_value` so `nextval` after restore does not collide with imported IDs. ([#19](https://github.com/heyinc/exwiw/pull/19))

## [0.1.7] - 2026-05-14

### Added

- Add embedded document support to the MongoDB adapter via `embedded_in: { collection_name, path }`. Embedded configs are not dumped as their own jsonl; their `replace_with` rules apply to subdocuments (Array or Hash, with multi-level nesting) inside the parent collection.

## [0.1.6] - 2026-03-14

### Added

- Add `bulk_insert_chunk_size` table config to split the generated `INSERT` statement into chunks of the specified size. ([#8](https://github.com/riseshia/exwiw/pull/8))
- Add experimental MongoDB adapter (`--adapter=mongodb`) that exports collections as JSONL (`insert-{idx}-{collection}.jsonl`). Embedded documents and collection-level `filter` are not supported. ([#10](https://github.com/riseshia/exwiw/pull/10))
- Introduce `MongodbCollectionConfig` for the MongoDB adapter, with MongoDB-native naming (`fields` instead of `columns`). ([#10](https://github.com/riseshia/exwiw/pull/10))

### Changed

- **Breaking (MongoDB only):** scenario JSON for the MongoDB adapter must use `fields` instead of `columns`. SQL adapters (`mysql2`, `postgresql`, `sqlite3`) are unaffected. ([#10](https://github.com/riseshia/exwiw/pull/10))
- Bump minimum required Ruby version to 3.3.0 and drop Ruby 3.2 from the CI matrix (3.2 reached EOL on 2026-03-31).
- Refactor `Adapter` contract to support non-SQL backends: introduce `Adapter#build_query`, `Adapter#output_extension`, and `Adapter#supports_bulk_delete?` hooks. SQL adapters retain existing behavior. ([#9](https://github.com/riseshia/exwiw/pull/9))
- Extract `exwiw:schema:generate` logic into `Exwiw::SchemaGenerator` so it can be exercised under RSpec without the Rake harness. ([#11](https://github.com/riseshia/exwiw/pull/11))

### Fixed

- Fix MySQL host access for local rspec runs and switch local dev scripts to inject the password via `MYSQL_PWD` env on `docker compose exec` instead of the `-p` CLI flag. ([#5](https://github.com/riseshia/exwiw/pull/5))
- Expand `~` in path arguments and validate the existence of `--config-dir`. ([#6](https://github.com/riseshia/exwiw/pull/6))
- Fix incorrect left-side table in `JOIN ... ON` clause for join chains with 3+ hops, which caused `no such column` / `column does not exist` errors at execute time. ([#7](https://github.com/riseshia/exwiw/pull/7))
- Fix hard-coded `id` primary key in `QueryAstBuilder` so non-`id` primary keys are honored when expanding `dump_target.ids` into `WHERE`. ([#9](https://github.com/riseshia/exwiw/pull/9))
- `exwiw:schema:generate` now aggregates `belongs_to` reflections across STI subclasses sharing one table; previously the first-seen class won and subclass associations could be silently dropped. ([#11](https://github.com/riseshia/exwiw/pull/11))
- `exwiw:schema:generate` now fails fast with `Exwiw::SchemaGenerator::MultipleDatabasesNotSupportedError` when models span multiple `connects_to` databases instead of silently producing a partial schema bound to a single connection. ([#11](https://github.com/riseshia/exwiw/pull/11))

## [0.1.4] - 2026-04-04

### Fixed

- Skip models whose table does not exist in `exwiw:schema:generate` task.
- Add trailing newline to generated schema files.
- Fixed foreign key constraint errors when exporting child tables with filters on intermediate tables. Filters from intermediate tables are now correctly included in JOIN clauses. ([#3](https://github.com/riseshia/exwiw/pull/3))

## [0.1.3] - 2025-04-02

### Fixed

- Generate correct schema when schema is not exist via `exwiw:schema:generate` task.

## [0.1.2] - 2025-03-11

### Changed

- Do not serialize when optional attribute is `nil`.

## [0.1.1] - 2025-03-02

### Added

- Added support for `OUTPUT_DIR_PATH` environment variable in `exwiw:schema:generate` task to specify custom output directory for generated schema files.
- When `exwiw:schema:generate` detects schema files in the output directory, it tries to keep filter and masking options.

## [0.1.0] - 2025-01-31

- Initial release

# Changelog

## [Unreleased]

### Added

- New rake task `exwiw:schema:generate_mongoid` (backed by `Exwiw::MongoidSchemaGenerator`) generates `MongodbCollectionConfig` files by introspecting Mongoid document models — a separate task/class from the ActiveRecord `schema:generate` because the ORMs expose different metadata. It derives the collection name, the `_id` primary key, `fields` (including referenced `belongs_to` foreign keys), `belongs_tos` from referenced `belongs_to` associations, and `embedded_in` from `embedded_in` / `embeds_many` / `embeds_one` associations (each embedded config names its immediate parent collection and `store_as` document key; nested embedding is emitted as a chain — `comments` embedded_in `posts`, `posts` embedded_in `users` — so the adapter can recurse through both array and Hash subdocuments). Regeneration preserves hand-edited `replace_with` / `filter` / `skip` / `bulk_insert_chunk_size`. Polymorphic `belongs_to` is not yet expanded. Models in an inheritance hierarchy whose subclasses share the base's collection (Mongoid STI, `_type` discriminator) collapse into a single config: subclasses are discovered via `descendants` (Mongoid registers only the base in `Mongoid.models`) and every class's `fields` / `belongs_tos` are unioned, so subclass-only fields and associations are preserved. A referenced `belongs_to` declared on an *embedded* document (e.g. `Comment embedded_in :post, belongs_to :author`) is dropped from the embedded config's `belongs_tos` (cross-collection refs from inside embedded subdocuments are unsupported and rejected on load), while its foreign-key column is still kept as an ordinary field. A `has_and_belongs_to_many` association is likewise dropped from `belongs_tos` (its foreign keys are stored as an array field such as `tag_ids`, which exwiw cannot follow as a single-valued foreign key), while that `*_ids` array column is kept as an ordinary field.

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

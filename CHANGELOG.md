# Changelog

## [Unreleased]

## [0.2.3] - 2026-05-27

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

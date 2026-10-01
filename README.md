# Exwiw

Export What I Want (exwiw) exports part of a database as SQL `INSERT` files: the rows related to the records you name, with sensitive columns masked. It is meant for building a development database that looks like production, without copying all of production or maintaining hand-made seed data.

Each table is described in a JSON schema config: its columns, how to mask them, and its `belongs_to` relations. Given a target table and ids, exwiw follows those relations to decide which rows of every other table to export. The schema config can be generated from ActiveRecord or Mongoid models, or from a live database.

## Installation

```bash
bundle add exwiw
```

You usually want `require: false` on the Gemfile entry. Without bundler, run `gem install exwiw`.

## Supported databases

- MySQL
- PostgreSQL
- SQLite
- MongoDB (see [MongoDB support](docs/mongodb.md))

For MySQL, exwiw uses the `mysql2` gem if it is available and `trilogy` otherwise; pass `--adapter=mysql` either way. Set `EXWIW_MYSQL_DRIVER=trilogy` (or `mysql2`) to choose one. `trilogy` helps when `mysql2` is linked against a client library that cannot load the server's auth plugin, such as a MySQL 9.x client connecting to a server that uses `mysql_native_password`.

## Usage

exwiw has three subcommands:

- `export` (the default): write the dump files.
- `explain`: print the queries `export` would run, with their `EXPLAIN` output.
- `schema generate|check|tidy --from-db`: maintain the schema config from a live database. See [Non-Rails applications](#non-rails-applications-exwiw-schema----from-db).

### `exwiw export`

```bash
# The database password is read from DATABASE_PASSWORD.
exwiw \
  --adapter=mysql \
  --host=localhost \
  --port=3306 \
  --user=reader \
  --database=app_production \
  --schema-dir=exwiw/schema \
  --target-table=shops \
  --ids=1,2 \
  --output-dir=dump
```

This exports the `shops` rows with id 1 and 2 and the rows of other tables related to them. `--schema-dir` reads every JSON file in the directory.

| `--target-table` | `--ids` | What is exported |
|---|---|---|
| given | given | The target rows by primary key, and their related rows. If the table declares a `scope_column`, [scope-column mode](#scope-column-mode) is used instead |
| omitted | given | [Scope-column mode](#scope-column-mode). An error if no table declares a `scope_column` (SQL adapters only) |
| omitted | omitted | Every table in full |

The output directory (`dump/` by default) is emptied before each run. When it already has files and stdin is a terminal, exwiw asks before removing them.

The output files are:

- `insert-000-schema.sql`: `CREATE TABLE IF NOT EXISTS ...` for every table. Run it first to create an empty database.
- `insert-{idx}-{table}.sql`: one per table. A file may depend on files with a smaller `idx`, so import them in order.

exwiw writes no `DELETE` statements. Import into an empty database, or clear the target's rows yourself.

### Restoring the dump

`insert-000-schema.sql` is created with the database's own tools (`mysqldump`, `pg_dump`, or the sqlite3 driver), so `mysqldump` or `pg_dump` must be on `PATH`. Set `EXWIW_MYSQLDUMP` to use a specific `mysqldump`, for example an 8.0 one when a 9.x `mysqldump` cannot authenticate against the server.

The schema file is rewritten so that running it again is harmless (`IF NOT EXISTS`, and PostgreSQL constraints and triggers that are skipped if they already exist). For MySQL, `DEFINER` clauses are removed so that a managed MySQL instance accepts the views and triggers.

MySQL data files turn off foreign key checks (`FOREIGN_KEY_CHECKS=0`). PostgreSQL data files set `session_replication_role = 'replica'`, which turns off both foreign key checks and triggers. This setting needs superuser (`rds_superuser` on RDS); without it a `WARNING` is printed and triggers fire. The setting stays on for the rest of the connection, so run `SET session_replication_role = 'origin'` if you keep using that connection. SQLite loads with its triggers active.

On PostgreSQL, extensions that only exist to run a managed instance (`google_vacuum_mgmt`, `google_columnar_engine`, `google_db_advisor`) are left out of the dump, because a database outside that platform cannot create them. Other extensions are kept, and are skipped with a warning when the target cannot create them.

### `exwiw explain`

Prints the query `export` would run for each table, with its `EXPLAIN` output. For the SQL adapters the SELECT is not executed. For MongoDB, see [`exwiw explain` verbosity](docs/mongodb.md#exwiw-explain-verbosity).

```bash
exwiw explain \
  --adapter=postgresql \
  --host=localhost --port=5432 --user=reader \
  --database=app_production \
  --schema-dir=exwiw/schema \
  --target-table=shops --ids=1
```

`--output-dir`, `--output-format` and `--after-insert-hook` cannot be used with `explain`.

### Config file (`exwiw.yml`)

Options can be kept in a YAML file passed with `--config=PATH`. Without `--config`, `exwiw.yml` (or `exwiw.yaml`) in the current directory is used if it exists. Options passed on the command line take precedence.

```yaml
adapter: postgresql
schema_dir: exwiw/schema
output_dir: dump
output_format: insert        # insert | copy
after_insert_hook: hooks/seed.rb
log_level: info              # debug | info
# target_table, ids, ids_field and scope_column can also be set here.
```

```bash
DATABASE_PASSWORD=... exwiw \
  --host=localhost --port=5432 --user=reader --database=app_production \
  --target-table=shops --ids=1
```

- Connection settings (`host`, `port`, `user`, `database`, `uri`, `password`) are rejected, so they stay out of a committed file. `adapter` is allowed.
- Relative paths are resolved from the config file's directory, not the current directory.
- Unknown keys are rejected. Keys that only apply to `export` are ignored by `explain` and `schema`, so all subcommands can share one file.
- MongoDB-only keys (`explain_verbosity`, `mongodb_query_timeout_ms`, `parallel_workers`) are described in [MongoDB support](docs/mongodb.md).

### Output format

For PostgreSQL, `--output-format=copy` writes `COPY ... FROM stdin` instead of `INSERT`, which loads much faster. Import it with `psql -d app_dev -f dump/insert-001-shops.sql`.

## Schema config

Each table has one JSON file:

```json
{
    "name": "users",
    "primary_key": "id",
    "belongs_tos": [{
        "table_name": "companies",
        "foreign_key": "company_id"
    }],
    "columns": [{
        "name": "id"
    }, {
        "name": "email",
        "replace_with": "user{id}@example.com"
    }, {
        "name": "company_id"
    }]
}
```

`belongs_tos` decides which rows are exported (see [How each table is narrowed](#how-each-table-is-narrowed)), and each column can be masked (see [Masking](#masking)). The other table-level keys are:

- `filter`: an SQL condition added to the table's query, such as `"access_logs.created_at > '2025-01-01'"`. It is added to every query that joins this table, so it also narrows the tables that depend on it, which can leave their foreign keys pointing at rows that were not exported. Qualify column names with the table name. A filter reduces the rows returned, not necessarily the rows read; see [Batched extraction](#batched-extraction-batch_scope) for that.
- `bulk_insert_chunk_size`: the maximum rows per `INSERT` statement (10,000 by default), to stay under limits such as MySQL's `max_allowed_packet`.
- `ignore`, `comment`: see below.

### Unknown keys are rejected

A config with a key exwiw does not know fails to load, with an error naming the key and the file. A typo such as `reverse_scop` would otherwise silently disable what it was meant to do. Use `comment` for notes.

### Ignore a table

`"ignore": true` on a table stops its data from being exported. Its `CREATE TABLE` is still written to `insert-000-schema.sql`.

- A table that has a `belongs_to` to an ignored table fails to load. Remove that `belongs_to`, or ignore it too.
- An ignored table cannot be the `--target-table`.

### Ignore / annotate a column or `belongs_to`

Entries in `columns` and `belongs_tos` accept `comment` (a note exwiw never reads) and `ignore: true`. An ignored column is not exported; it still exists in the restored table, with its default value. An ignored `belongs_to` is not followed.

```json
{
  "name": "users",
  "primary_key": "id",
  "belongs_tos": [
    { "table_name": "companies", "foreign_key": "company_id" },
    { "table_name": "audit_logs", "foreign_key": "log_id", "ignore": true, "comment": "not needed in development" }
  ],
  "columns": [
    { "name": "id" },
    { "name": "secret_token", "ignore": true, "comment": "do not copy credentials" }
  ]
}
```

### Hand-edited keys survive regeneration

Regenerating the config (see [Generating the schema config](#generating-the-schema-config)) keeps what you wrote by hand. A column already in the config is kept as it is, `comment` and `ignore` on a table or `belongs_to` are kept, and so are the keys the generators never write (`filter`, `bulk_insert_chunk_size`, `scope_column`, `id_space`, `scope_exempt`, `reverse_scope`, `batch_scope`).

## How each table is narrowed

Only the target table is filtered by `--ids` directly. exwiw narrows every other table to the rows related to the target, using the first of these rules that applies:

| # | Rule | When it applies | Result |
|---|------|-----------------|--------|
| 1 | Direct filter | The table is the `--target-table`, or declares a `scope_column` in [scope-column mode](#scope-column-mode) | `WHERE pk IN (ids)` or `WHERE scope_column IN (ids)` |
| 2 | `belongs_to` path | Following `belongs_to` reaches a table of rule 1 | Joined along the shortest path |
| 3 | Referenced by one table | No path, but exactly one narrowed table has a foreign key to it | Only the rows that table points at |
| 4 | [`reverse_scope`](#reverse-scope-for-multi-referencer-tables-reverse_scope) | Several narrowed tables point at it, and the config lists them | Only the rows the listed tables point at |
| 5 | Narrowed parent | No path, but a `belongs_to` parent is narrowed by a rule above | Only the rows belonging to the parent's exported rows, over any number of hops |
| 6 | Full dump | Nothing relates the table to the target | All rows, meant for master data. Scope-column mode stops with an error instead, unless the table has [`scope_exempt: true`](#scope_exempt-intentional-full-dump) |

- Rule 3 covers tables like `active_storage_blobs`, which nothing in the table itself links to the target. It applies only when the referencing `belongs_to` is not polymorphic.
- Rule 5 applies only when exactly one parent is narrowed, and stops at a `belongs_to` cycle.
- If a table matches both rule 3 and rule 5, rule 3 wins and the result can miss rows that rule 5 would have kept; set `ignore: true` on the referencing `belongs_to` to use rule 5.
- Whichever rule narrows a table with a `belongs_to` to itself, the ancestors of its rows are added (see [Self-referencing `belongs_to`](#self-referencing-belongs_to-tree-tables)).
- MongoDB follows the same rules, collecting the ids while it reads the parent collections instead of using SQL subqueries. It does not add ancestors.

When a rule picks the full dump because the relation was ambiguous, exwiw logs a warning. `exwiw explain` is the easiest way to see what each table resolved to. Rules 3 to 5 appear in it as a `JOIN` on a `SELECT DISTINCT` subquery; [`docs/scope-id-set-join-notes.md`](docs/scope-id-set-join-notes.md) explains why.

### Polymorphic `belongs_to`

A polymorphic association (`belongs_to :reviewable, polymorphic: true`) is written as one `belongs_to` per target table, each with the type column (`foreign_type`) and the value it holds for that target (`type_value`):

```json
{
  "name": "reviews",
  "primary_key": "id",
  "belongs_tos": [
    { "table_name": "products", "foreign_key": "reviewable_id", "foreign_type": "reviewable_type", "type_value": "Product" },
    { "table_name": "shops", "foreign_key": "reviewable_id", "foreign_type": "reviewable_type", "type_value": "Shop" }
  ],
  "columns": [{ "name": "id" }, { "name": "reviewable_type" }, { "name": "reviewable_id" }]
}
```

`exwiw:schema:generate` writes these entries from the models' `has_many ..., as:` declarations. A non-polymorphic `belongs_to` leaves out `foreign_type` and `type_value`.

Following such a `belongs_to` also checks the type column, so dumping `products` exports only the reviews with `reviewable_type = 'Product'`.

#### Every arm is extracted

When a table's path to the target goes through a polymorphic `belongs_to`, exwiw follows every entry with the same `foreign_type` and exports the union of their rows. Dumping `shops` exports the shop's own reviews and the reviews of its products.

- An entry whose target table is not narrowed is skipped, so a polymorphic `belongs_to` never widens the dump.
- If the shortest path leaves through a non-polymorphic `belongs_to`, only that path is used.
- In single-target mode, an entry is skipped when its table is narrowed only by rule 3. Those rows are exported to keep foreign keys valid, not because they own the rows that point at them. So dumping `products` still exports only the `Product` reviews, even though the product's shop is exported too. An entry whose table has a `reverse_scope` is followed.

### ActiveStorage (`has_one_attached` / `has_many_attached`)

ActiveStorage needs no configuration:

- `active_storage_attachments` is a polymorphic `belongs_to :record`, so only the attachments of exported records are exported.
- `active_storage_blobs` is narrowed by rule 3 to the blobs those attachments point at.
- `active_storage_variant_records` is generated with `ignore: true`, because ActiveStorage recreates its rows when needed and its `blob_id` could point at blobs that were not exported. Remove `ignore` if you need it.

### Reverse scope for multi-referencer tables (`reverse_scope`)

A table such as `users` often has no `belongs_to` toward the target, while many narrowed tables point at it. Rule 3 does not apply when there is more than one, so it would be dumped in full, with every tenant's users. `reverse_scope` lists the tables and columns that point at it, and the table is narrowed to the values those tables export:

```json
{
  "name": "users",
  "primary_key": "id",
  "reverse_scope": {
    "via": [
      { "table": "customers", "column": "user_id" },
      { "table": "staff", "column": "user_id" },
      { "table": "members", "column": "legacy_user_id" }
    ]
  },
  "columns": [{ "name": "id" }, { "name": "name" }]
}
```

- `column` is given explicitly, so a column with a non-standard name, or one without a `belongs_to`, works.
- List only narrowed tables. A table in `via` that is not narrowed would add every value, so it is skipped with a warning.
- A table in `via` may itself be narrowed by its own `reverse_scope`.
- By default the values are matched against the primary key. Set `reverse_scope.column` to match another column, such as `{ "column": "code", "via": [{ "table": "contracts", "column": "rate_code" }] }`.
- Tables that `belongs_to` the reverse-scoped table are narrowed by rule 5 and need no config.

### Self-referencing `belongs_to` (tree tables)

When a table has a `belongs_to` to itself, such as `categories.parent_id`, narrowing it would drop the parents of the rows it keeps. exwiw also keeps every ancestor of those rows, up to the root. Declaring the `belongs_to` is enough.

- Ancestors are kept regardless of the table's `filter` and scope, so foreign keys stay valid. If a tree spans tenants, the dump can include another tenant's ancestors.
- Tables below the tree (`category_notes`) also keep the rows of the ancestors, and tables the tree points at keep what the ancestors point at. An ancestor with many rows hanging off it brings them all; set `ignore: true` on that `belongs_to` to leave them out.
- The walk stops at a `NULL` or missing parent and at cycles in the data. Polymorphic self-references are not supported.
- On MySQL this needs 8.0 or later, and a tree deeper than `cte_max_recursion_depth` (1000 by default) fails.
- [Batched](#batched-extraction-batch_scope) tables do not get ancestors added; exwiw warns about this. MongoDB does not add ancestors either.

### Scope-column mode

Single-target mode assumes every table reaches one target table through `belongs_to`. In many multi-tenant schemas, tables instead each carry a tenant column (`tenant_id`) and are not all connected to one root. Picking one table as the target would dump the unrelated tables in full.

In scope-column mode, each table names the column that holds the tenant id, and `--ids` are values of that column:

```json
{
  "name": "shops",
  "primary_key": "id",
  "scope_column": "tenant_id",
  "columns": [{ "name": "id" }, { "name": "name" }, { "name": "tenant_id" }]
}
```

```bash
exwiw \
  --adapter=postgresql \
  --host=localhost --port=5432 --user=reader \
  --database=app_production \
  --schema-dir=exwiw/schema \
  --ids=42,43 \
  --output-dir=dump
```

Here `42,43` are `tenant_id` values, not shop ids. Passing `--target-table=shops` gives the same result.

Tables without a `scope_column` are narrowed by the rules above. A table that none of them can narrow stops the run before anything is exported, and the error lists those tables. For each, declare a `scope_column`, add a `belongs_to`, set `ignore: true`, or set `scope_exempt: true`.

Scope-column mode is for the SQL adapters only. Use `exwiw explain` to check the queries first.

#### Cross-database foreign keys

A `belongs_to` to a table in another database cannot be joined, so `schema:generate` writes it with `ignore: true`. The foreign key column is still there, so declaring `scope_column: "<that foreign key>"` on the table narrows it without a join.

#### `scope_exempt` (intentional full dump)

A master table with no personal data and no relation to the tenant can be exported in full:

```json
{ "name": "countries", "primary_key": "id", "scope_exempt": true, "columns": [{ "name": "id" }, { "name": "code" }] }
```

`schema_migrations` and `ar_internal_metadata` are exempt automatically.

#### Per-table `scope_column` and ID spaces

Each table names its own column, so tables that store the tenant id under different names work together. When one database has two groups of tables keyed by different kinds of id, give one group an `id_space` and pass its values separately:

```json
{ "name": "tenants", "primary_key": "id", "scope_column": "id", "columns": [{ "name": "id" }] }
{ "name": "organizations", "primary_key": "id", "scope_column": "id", "id_space": "org", "columns": [{ "name": "id" }] }
```

```bash
exwiw ... --ids=1,2 --ids=org=0b6f4c1e-0000-4000-8000-000000000001
```

- Tables without `id_space`, and `--ids` without a prefix, use the `default` ID space. Write `--ids=default=...` when an id itself contains `=`.
- A table without a scope column uses the ID space of the table it is narrowed through.
- The run stops before exporting when an ID space a table needs has no values, when values are given for an unused ID space, or when a table reaches tables of more than one ID space.
- Single-target mode and MongoDB support only the `default` ID space.
- In the config file, `ids:` takes a list, or a mapping such as `ids: { default: [1, 2], org: [...] }`.

The older global `--scope-column=COLUMN` flag still works but is deprecated; declare `scope_column` per table instead.

### Batched extraction (`batch_scope`)

A table with hundreds of millions of rows can be slow to export even when few of its rows are kept. Once the scope covers many parent rows, the database may decide that scanning the whole table is cheaper than using the foreign key index, and the query runs for hours or hits `statement_timeout`.

`batch_scope` avoids this by exporting the table in batches. exwiw first fetches the ids of a narrowed table on the path (the batch table), then runs one query per `size` ids, with the ids written into the query:

```json
{
  "name": "activities",
  "primary_key": "id",
  "batch_scope": { "table": "customers", "size": 1000 },
  "belongs_tos": [{ "table_name": "customers", "foreign_key": "customer_id" }],
  "columns": [{ "name": "id" }, { "name": "customer_id" }]
}
```

```sql
SELECT activities.* FROM activities
  JOIN customers ON activities.customer_id = customers.id
                AND customers.id IN (/* 1000 ids */)
```

- The exported rows are the same as without batching. The batch table's ids are sorted, so the output is the same on every run.
- `size` defaults to 1000.
- The batch table can be several hops up the path.
- A table with its own `scope_column` can name itself. This only helps when the scope column is indexed.
- `batch_scope` requires scope-column mode, and a table narrowed by rule 1 or rule 2. Other cases are rejected before anything is written.
- With `--output-format=copy`, all batches are held in memory at once. Use the default `INSERT` format for very large results.
- `exwiw explain` also shows the query that fetches the batch table's ids.

## Masking

Each column can be masked with one of the following keys.

### `replace_with`

Replaces the value with a string. `{column}` is replaced with that column's value, so for a row with `id` 1, `"user{id}@example.com"` becomes `user1@example.com`. `{}` is kept as is, so `"replace_with": "{}"` gives an empty JSON object.

A number or boolean is used as it is, so non-text columns keep their type:

```jsonc
{ "name": "score",  "replace_with": 0 }
{ "name": "active", "replace_with": false }
```

`NULL` stays `NULL` (an empty string is still replaced).

### `raw_sql`

An SQL expression used in place of the column, such as `"CONCAT('user', shops.id, '@example.com')"`. Use it when a database function is needed. Qualify column names with the table name. `replace_with` is ignored when both are set. SQL adapters only.

### `map`

Ruby code that returns a `Proc`. The proc is called with each row, and its return value (a `String`, a number or `nil`) replaces the column:

```jsonc
{ "name": "email", "map": "proc { |r| 'user' + r['id'].to_s + '@example.com' }" }
```

- `r['column']` reads any column of the row, after the database-side masking of other columns.
- `NULL` is not kept automatically; the proc receives `nil` and decides.
- It runs in the exwiw process, so `explain` does not show it. SQL adapters only.
- Because the config runs arbitrary Ruby, only load configs you trust.

Prefer `replace_with` or `raw_sql` when they can do the job.

### `replace_with_fake_data`

Replaces the value with realistic fake data from the [faker](https://github.com/faker-ruby/faker) gem. The value is chosen from a seed column, so the same seed always gives the same value, across tables, runs and adapters:

```jsonc
{ "name": "name", "replace_with_fake_data": { "seed": "users.id", "type": "human_name", "locale": "ja" } }
```

| type | example (en) | example (`locale: ja`) |
|------|--------------|------------------------|
| `human_name` | `Adrianna Kilback` | `山田 太郎` |
| `first_name` | `Adrianna` | `太郎` |
| `last_name` | `Kilback` | `山田` |
| `human_name_kana` | (ja only) | `ヤマダ タロウ` |
| `first_name_kana` | (ja only) | `タロウ` |
| `last_name_kana` | (ja only) | `ヤマダ` |
| `phone_number` | `(555) 123-4567` | |
| `address` | `282 Kevin Brook, Imogeneborough, CA 58517` | |
| `company_name` | `Hirthe-Ritchie` | |
| `email` | `cliff.fay.9d6b804eff5a3f57@example.com` | |
| `username` | `cliff.fay_9d6b804eff5a3f57` | |

- `seed` is a column of the same table, with or without the table name. Use a stable id such as the primary key.
- For one seed, the name types describe the same person: `human_name` is `last_name` + `first_name`, and the kana matches the kanji.
- Different seeds can get the same name. `email` and `username` include a token from the seed, so they stay unique.
- Values change when `locale`, the faker version, or exwiw's bundled Japanese name list changes.
- `NULL` stays `NULL`.
- Add `gem "faker"` to your Gemfile. A config that uses only `ja` name types does not need it.
- It runs in the exwiw process, so `explain` does not show it. The cost is small; see [`docs/row-transform-masking-notes.md`](docs/row-transform-masking-notes.md).

Only one masking key can be set on a column.

## Generating the schema config

In a Rails application, a rake task writes the schema config from the models:

```bash
bundle exec rake exwiw:schema:generate
```

The files go to `EXWIW_SCHEMA_DIR_PATH` if set, otherwise `schema_dir` from `exwiw.yml`, otherwise `exwiw/schema`. If the application has more than one source of models, such as ActiveRecord and Mongoid, give each its own directory; `check` and `tidy` treat files they do not recognize as stale.

### Safe mode (masking new columns by default)

A new column could hold personal data, so `schema:generate` writes every column that is not yet in the config as masked, and marks it with [`needs_mask_decision: true`](#needs_mask_decision). Columns already in the config are left as they are.

The mask is the column's default value if it has a constant one, otherwise a value by type: `masked-{primary key}` for text (with `@example.com` when the name mentions mail), `0`, `false`, a fixed date, or `{}` for JSON. Some columns are marked but left unmasked, because masking them would break the dump or the restore:

- the primary key and the columns `belongs_to` joins on
- types no constant fits, such as `uuid`, binary, enums, arrays, and text too short for the mask
- columns under a unique index, unless the mask differs per row

For the first config of an application, where every column is new, run with `EXWIW_NEW_COLUMNS=plain` to turn safe mode off. Do not use it afterwards: those columns get no mark, so nothing tells them apart from reviewed ones.

### `needs_mask_decision`

`needs_mask_decision: true` marks a column whose masking nobody has decided yet. Export ignores it. [`schema:check`](#checking-the-config-against-the-schema) reports these columns, so CI can block a pull request until each is decided. To decide, keep the mask (ideally with a `comment` saying why), change it, remove `replace_with` to export the real value, or set `ignore: true`, and then remove the key.

### Tidying stale config (`schema:tidy`)

`schema:generate` never deletes anything. `schema:tidy` removes the config files of tables that no longer exist in the database, and the columns those tables no longer have. It reads the database, not the models, so a table without a model is kept. It does not touch anything else, and does not remove stale `belongs_tos`; run `schema:generate` for those.

```bash
bundle exec rake exwiw:schema:tidy
```

### Checking the config against the schema

`schema:check` reports how the config differs from what `generate` and `tidy` would produce, without writing anything. It exits non-zero when something needs attention, so it can run in CI:

```bash
bundle exec rake exwiw:schema:check
```

```json
{
  "added_tables": [],
  "added_columns": ["users.contact_email"],
  "removed_tables": [],
  "removed_columns": ["orders.legacy_flag"],
  "changed_tables": ["orders", "users"],
  "needs_mask_decision": ["orders.memo"],
  "stale_tables": [],
  "stale_columns": ["orders.legacy_flag"]
}
```

- `added_*`, `removed_*` and `changed_tables`: run `schema:generate` and `schema:tidy`.
- `needs_mask_decision`: columns still waiting for a decision.
- `stale_*`: removed tables and columns that the config still exports, which would make the export fail. Used by `--fail-on=stale` (see [below](#non-rails-applications-exwiw-schema----from-db)).

With multiple databases each entry starts with the database name (`primary/users.email`). Set `EXWIW_SCHEMA_CHECK_OUTPUT=<path>` to also write the JSON to a file.

### Multiple databases

With Rails' multiple databases, `schema:generate` writes each database's files into a subdirectory named after it (`exwiw/schema/primary/`, `exwiw/schema/analytics/`). Each database is exported by a separate run.

A `belongs_to` to a model in another database is written with `ignore: true` and `ignore_type: "cross_database"`; see [Cross-database foreign keys](#cross-database-foreign-keys).

### Rails-managed tables and composite primary keys

`schema_migrations` and `ar_internal_metadata` get a config with a `type` such as `rails_managed_schema_migrations` and no columns. They are exported with `SELECT *` and `INSERT` without a column list, so new Rails versions do not break them. They cannot be the `--target-table`.

Composite primary keys are not supported. Such a table is generated with `ignore: true` and `type: "unsupported_composite_primary_key"`.

### Mongoid applications

```bash
bundle exec rake exwiw:schema:generate_mongoid
bundle exec rake exwiw:schema:tidy_mongoid
bundle exec rake exwiw:schema:check_mongoid
```

These work like the ActiveRecord tasks. See [Generating config from Mongoid models](docs/mongodb.md#generating-config-from-mongoid-models).

### Non-Rails applications (`exwiw schema ... --from-db`)

For applications exwiw cannot load, the same three operations read the database instead of the models:

```bash
exwiw schema generate --from-db -a postgresql -h db.example.com -p 5432 -u app --database=app --schema-dir=exwiw/schema
exwiw schema check    --from-db -a postgresql -h db.example.com -p 5432 -u app --database=app --schema-dir=exwiw/schema
exwiw schema tidy     --from-db -a postgresql -h db.example.com -p 5432 -u app --database=app --schema-dir=exwiw/schema
```

- MySQL and PostgreSQL only.
- `DATABASE_PASSWORD` may be empty, for CI databases without a password.
- Safe mode and the `check` report work as above. `check` exits 1 when the config needs attention, and with another status when it could not run.
- `check --fail-on=stale` fails only on `stale_*`, so it can run before an export without blocking on newly added columns.
- One run covers one database, and the files are written directly into the schema directory.

Foreign keys in the database become `belongs_tos`. A table without a primary key is generated with `ignore: true` and a comment; once you add a `primary_key` by hand, it is kept.

Regeneration only adds `belongs_tos`, because many relations exist only in application code. Add those by hand; they are kept from then on, and their foreign key columns are never masked. `tidy` removes a `belongs_to` whose table no longer exists.

## After-insert hook

`--after-insert-hook=PATH` runs a script after all data files are written, to add rows of your own.

A Ruby hook (`.rb`) can use:

- `cli_options`: the parsed options, such as `cli_options.fetch(:ids)`.
- `ids_for(id_space = "default")`: the ids of an [ID space](#per-table-scope_column-and-id-spaces).
- `insert_sql(template)`: renders an ERB template and writes it to `insert-{N+1}-after_insert.sql`, after the last data file. Multiple calls go into the same file.
- `insert_jsonl(collection, template)`: MongoDB only; see [MongoDB support](docs/mongodb.md).

```ruby
insert_sql <<~SQL
  <%- cli_options.fetch(:ids).each do |tenant_id| -%>
  INSERT INTO users (tenant_id, email) VALUES (<%= tenant_id %>, 'default@example.com');
  <%- end -%>
SQL
```

Ruby hooks run inside the exwiw process, so only use hooks you trust.

Any other file is run as a command. Its output is not captured, and a non-zero exit stops exwiw. It gets `DATABASE_PASSWORD` and these environment variables:

- `EXWIW_OUTPUT_DIR`, `EXWIW_SCHEMA_DIR`
- `EXWIW_DATABASE_ADAPTER`, `EXWIW_DATABASE_HOST`, `EXWIW_DATABASE_PORT`, `EXWIW_DATABASE_USER`, `EXWIW_DATABASE_NAME`
- `EXWIW_TARGET_TABLE`, `EXWIW_IDS` (comma-separated, the `default` ID space), `EXWIW_OUTPUT_FORMAT`
- `EXWIW_IDS_<ID_SPACE>` for each ID space given values (`--ids=org=...` becomes `EXWIW_IDS_ORG`)

## MongoDB

`--adapter=mongodb` exports JSON Lines for `mongoimport`. Setup, options and the differences from the SQL adapters are in [docs/mongodb.md](docs/mongodb.md).

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

To release a new version:

1. Run the **Release PR** workflow from the Actions tab with the new version number (e.g. `0.2.3`). This creates a PR that bumps `version.rb` and `CHANGELOG.md`.
2. Merge the PR. The **Release** workflow runs automatically, creating a git tag and publishing the gem to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/heyinc/exwiw.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

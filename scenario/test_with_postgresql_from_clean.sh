#!/bin/bash

# Variant of test_with_postgresql.sh that exercises the "fresh target DB" path.
# The TO database is created empty (no schema, no rows), so the run must
# succeed purely on the strength of insert-000-schema.sql creating the schema
# before subsequent insert-*.sql statements run.
#
# Unlike test_with_postgresql.sh, the delete-*.sql pass is skipped because the
# TO database has no tables to delete from.

set -e

export FROM_DATABASE_NAME="exwiw_scenario_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_dev_clean_db"

# Determine PostgreSQL command based on environment
if [ -n "$CI" ]; then
  # CI environment: use psql directly
  export PGPASSWORD="test_password"
  PSQL_CMD="psql -h 127.0.0.1 -p 5432 -U postgres"
  PSQL_FILE_CMD="psql -h 127.0.0.1 -p 5432 -U postgres"
else
  # Local environment: use docker compose exec
  PSQL_CMD="docker compose exec postgres psql -U postgres"
  PSQL_FILE_CMD="docker compose exec postgres psql -U postgres"
fi

# Clean up
$PSQL_CMD -c "DROP DATABASE IF EXISTS ${FROM_DATABASE_NAME}" > /dev/null
$PSQL_CMD -c "CREATE DATABASE ${FROM_DATABASE_NAME}" > /dev/null
$PSQL_CMD -c "DROP DATABASE IF EXISTS ${TO_DATABASE_NAME}" > /dev/null
$PSQL_CMD -c "CREATE DATABASE ${TO_DATABASE_NAME}" > /dev/null

# Seed only the FROM database. TO is left empty on purpose to validate that
# insert-000-schema.sql can stand up the schema from scratch.
if [ -n "$CI" ]; then
  $PSQL_FILE_CMD -d "${FROM_DATABASE_NAME}" -f seed/postgresql-dump.sql > /dev/null
else
  docker compose exec postgres psql -U postgres -d "${FROM_DATABASE_NAME}" -f /seed/postgresql-dump.sql > /dev/null
fi

# Clean output dir so stale insert-*.sql from a previous run (e.g. before the
# numbering changed when rails_managed entries were added) does not leak in
# via the glob loop below.
rm -rf tmp/postgresql-clean

# run exwiw — output to a dedicated dir so we don't collide with the other
# scenario's artifacts. Uses `postgresql-schema-from-clean` which augments the
# regular config dir with rails_managed_* entries (schema_migrations etc).
# Those are only safe to import into a fresh DB; the standard
# test_with_postgresql.sh seeds the target with the same dump as the source,
# so applying schema_migrations there would hit duplicate-key errors.
export DATABASE_PASSWORD="test_password"
bundle exec exe/exwiw \
  --adapter=postgresql \
  --host=127.0.0.1 \
  --port=5432 \
  --user=postgres \
  --database="${FROM_DATABASE_NAME}" \
  --schema-dir=scenario/postgresql-schema-from-clean \
  --target-table=shops \
  --ids=1 \
  --output-dir=tmp/postgresql-clean

# Apply insert-*.sql against the empty TO database. insert-000-schema.sql is
# expected to be the first file and to create every table referenced by the
# subsequent insert-*.sql statements.
for file in tmp/postgresql-clean/insert-*.sql; do
  echo "Run ${file}"
  if [ -n "$CI" ]; then
    $PSQL_FILE_CMD -d "${TO_DATABASE_NAME}" -f "${file}" > /dev/null
  else
    docker compose exec postgres psql -U postgres -d "${TO_DATABASE_NAME}" -f "/scenario/${file}" > /dev/null
  fi
done

# Verify that the schema was created and the target row landed.
echo "Verifying import to clean DB..."
COUNT=$($PSQL_CMD -d "${TO_DATABASE_NAME}" -t -c "SELECT COUNT(*) FROM shops WHERE id = 1;" | tr -d ' ')

if [ "$COUNT" -eq "1" ]; then
  echo "✓ Schema + data imported successfully into clean DB"
else
  echo "✗ Import into clean DB failed (expected 1 shop with id=1, got ${COUNT})"
  exit 1
fi

# Verify rails_managed (type=rails_managed_schema_migrations) extraction:
# the source seed has 3 migration versions, and the rails_managed dump path
# uses SELECT * with no WHERE clause, so all 3 should land regardless of the
# --target-table / --ids scoping.
echo "Verifying rails_managed schema_migrations import..."
SM_COUNT=$($PSQL_CMD -d "${TO_DATABASE_NAME}" -t -c "SELECT COUNT(*) FROM schema_migrations;" | tr -d ' ')
if [ "$SM_COUNT" -eq "3" ]; then
  echo "✓ schema_migrations: all 3 versions imported"
else
  echo "✗ schema_migrations expected 3 rows, got ${SM_COUNT}"
  exit 1
fi

# Verify that the sequence was advanced past the explicit IDs we just
# inserted. Each insert-*.sql appends a setval() so a follow-up INSERT that
# relies on the default (nextval) does not collide with existing rows.
# We use `if` (not a follow-up COUNT) because the failure mode is a duplicate
# key error from psql — `set -e` would otherwise kill the script before we
# could print a friendly diagnosis.
echo "Testing insert (auto increment) after clean import..."
if ! $PSQL_CMD -d "${TO_DATABASE_NAME}" -c "INSERT INTO shops (name, updated_at, created_at) VALUES ('Test Shop', '2025-01-01 00:00:00', '2025-01-01 00:00:00');" > /dev/null; then
  echo "✗ Auto increment failed after clean import (sequence not advanced past imported IDs)"
  exit 1
fi
echo "✓ Auto increment works after clean import"

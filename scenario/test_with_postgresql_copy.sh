#!/bin/bash

# Variant of test_with_postgresql.sh that exercises `--output-format=copy`.
# The generated insert-*.sql files contain `COPY ... FROM stdin;` blocks
# instead of bulk INSERTs. We feed them back through `psql -f` to confirm
# the produced SQL is actually valid PostgreSQL — a malformed COPY block,
# missing `\.` terminator, or unescaped value would surface here as a
# psql parse/runtime error and abort the script via `set -e`.

set -e

export FROM_DATABASE_NAME="exwiw_scenario_prod_db_copy"
export TO_DATABASE_NAME="exwiw_scenario_dev_db_copy"

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

# Setup db
if [ -n "$CI" ]; then
  $PSQL_FILE_CMD -d "${FROM_DATABASE_NAME}" -f seed/postgresql-dump.sql > /dev/null
  $PSQL_FILE_CMD -d "${TO_DATABASE_NAME}" -f seed/postgresql-dump.sql > /dev/null
else
  docker compose exec postgres psql -U postgres -d "${FROM_DATABASE_NAME}" -f /seed/postgresql-dump.sql > /dev/null
  docker compose exec postgres psql -U postgres -d "${TO_DATABASE_NAME}" -f /seed/postgresql-dump.sql > /dev/null
fi

# run exwiw
export DATABASE_PASSWORD="test_password"
bundle exec exe/exwiw \
  --adapter=postgresql \
  --host=127.0.0.1 \
  --port=5432 \
  --user=postgres \
  --database="${FROM_DATABASE_NAME}" \
  --config-dir=scenario/postgresql-schema \
  --target-table=shops \
  --ids=1 \
  --output-format=copy \
  --output-dir=tmp/postgresql-copy

# import to db
for file in tmp/postgresql-copy/delete-*.sql; do
  echo "Run ${file}"
  if [ -n "$CI" ]; then
    $PSQL_FILE_CMD -d "${TO_DATABASE_NAME}" -f "${file}" > /dev/null
  else
    docker compose exec postgres psql -U postgres -d "${TO_DATABASE_NAME}" -f "/scenario/${file}" > /dev/null
  fi
done

for file in tmp/postgresql-copy/insert-*.sql; do
  echo "Run ${file}"
  if [ -n "$CI" ]; then
    $PSQL_FILE_CMD -d "${TO_DATABASE_NAME}" -f "${file}" > /dev/null
  else
    docker compose exec postgres psql -U postgres -d "${TO_DATABASE_NAME}" -f "/scenario/${file}" > /dev/null
  fi
done

# Verify insert works after import.
# A failed INSERT (e.g. PK collision when the sequence wasn't advanced) makes
# psql exit non-zero, so we evaluate it directly with `if` instead of doing a
# follow-up COUNT — `set -e` would otherwise kill the script before we could
# print a friendly diagnosis.
echo "Testing insert after import (copy mode)..."
if ! $PSQL_CMD -d "${TO_DATABASE_NAME}" -c "INSERT INTO shops (name, updated_at, created_at) VALUES ('Test Shop', '2025-01-01 00:00:00', '2025-01-01 00:00:00');" > /dev/null; then
  echo "✗ Insert after copy-mode import failed"
  exit 1
fi
echo "✓ Insert after copy-mode import works correctly (auto increment)"

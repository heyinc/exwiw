#!/bin/bash

set -e

export FROM_DATABASE_NAME="exwiw_scenario_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_dev_db"

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

# Clean output dir so stale insert-*.sql / delete-*.sql from previous runs do
# not leak in via the glob loops below.
rm -rf tmp/postgresql

# run exwiw
export DATABASE_PASSWORD="test_password"
bundle exec exe/exwiw \
  --adapter=postgresql \
  --host=127.0.0.1 \
  --port=5432 \
  --user=postgres \
  --database="${FROM_DATABASE_NAME}" \
  --schema-dir=e2e/postgresql-schema \
  --target-table=shops \
  --ids=1 \
  --output-dir=tmp/postgresql

# import to db
for file in tmp/postgresql/delete-*.sql; do
  echo "Run ${file}"
  if [ -n "$CI" ]; then
    $PSQL_FILE_CMD -d "${TO_DATABASE_NAME}" -f "${file}" > /dev/null
  else
    docker compose exec postgres psql -U postgres -d "${TO_DATABASE_NAME}" -f "/e2e/${file}" > /dev/null
  fi
done

# stderr is kept so the trigger-suppression assertion below can see whether the
# `session_replication_role = 'replica'` block each insert-NNN file opens with
# fell back to its WARNING. psql runs as the superuser here, so it must not.
INSERT_LOG=$(mktemp)
for file in tmp/postgresql/insert-*.sql; do
  echo "Run ${file}"
  if [ -n "$CI" ]; then
    $PSQL_FILE_CMD -d "${TO_DATABASE_NAME}" -f "${file}" 2>> "${INSERT_LOG}" > /dev/null
  else
    docker compose exec postgres psql -U postgres -d "${TO_DATABASE_NAME}" -f "/e2e/${file}" 2>> "${INSERT_LOG}" > /dev/null
  fi
done

# Every data file must disable triggers/FKs for its own load, and under a
# privileged role it must succeed at it — the WARNING is the unprivileged
# fallback, not an acceptable outcome here.
echo "Verifying the data files suppress triggers during the load..."
for file in tmp/postgresql/insert-*.sql; do
  case "${file}" in */insert-000-schema.sql) continue ;; esac
  if ! grep -q "set_config('session_replication_role', 'replica', false)" "${file}"; then
    echo "✗ ${file} does not disable triggers for the load"
    exit 1
  fi
done
if grep -q 'could not disable triggers for the load' "${INSERT_LOG}"; then
  echo "✗ The load fell back to firing triggers:"
  grep 'could not disable triggers for the load' "${INSERT_LOG}"
  exit 1
fi
rm -f "${INSERT_LOG}"
echo "✓ Triggers and foreign keys were suppressed for the load"

# The seed's trigger must be in the generated schema and on the target. The TO
# database is seeded with the same dump, so the trigger already existed when
# insert-000-schema.sql was applied — which also asserts the generated
# CREATE TRIGGER is re-appliable (a bare one would have aborted with
# duplicate_object).
echo "Verifying triggers were carried into the schema and created on the target..."
if ! grep -q 'CREATE TRIGGER suppress_redundant_user_updates' tmp/postgresql/insert-000-schema.sql; then
  echo "✗ insert-000-schema.sql does not carry the source's trigger"
  exit 1
fi
TRIGGER_COUNT=$($PSQL_CMD -d "${TO_DATABASE_NAME}" -t -c "SELECT COUNT(*) FROM pg_trigger WHERE NOT tgisinternal;" | tr -d ' ')
if [ "$TRIGGER_COUNT" -eq "1" ]; then
  echo "✓ Trigger restored (and the generated schema re-applied without error)"
else
  echo "✗ Expected 1 user trigger on the target, got ${TRIGGER_COUNT}"
  exit 1
fi

# Verify insert works after import.
# A failed INSERT (e.g. PK collision when the sequence wasn't advanced) makes
# psql exit non-zero, so we evaluate it directly with `if` instead of doing a
# follow-up COUNT — `set -e` would otherwise kill the script before we could
# print a friendly diagnosis.
echo "Testing insert after import..."
if ! $PSQL_CMD -d "${TO_DATABASE_NAME}" -c "INSERT INTO shops (name, updated_at, created_at) VALUES ('Test Shop', '2025-01-01 00:00:00', '2025-01-01 00:00:00');" > /dev/null; then
  echo "✗ Insert after import failed"
  exit 1
fi
echo "✓ Insert after import works correctly (auto increment)"

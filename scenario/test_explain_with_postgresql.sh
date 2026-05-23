#!/bin/bash

set -eo pipefail

export FROM_DATABASE_NAME="exwiw_scenario_explain_db"
EXPLAIN_OUT="tmp/postgresql-explain.out"

# Determine PostgreSQL command based on environment
if [ -n "$CI" ]; then
  export PGPASSWORD="test_password"
  PSQL_CMD="psql -h 127.0.0.1 -p 5432 -U postgres"
  PSQL_FILE_CMD="psql -h 127.0.0.1 -p 5432 -U postgres"
else
  PSQL_CMD="docker compose exec postgres psql -U postgres"
  PSQL_FILE_CMD="docker compose exec postgres psql -U postgres"
fi

# Clean up
mkdir -p tmp
rm -f "$EXPLAIN_OUT" tmp/postgresql-explain.err
$PSQL_CMD -c "DROP DATABASE IF EXISTS ${FROM_DATABASE_NAME}" > /dev/null
$PSQL_CMD -c "CREATE DATABASE ${FROM_DATABASE_NAME}" > /dev/null

# Setup db
if [ -n "$CI" ]; then
  $PSQL_FILE_CMD -d "${FROM_DATABASE_NAME}" -f seed/postgresql-dump.sql > /dev/null
else
  docker compose exec postgres psql -U postgres -d "${FROM_DATABASE_NAME}" -f /seed/postgresql-dump.sql > /dev/null
fi

# Snapshot tmp/ contents before running, so we can detect any unintended file
# creation by `exwiw explain`.
tmp_before=$(ls -1 tmp 2>/dev/null | sort)

# Run `exwiw explain` and tee output to a file for later assertions while
# keeping stdout visible in CI logs.
export DATABASE_PASSWORD="test_password"
bundle exec exe/exwiw explain \
  --adapter=postgresql \
  --host=127.0.0.1 \
  --port=5432 \
  --user=postgres \
  --database="${FROM_DATABASE_NAME}" \
  --config-dir=scenario/postgresql-schema \
  --target-table=shops \
  --ids=1 \
  | tee "$EXPLAIN_OUT"

# Structural markers — one block per dumped table.
grep -q '^-- \[1/7\] shops$'              "$EXPLAIN_OUT" || { echo "✗ missing shops header";        exit 1; }
grep -q '^-- \[7/7\] transactions$'       "$EXPLAIN_OUT" || { echo "✗ missing transactions header"; exit 1; }
grep -q '^-- EXPLAIN:$'                   "$EXPLAIN_OUT" || { echo "✗ missing EXPLAIN marker";      exit 1; }

# Compiled SELECT for the dump_target.
grep -q 'SELECT shops.id'                 "$EXPLAIN_OUT" || { echo "✗ missing compiled SELECT for shops"; exit 1; }
grep -q "FROM shops WHERE shops.id = '1'" "$EXPLAIN_OUT" || { echo "✗ missing WHERE clause for shops"; exit 1; }

# PostgreSQL-specific: EXPLAIN emits node names with cost annotations like
# "Seq Scan on shops  (cost=0.00..1.06 rows=1 width=56)". Loose match.
grep -Eq '(Scan|Index|Join) .*\(cost='    "$EXPLAIN_OUT" || { echo "✗ no PG EXPLAIN cost line found"; exit 1; }

# No file should have been created in tmp/ besides our captured output.
tmp_after=$(ls -1 tmp | sort)
expected=$(printf '%s\n%s\n' "$tmp_before" "$(basename "$EXPLAIN_OUT")" | sort -u | grep -v '^$')
if [ "$tmp_after" != "$expected" ]; then
  echo "✗ explain created unexpected files in tmp/:"
  diff <(echo "$expected") <(echo "$tmp_after") || true
  exit 1
fi

echo "✓ postgresql explain produced expected output and wrote no extra files"

# Rejection case: dump-only flag must be refused.
echo "Testing explain rejection of --output-format..."
set +e
bundle exec exe/exwiw explain \
    --adapter=postgresql \
    --host=127.0.0.1 \
    --port=5432 \
    --user=postgres \
    --database="${FROM_DATABASE_NAME}" \
    --config-dir=scenario/postgresql-schema \
    --output-format=copy \
    2>&1 | tee tmp/postgresql-explain.err
rejection_exit=${PIPESTATUS[0]}
set -e
if [ "$rejection_exit" -eq 0 ]; then
  echo "✗ explain should have rejected --output-format=copy (exit 0)"
  exit 1
fi
grep -q "not applicable in 'explain'" tmp/postgresql-explain.err || {
  echo "✗ unexpected rejection message:"
  cat tmp/postgresql-explain.err
  exit 1
}
echo "✓ postgresql explain rejects --output-format with the expected message"

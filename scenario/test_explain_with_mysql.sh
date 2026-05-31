#!/bin/bash

set -eo pipefail

export FROM_DATABASE_NAME="exwiw_scenario_explain_db"
EXPLAIN_OUT="tmp/mysql-explain.out"

# Determine MySQL command based on environment
if [ -n "$CI" ]; then
  MYSQL_CMD="mysql -h 127.0.0.1 -P 3306 -u root -prootpassword"
else
  MYSQL_CMD="docker compose exec -T -e MYSQL_PWD=rootpassword mysql mysql -u root"
fi

# Clean up
mkdir -p tmp
rm -f "$EXPLAIN_OUT" tmp/mysql-explain.err
$MYSQL_CMD -e "DROP DATABASE IF EXISTS ${FROM_DATABASE_NAME}; CREATE DATABASE ${FROM_DATABASE_NAME};"

# Setup db
$MYSQL_CMD "${FROM_DATABASE_NAME}" < seed/mysql-dump.sql

# Snapshot tmp/ contents before running, so we can detect any unintended file
# creation by `exwiw explain`.
tmp_before=$(ls -1 tmp 2>/dev/null | sort)

# Run `exwiw explain` and tee output to a file for later assertions while
# keeping stdout visible in CI logs.
export DATABASE_PASSWORD="rootpassword"
bundle exec exe/exwiw explain \
  --adapter=mysql \
  --host=127.0.0.1 \
  --port=3306 \
  --user=root \
  --database="${FROM_DATABASE_NAME}" \
  --config-dir=scenario/mysql-schema \
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

# MySQL-specific: we format EXPLAIN as vertical (\G-style) rows. The header
# line is always emitted. MySQL 5.7/8.0 expose classic columns (table, type,
# rows, ...) while MySQL 8.0.16+ returns a single `EXPLAIN:` column with tree
# text — both forms include "1. row" in our output.
grep -q '1\. row'                         "$EXPLAIN_OUT" || { echo "✗ no MySQL EXPLAIN vertical row marker"; exit 1; }

# No file should have been created in tmp/ besides our captured output.
tmp_after=$(ls -1 tmp | sort)
expected=$(printf '%s\n%s\n' "$tmp_before" "$(basename "$EXPLAIN_OUT")" | sort -u | grep -v '^$')
if [ "$tmp_after" != "$expected" ]; then
  echo "✗ explain created unexpected files in tmp/:"
  diff <(echo "$expected") <(echo "$tmp_after") || true
  exit 1
fi

echo "✓ mysql explain produced expected output and wrote no extra files"

# Rejection case: dump-only flag must be refused.
echo "Testing explain rejection of --insert-only..."
set +e
bundle exec exe/exwiw explain \
    --adapter=mysql \
    --host=127.0.0.1 \
    --port=3306 \
    --user=root \
    --database="${FROM_DATABASE_NAME}" \
    --config-dir=scenario/mysql-schema \
    --insert-only \
    2>&1 | tee tmp/mysql-explain.err
rejection_exit=${PIPESTATUS[0]}
set -e
if [ "$rejection_exit" -eq 0 ]; then
  echo "✗ explain should have rejected --insert-only (exit 0)"
  exit 1
fi
grep -q "not applicable in 'explain'" tmp/mysql-explain.err || {
  echo "✗ unexpected rejection message:"
  cat tmp/mysql-explain.err
  exit 1
}
echo "✓ mysql explain rejects --insert-only with the expected message"

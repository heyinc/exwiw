#!/bin/bash

# Variant of test_with_sqlite.sh that exercises the "fresh target DB" path.
# The TO database file starts non-existent / empty (no tables), so the run
# must succeed purely on the strength of insert-000-schema.sql creating the
# schema before the subsequent insert-*.sql statements run.
#
# The delete-*.sql pass is skipped because the TO database has no tables.

set -e

TARGET_DB_PATH="tmp/scenario-target-clean.sqlite3"
NEW_DB_PATH="tmp/scenario-new-clean.sqlite3"

# Clean up
rm -rf tmp/sqlite-clean
mkdir -p tmp/sqlite-clean
rm -f "$TARGET_DB_PATH" "$NEW_DB_PATH"

# Seed only the FROM (source) database. The NEW (target) DB file is left
# unseeded on purpose; sqlite3 will create it as an empty DB when
# insert-000-schema.sql runs.
cp e2e/initdb/init.sqlite3 "$TARGET_DB_PATH"

# run exwiw — output to a dedicated dir so we don't collide with the other
# scenario's artifacts.
bundle exec exe/exwiw \
  --adapter=sqlite \
  --database="${TARGET_DB_PATH}" \
  --schema-dir=e2e/sqlite-schema \
  --target-table=shops \
  --ids=1 \
  --output-dir=tmp/sqlite-clean \
  --log-level=debug

# Apply insert-*.sql against the (non-existent) TO database file.
# insert-000-schema.sql is expected to be the first file and to create every
# table referenced by the subsequent insert-*.sql statements.
for file in tmp/sqlite-clean/insert-*.sql; do
  echo "Run ${file}"
  sqlite3 "$NEW_DB_PATH" < "${file}"
done

# Verify that the schema was created and the target row landed.
echo "Verifying import to clean DB..."
COUNT=$(sqlite3 "$NEW_DB_PATH" "SELECT COUNT(*) FROM shops WHERE id = 1;")

if [ "$COUNT" -eq "1" ]; then
  echo "✓ Schema + data imported successfully into clean DB"
else
  echo "✗ Import into clean DB failed (expected 1 shop with id=1, got ${COUNT})"
  exit 1
fi

# SQLite's INTEGER PRIMARY KEY (rowid alias) automatically picks MAX(id)+1
# on next insert, so auto-increment should work after a clean import.
# A failed INSERT makes sqlite3 exit non-zero, so we evaluate it directly
# with `if` — `set -e` would otherwise kill the script before we could print
# a friendly diagnosis.
echo "Testing insert (auto increment) after clean import..."
if ! sqlite3 "$NEW_DB_PATH" "INSERT INTO shops (name, updated_at, created_at) VALUES ('Test Shop', '2025-01-01 00:00:00', '2025-01-01 00:00:00');"; then
  echo "✗ Auto increment failed after clean import"
  exit 1
fi
echo "✓ Auto increment works after clean import"

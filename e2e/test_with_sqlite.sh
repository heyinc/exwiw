#!/bin/bash

set -e

TARGET_DB_PATH="tmp/scenario-target.sqlite3"
NEW_DB_PATH="tmp/scenario-new.sqlite3"

# Clean up
rm -rf tmp/sqlite
mkdir -p tmp/sqlite

# Setup db. The NEW (import target) DB gets the schema only: exwiw emits no
# delete-*.sql, so the target must not already hold the rows being imported.
# (sqlite_sequence is internal; sqlite3 refuses to CREATE it explicitly.)
cp e2e/initdb/init.sqlite3 $TARGET_DB_PATH
rm -f $NEW_DB_PATH
grep -vxF 'CREATE TABLE sqlite_sequence(name,seq);' seed/sqlite-schema.sql | sqlite3 $NEW_DB_PATH

# run exwiw
bundle exec exe/exwiw \
  --adapter=sqlite \
  --database="${TARGET_DB_PATH}" \
  --schema-dir=e2e/sqlite-schema \
  --target-table=shops \
  --ids=1 \
  --output-dir=tmp/sqlite \
  --log-level=debug

# import to db
bundle exec ruby e2e/import_with_sqlite.rb $NEW_DB_PATH

# Verify insert works after import.
# A failed INSERT (e.g. PK collision) makes sqlite3 exit non-zero, so we
# evaluate it directly with `if` instead of doing a follow-up COUNT — `set -e`
# would otherwise kill the script before we could print a friendly diagnosis.
echo "Testing insert after import..."
if ! sqlite3 $NEW_DB_PATH "INSERT INTO shops (name, updated_at, created_at) VALUES ('Test Shop', '2025-01-01 00:00:00', '2025-01-01 00:00:00');"; then
  echo "✗ Insert after import failed"
  exit 1
fi
echo "✓ Insert after import works correctly (auto increment)"

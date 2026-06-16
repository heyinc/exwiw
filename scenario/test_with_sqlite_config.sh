#!/bin/bash

# Same as test_with_sqlite.sh, but the stable arguments (adapter, schema-dir,
# target-table, log-level) come from a config file (scenario/exwiw.test.yml) via
# --config instead of being passed as flags. The connection (--database), the
# per-run --ids, and --output-dir are supplied on the CLI. This exercises
# config-file loading, config-relative path resolution (schema_dir: sqlite-schema
# -> scenario/sqlite-schema), and mixing config-file and CLI options.

set -e

TARGET_DB_PATH="tmp/scenario-config-target.sqlite3"
NEW_DB_PATH="tmp/scenario-config-new.sqlite3"

# Clean up (tmp/sqlite is the dump dir that import_with_sqlite.rb reads from)
rm -rf tmp/sqlite
mkdir -p tmp/sqlite

# Setup db
cp scenario/initdb/init.sqlite3 $TARGET_DB_PATH
cp scenario/initdb/init.sqlite3 $NEW_DB_PATH

# run exwiw — adapter/schema-dir/target-table/log-level are read from the config
# file; the connection, the per-run --ids, and the output dir are on the CLI.
bundle exec exe/exwiw \
  --config=scenario/exwiw.test.yml \
  --database="${TARGET_DB_PATH}" \
  --ids=1 \
  --output-dir=tmp/sqlite

# import to db
bundle exec ruby scenario/import_with_sqlite.rb $NEW_DB_PATH

# Verify insert works after import.
echo "Testing insert after import..."
if ! sqlite3 $NEW_DB_PATH "INSERT INTO shops (name, updated_at, created_at) VALUES ('Test Shop', '2025-01-01 00:00:00', '2025-01-01 00:00:00');"; then
  echo "✗ Insert after import failed"
  exit 1
fi
echo "✓ Insert after import works correctly (auto increment)"

#!/bin/bash

# Variant of test_with_mysql.sh that exercises the "fresh target DB" path.
# The TO database is created empty (no tables), so the run must succeed purely
# on the strength of insert-000-schema.sql creating the schema before the
# subsequent insert-*.sql statements run.
#
# The delete-*.sql pass is skipped because the TO database has no tables.

set -e

export FROM_DATABASE_NAME="exwiw_scenario_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_dev_clean_db"

# Determine MySQL command based on environment
if [ -n "$CI" ]; then
  MYSQL_CMD="mysql -h 127.0.0.1 -P 3306 -u root -prootpassword"
else
  MYSQL_CMD="docker compose exec -T -e MYSQL_PWD=rootpassword mysql mysql -u root"
fi

# Clean up
$MYSQL_CMD -e "DROP DATABASE IF EXISTS ${FROM_DATABASE_NAME}; CREATE DATABASE ${FROM_DATABASE_NAME};"
$MYSQL_CMD -e "DROP DATABASE IF EXISTS ${TO_DATABASE_NAME}; CREATE DATABASE ${TO_DATABASE_NAME};"

# Seed only the FROM database. TO is left empty on purpose to validate that
# insert-000-schema.sql can stand up the schema from scratch.
$MYSQL_CMD "${FROM_DATABASE_NAME}" < seed/mysql-dump.sql

# run exwiw — output to a dedicated dir so we don't collide with the other
# scenario's artifacts.
export DATABASE_PASSWORD="rootpassword"
bundle exec exe/exwiw \
  --adapter=mysql \
  --host=127.0.0.1 \
  --port=3306 \
  --user=root \
  --database="${FROM_DATABASE_NAME}" \
  --schema-dir=scenario/mysql-schema \
  --target-table=shops \
  --ids=1 \
  --output-dir=tmp/mysql-clean \
  --log-level=debug

# Apply insert-*.sql against the empty TO database. insert-000-schema.sql is
# expected to be the first file and to create every table referenced by the
# subsequent insert-*.sql statements.
for file in tmp/mysql-clean/insert-*.sql; do
  echo "Run ${file}"
  $MYSQL_CMD "${TO_DATABASE_NAME}" < "${file}"
done

# Verify that the schema was created and the target row landed.
echo "Verifying import to clean DB..."
COUNT=$($MYSQL_CMD "${TO_DATABASE_NAME}" -sN -e "SELECT COUNT(*) FROM shops WHERE id = 1;")

if [ "$COUNT" -eq "1" ]; then
  echo "✓ Schema + data imported successfully into clean DB"
else
  echo "✗ Import into clean DB failed (expected 1 shop with id=1, got ${COUNT})"
  exit 1
fi

# MySQL advances the AUTO_INCREMENT counter automatically when explicit IDs
# are inserted, so auto-increment should work after a clean import.
# A failed INSERT makes mysql exit non-zero, so we evaluate it directly with
# `if` — `set -e` would otherwise kill the script before we could print a
# friendly diagnosis.
echo "Testing insert (auto increment) after clean import..."
if ! $MYSQL_CMD "${TO_DATABASE_NAME}" -e "INSERT INTO shops (name, updated_at, created_at) VALUES ('Test Shop', '2025-01-01 00:00:00', '2025-01-01 00:00:00');"; then
  echo "✗ Auto increment failed after clean import (AUTO_INCREMENT not advanced past imported IDs)"
  exit 1
fi
echo "✓ Auto increment works after clean import"

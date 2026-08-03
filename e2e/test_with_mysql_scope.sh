#!/bin/bash

# Scope-column mode on mysql, using the same two-tenant fixture as
# test_with_sqlite_scope.sh. Its purpose is the mysql-only scope id-set
# materialization path: `attachments` reaches the scope through two polymorphic
# arms, which compile into an id-set, and the mysql adapter materializes each
# id-set into a session TEMPORARY TABLE.
#
# The log is asserted as well as the extracted rows, because a failure to
# materialize is not visible in the output: the adapter warns and falls back to
# inline scope subqueries, producing identical rows and only a slower export.

set -eo pipefail

export FROM_DATABASE_NAME="exwiw_scenario_scope_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_scope_dev_db"
OUTPUT_DIR="tmp/mysql-scope"
# Kept outside OUTPUT_DIR: exwiw clears the output dir when it starts.
LOG_FILE="tmp/mysql-scope-export.log"

# Determine MySQL command based on environment
if [ -n "$CI" ]; then
  MYSQL_CMD="mysql -h 127.0.0.1 -P 3306 -u root -prootpassword"
else
  MYSQL_CMD="docker compose exec -T -e MYSQL_PWD=rootpassword mysql mysql -u root"
fi

# Clean up
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -f "$LOG_FILE"
$MYSQL_CMD -e "DROP DATABASE IF EXISTS ${FROM_DATABASE_NAME}; CREATE DATABASE ${FROM_DATABASE_NAME};"
$MYSQL_CMD -e "DROP DATABASE IF EXISTS ${TO_DATABASE_NAME}; CREATE DATABASE ${TO_DATABASE_NAME};"

# Seed only the FROM database; insert-000-schema.sql stands up the TO schema.
$MYSQL_CMD "${FROM_DATABASE_NAME}" <<'SQL'
CREATE TABLE accounts (id INT PRIMARY KEY, tenant_id INT NOT NULL, name VARCHAR(64) NOT NULL);
CREATE TABLE orders (id INT PRIMARY KEY, tenant_id INT NOT NULL, amount INT NOT NULL);
CREATE TABLE order_lines (id INT PRIMARY KEY, order_id INT NOT NULL, qty INT NOT NULL);
CREATE TABLE regions (id INT PRIMARY KEY, code VARCHAR(8) NOT NULL);
CREATE TABLE attachments (id INT PRIMARY KEY, attachable_type VARCHAR(32) NOT NULL, attachable_id INT NOT NULL, label VARCHAR(64) NOT NULL);

INSERT INTO accounts (id, tenant_id, name) VALUES (1, 1, 'acct-t1'), (2, 2, 'acct-t2');
INSERT INTO orders (id, tenant_id, amount) VALUES (1, 1, 100), (2, 1, 200), (3, 2, 300);
INSERT INTO order_lines (id, order_id, qty) VALUES (1, 1, 5), (2, 2, 6), (3, 3, 7);
INSERT INTO regions (id, code) VALUES (1, 'JP'), (2, 'US');
INSERT INTO attachments (id, attachable_type, attachable_id, label) VALUES
  (1, 'Account', 1, 'acct-t1'),
  (2, 'Order', 1, 'order-t1'),
  (3, 'Account', 2, 'acct-t2'),
  (4, 'Order', 3, 'order-t2'),
  (5, 'Order', 2, 'order2-t1'),
  (6, 'Account', 3, 'dangling');
SQL

export DATABASE_PASSWORD="rootpassword"
bundle exec exe/exwiw \
  --adapter=mysql \
  --host=127.0.0.1 \
  --port=3306 \
  --user=root \
  --database="${FROM_DATABASE_NAME}" \
  --schema-dir=e2e/scope-schema \
  --target-table=accounts \
  --ids=1 \
  --output-dir="$OUTPUT_DIR" \
  --log-level=debug 2>&1 | tee "$LOG_FILE"

echo "Verifying scope id-set materialization..."
if ! grep -q "Materialized scope id set" "$LOG_FILE"; then
  echo "✗ no scope id-set was materialized"
  exit 1
fi
echo "✓ materialized $(grep -c "Materialized scope id set" "$LOG_FILE") scope id set(s)"

if grep -q "Disabling scope id-set materialization" "$LOG_FILE"; then
  echo "✗ materialization was disabled at runtime:"
  grep "Disabling scope id-set materialization" "$LOG_FILE"
  exit 1
fi
echo "✓ materialization stayed enabled for the whole run"

for file in $(ls "$OUTPUT_DIR"/insert-*.sql | sort); do
  echo "Run ${file}"
  $MYSQL_CMD "${TO_DATABASE_NAME}" < "${file}"
done

query_to_db() {
  $MYSQL_CMD -N -B "${TO_DATABASE_NAME}" -e "$1" | tr -d '[:space:]'
}

check_count() {
  local table="$1" expected="$2"
  local actual
  actual=$(query_to_db "SELECT COUNT(*) FROM ${table};")
  if [ "$actual" != "$expected" ]; then
    echo "✗ $table: expected $expected row(s), got $actual"
    exit 1
  fi
  echo "✓ $table: $actual row(s)"
}

check_ids() {
  local table="$1" expected="$2"
  local actual
  actual=$(query_to_db "SELECT GROUP_CONCAT(id ORDER BY id) FROM ${table};")
  if [ "$actual" != "$expected" ]; then
    echo "✗ $table ids: expected '$expected', got '$actual'"
    exit 1
  fi
  echo "✓ $table ids: $actual"
}

echo "Verifying scope extraction..."
check_count accounts 1
check_ids accounts "1"
check_count orders 2
check_ids orders "1,2"
check_count order_lines 2
check_ids order_lines "1,2"
check_count regions 2
check_ids regions "1,2"
check_count attachments 3
check_ids attachments "1,2,5"

echo "✓ scope-column mode on mysql extracted only the scoped rows via materialized id-sets"

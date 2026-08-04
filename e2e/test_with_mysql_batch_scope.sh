#!/bin/bash

# Batched extraction (`batch_scope`) on mysql: the sqlite scenario against a real
# server. mysql is covered because batch_scope is the first feature that
# round-trips driver-returned values back into a WHERE predicate, and the mysql
# driver returns every value as a String (cast: false) — so this pins down that
# the emitted `IN (...)` literals stay comparable against an integer key.

set -eo pipefail

export FROM_DATABASE_NAME="exwiw_scenario_batch_scope_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_batch_scope_dev_db"
OUTPUT_DIR="tmp/mysql-batch-scope"
SCHEMA_DIR="tmp/mysql-batch-scope-schema"
# Kept outside OUTPUT_DIR: exwiw clears the output dir when it starts.
LOG_FILE="tmp/mysql-batch-scope-export.log"

if [ -n "$CI" ]; then
  MYSQL_CMD="mysql -h 127.0.0.1 -P 3306 -u root -prootpassword"
else
  MYSQL_CMD="docker compose exec -T -e MYSQL_PWD=rootpassword mysql mysql -u root"
fi

# Clean up
rm -rf "$OUTPUT_DIR" "$SCHEMA_DIR"
mkdir -p "$OUTPUT_DIR"
rm -f "$LOG_FILE"
$MYSQL_CMD -e "DROP DATABASE IF EXISTS ${FROM_DATABASE_NAME}; CREATE DATABASE ${FROM_DATABASE_NAME};"
$MYSQL_CMD -e "DROP DATABASE IF EXISTS ${TO_DATABASE_NAME}; CREATE DATABASE ${TO_DATABASE_NAME};"

# Seed only the FROM database; insert-000-schema.sql stands up the TO schema.
# One more in-scope order than the scope scenario, so the slices do not divide
# evenly: tenant 1's three orders produce a full batch of two and a partial one.
$MYSQL_CMD "${FROM_DATABASE_NAME}" <<'SQL'
CREATE TABLE accounts (id INT PRIMARY KEY, tenant_id INT NOT NULL, name VARCHAR(64) NOT NULL);
CREATE TABLE orders (id INT PRIMARY KEY, tenant_id INT NOT NULL, amount INT NOT NULL);
CREATE TABLE order_lines (id INT PRIMARY KEY, order_id INT NOT NULL, qty INT NOT NULL);
CREATE TABLE regions (id INT PRIMARY KEY, code VARCHAR(8) NOT NULL);
CREATE TABLE attachments (id INT PRIMARY KEY, attachable_type VARCHAR(32) NOT NULL, attachable_id INT NOT NULL, label VARCHAR(64) NOT NULL);

INSERT INTO accounts (id, tenant_id, name) VALUES (1, 1, 'acct-t1'), (2, 2, 'acct-t2');
INSERT INTO orders (id, tenant_id, amount) VALUES (1, 1, 100), (2, 1, 200), (3, 2, 300), (4, 1, 400);
INSERT INTO order_lines (id, order_id, qty) VALUES (1, 1, 5), (2, 2, 6), (3, 3, 7), (4, 4, 8);
INSERT INTO regions (id, code) VALUES (1, 'JP'), (2, 'US');
INSERT INTO attachments (id, attachable_type, attachable_id, label) VALUES
  (1, 'Account', 1, 'acct-t1'),
  (2, 'Order', 1, 'order-t1'),
  (3, 'Account', 2, 'acct-t2'),
  (4, 'Order', 3, 'order-t2'),
  (5, 'Order', 2, 'order2-t1'),
  (6, 'Account', 3, 'dangling');
SQL

cp -R e2e/scope-schema "$SCHEMA_DIR"
ruby -rjson -e '
  path = ARGV[0]
  config = JSON.parse(File.read(path))
  config["batch_scope"] = { "table" => "orders", "size" => 2 }
  File.write(path, JSON.pretty_generate(config))
' "$SCHEMA_DIR/order_lines.json"

export DATABASE_PASSWORD="rootpassword"
bundle exec exe/exwiw \
  --adapter=mysql \
  --host=127.0.0.1 \
  --port=3306 \
  --user=root \
  --database="${FROM_DATABASE_NAME}" \
  --schema-dir="$SCHEMA_DIR" \
  --target-table=accounts \
  --ids=1 \
  --output-dir="$OUTPUT_DIR" \
  --log-level=debug 2>&1 | tee "$LOG_FILE"

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

check_log() {
  local pattern="$1"
  if ! grep -q "$pattern" "$LOG_FILE"; then
    echo "✗ log does not contain '$pattern'"
    exit 1
  fi
  echo "✓ log contains '$pattern'"
}

echo "Verifying batched extraction..."
# Only the lines whose order belongs to tenant 1 (orders 1, 2, 4). A row emitted
# twice would have aborted the import on order_lines' primary key.
check_count order_lines 3
check_ids order_lines "1,2,4"
check_count accounts 1
check_ids accounts "1"
check_count orders 3
check_ids orders "1,2,4"
check_count regions 2
check_ids regions "1,2"
check_count attachments 3
check_ids attachments "1,2,5"

echo "Verifying the extraction really ran in batches..."
check_log "Extracting in 2 batch(es) of up to 2 orders.id value(s) (3 in scope)"
check_log "Batch 1/2: 2 record(s), 2 so far"
check_log "Batch 2/2: 1 record(s), 3 so far"
# The mysql driver returned these ids as Strings, so they compile to quoted
# literals — which MySQL still compares correctly against the INT key.
check_log "JOIN orders ON order_lines.order_id = orders.id AND orders.id IN ('1', '2')"
check_log "JOIN orders ON order_lines.order_id = orders.id AND orders.id = '4'"

echo "✓ batch_scope extracted the same rows on mysql, one scope-id slice per query"

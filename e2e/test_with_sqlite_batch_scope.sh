#!/bin/bash

# Batched extraction (`batch_scope`) on sqlite. Reuses the scope-column fixture
# (plus one more in-scope order, so the slices do not divide evenly) with
# `batch_scope: { table: "orders", size: 2 }` on `order_lines`, so tenant 1's
# three in-scope orders produce a full batch and a partial one.
#
# Batching is invisible in the output when it works, so both halves are asserted:
# the rows match the unbatched run (e2e/test_with_sqlite_scope.sh), and the export
# really ran one query per slice, bounded by that slice's literal ids.

set -eo pipefail

TARGET_DB_PATH="tmp/scenario-batch-scope-target.sqlite3"
NEW_DB_PATH="tmp/scenario-batch-scope-new.sqlite3"
OUTPUT_DIR="tmp/sqlite-batch-scope"
SCHEMA_DIR="tmp/sqlite-batch-scope-schema"
# Kept outside $OUTPUT_DIR: exwiw clears the output dir when it starts.
LOG_FILE="tmp/sqlite-batch-scope-export.log"

# Clean up
rm -rf "$OUTPUT_DIR" "$SCHEMA_DIR"
mkdir -p "$OUTPUT_DIR"
rm -f "$TARGET_DB_PATH" "$NEW_DB_PATH" "$LOG_FILE"

SCHEMA_SQL="
CREATE TABLE accounts (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, name TEXT NOT NULL);
CREATE TABLE orders (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, amount INTEGER NOT NULL);
CREATE TABLE order_lines (id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL, qty INTEGER NOT NULL);
CREATE TABLE regions (id INTEGER PRIMARY KEY, code TEXT NOT NULL);
CREATE TABLE attachments (id INTEGER PRIMARY KEY, attachable_type TEXT NOT NULL, attachable_id INTEGER NOT NULL, label TEXT NOT NULL);
"

# Target DB: schema + seed (tenant 1 and tenant 2). order_lines #3 belongs to
# order #3, which is tenant 2, so it must NOT be exported.
sqlite3 "$TARGET_DB_PATH" "$SCHEMA_SQL"
sqlite3 "$TARGET_DB_PATH" "
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
"

# Fresh DB: schema only.
sqlite3 "$NEW_DB_PATH" "$SCHEMA_SQL"

cp -R e2e/scope-schema "$SCHEMA_DIR"
ruby -rjson -e '
  path = ARGV[0]
  config = JSON.parse(File.read(path))
  config["batch_scope"] = { "table" => "orders", "size" => 2 }
  File.write(path, JSON.pretty_generate(config))
' "$SCHEMA_DIR/order_lines.json"

bundle exec exe/exwiw \
  --adapter=sqlite \
  --database="${TARGET_DB_PATH}" \
  --schema-dir="$SCHEMA_DIR" \
  --target-table=accounts \
  --ids=1 \
  --output-dir="$OUTPUT_DIR" \
  --log-level=debug 2>&1 | tee "$LOG_FILE"

# Import into the fresh DB (schema file is CREATE TABLE IF NOT EXISTS, so it is
# a no-op against the already-created schema).
for f in $(ls "$OUTPUT_DIR"/insert-*.sql | sort); do
  echo "Run $f"
  sqlite3 "$NEW_DB_PATH" < "$f"
done

check_count() {
  local table="$1" expected="$2"
  local actual
  actual=$(sqlite3 "$NEW_DB_PATH" "SELECT COUNT(*) FROM $table;")
  if [ "$actual" != "$expected" ]; then
    echo "✗ $table: expected $expected row(s), got $actual"
    exit 1
  fi
  echo "✓ $table: $actual row(s)"
}

check_ids() {
  local table="$1" expected="$2"
  local actual
  actual=$(sqlite3 "$NEW_DB_PATH" "SELECT group_concat(id, ',') FROM (SELECT id FROM $table ORDER BY id);")
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
check_log "JOIN orders ON order_lines.order_id = orders.id AND orders.id IN (1, 2)"
check_log "JOIN orders ON order_lines.order_id = orders.id AND orders.id = 4"
# The batch ids come from the scope filter the unbatched query would carry.
check_log "SELECT orders.id FROM orders WHERE orders.tenant_id = '1'"

echo "✓ batch_scope extracted the same rows, one scope-id slice per query"

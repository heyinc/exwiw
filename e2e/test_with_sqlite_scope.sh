#!/bin/bash

# Scope-column mode: filter every table by a shared `tenant_id` instead of
# anchoring on one table's primary key. `accounts` and `orders` declare
# `scope_column: tenant_id` in their config, so naming one of them as
# --target-table runs in scope-column mode and --ids are tenant_id values (not
# primary keys). `order_lines` is reached via belongs_to to `orders`, and
# `regions` is a scope_exempt reference table exported in full. We seed two
# tenants and assert only tenant 1's rows (plus all regions) come out.

set -e

TARGET_DB_PATH="tmp/scenario-scope-target.sqlite3"
NEW_DB_PATH="tmp/scenario-scope-new.sqlite3"
OUTPUT_DIR="tmp/sqlite-scope"

# Clean up
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -f "$TARGET_DB_PATH" "$NEW_DB_PATH"

SCHEMA_SQL="
CREATE TABLE accounts (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, name TEXT NOT NULL);
CREATE TABLE orders (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, amount INTEGER NOT NULL);
CREATE TABLE order_lines (id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL, qty INTEGER NOT NULL);
CREATE TABLE regions (id INTEGER PRIMARY KEY, code TEXT NOT NULL);
"

# Target DB: schema + seed (tenant 1 and tenant 2). order_lines #3 belongs to
# order #3, which is tenant 2, so it must NOT be exported.
sqlite3 "$TARGET_DB_PATH" "$SCHEMA_SQL"
sqlite3 "$TARGET_DB_PATH" "
INSERT INTO accounts (id, tenant_id, name) VALUES (1, 1, 'acct-t1'), (2, 2, 'acct-t2');
INSERT INTO orders (id, tenant_id, amount) VALUES (1, 1, 100), (2, 1, 200), (3, 2, 300);
INSERT INTO order_lines (id, order_id, qty) VALUES (1, 1, 5), (2, 2, 6), (3, 3, 7);
INSERT INTO regions (id, code) VALUES (1, 'JP'), (2, 'US');
"

# Fresh DB: schema only.
sqlite3 "$NEW_DB_PATH" "$SCHEMA_SQL"

# Run exwiw in scope-column mode for tenant_id = 1. `accounts` declares
# scope_column: tenant_id, so --ids are matched against tenant_id and accounts
# is scoped like any other table rather than anchored by its primary key.
bundle exec exe/exwiw \
  --adapter=sqlite \
  --database="${TARGET_DB_PATH}" \
  --schema-dir=e2e/scope-schema \
  --target-table=accounts \
  --ids=1 \
  --output-dir="$OUTPUT_DIR" \
  --log-level=debug

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

echo "Verifying scope extraction..."
# accounts/orders: only tenant 1.
check_count accounts 1
check_ids accounts "1"
check_count orders 2
check_ids orders "1,2"
# order_lines: only lines whose order is tenant 1 (orders 1 and 2 -> lines 1,2).
check_count order_lines 2
check_ids order_lines "1,2"
# regions: scope_exempt -> exported in full.
check_count regions 2
check_ids regions "1,2"

echo "✓ scope-column mode extracted only the scoped rows (plus the exempt table)"

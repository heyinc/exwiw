#!/bin/bash

# Batched extraction (`batch_scope`) on postgresql: the sqlite scenario against a
# real server, plus a uuid-keyed pair. libpq returns the batch ids as text, so
# this pins down that the emitted literals stay comparable against both an integer
# and a uuid primary key.

set -e

export FROM_DATABASE_NAME="exwiw_scenario_batch_scope_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_batch_scope_dev_db"

OUTPUT_DIR="tmp/postgresql-batch-scope"
SCHEMA_DIR="tmp/postgresql-batch-scope-schema"
# Kept outside $OUTPUT_DIR: exwiw clears the output dir when it starts.
LOG_FILE="tmp/postgresql-batch-scope-export.log"

if [ -n "$CI" ]; then
  export PGPASSWORD="test_password"
  PSQL_CMD="psql -h 127.0.0.1 -p 5432 -U postgres"
else
  PSQL_CMD="docker compose exec -T postgres psql -U postgres"
fi

# Clean up
rm -rf "$OUTPUT_DIR" "$SCHEMA_DIR"
mkdir -p "$OUTPUT_DIR"
rm -f "$LOG_FILE"

$PSQL_CMD -c "DROP DATABASE IF EXISTS ${FROM_DATABASE_NAME}" > /dev/null
$PSQL_CMD -c "CREATE DATABASE ${FROM_DATABASE_NAME}" > /dev/null
$PSQL_CMD -c "DROP DATABASE IF EXISTS ${TO_DATABASE_NAME}" > /dev/null
$PSQL_CMD -c "CREATE DATABASE ${TO_DATABASE_NAME}" > /dev/null

# Source DB: schema + two tenants' rows.
$PSQL_CMD -d "${FROM_DATABASE_NAME}" > /dev/null <<'SQL'
CREATE TABLE accounts (id integer PRIMARY KEY, tenant_id integer NOT NULL, name text NOT NULL);
CREATE TABLE orders (id integer PRIMARY KEY, tenant_id integer NOT NULL, amount integer NOT NULL);
CREATE TABLE order_lines (id integer PRIMARY KEY, order_id integer NOT NULL REFERENCES orders (id), qty integer NOT NULL);
CREATE TABLE shipments (id uuid PRIMARY KEY, tenant_id integer NOT NULL, code text NOT NULL);
CREATE TABLE shipment_events (id integer PRIMARY KEY, shipment_id uuid NOT NULL REFERENCES shipments (id), state text NOT NULL);

INSERT INTO accounts (id, tenant_id, name) VALUES (1, 1, 'acct-t1'), (2, 2, 'acct-t2');
INSERT INTO orders (id, tenant_id, amount) VALUES (1, 1, 100), (2, 1, 200), (3, 2, 300), (4, 1, 400);
INSERT INTO order_lines (id, order_id, qty) VALUES (1, 1, 5), (2, 2, 6), (3, 3, 7), (4, 4, 8);
INSERT INTO shipments (id, tenant_id, code) VALUES
  ('11111111-1111-4111-8111-111111111111', 1, 'ship-t1-a'),
  ('22222222-2222-4222-8222-222222222222', 1, 'ship-t1-b'),
  ('33333333-3333-4333-8333-333333333333', 2, 'ship-t2');
INSERT INTO shipment_events (id, shipment_id, state) VALUES
  (1, '11111111-1111-4111-8111-111111111111', 'packed'),
  (2, '22222222-2222-4222-8222-222222222222', 'shipped'),
  (3, '33333333-3333-4333-8333-333333333333', 'packed');
SQL

# Target DB: left empty on purpose; insert-000-schema.sql provisions it.

# orders/shipments carry the scope column; order_lines and shipment_events reach
# it through their belongs_to and are batched by it.
mkdir -p "$SCHEMA_DIR"
cat > "$SCHEMA_DIR/accounts.json" <<'JSON'
{
  "name": "accounts",
  "primary_key": "id",
  "scope_column": "tenant_id",
  "belongs_tos": [],
  "columns": [{ "name": "id" }, { "name": "tenant_id" }, { "name": "name" }]
}
JSON
cat > "$SCHEMA_DIR/orders.json" <<'JSON'
{
  "name": "orders",
  "primary_key": "id",
  "scope_column": "tenant_id",
  "belongs_tos": [],
  "columns": [{ "name": "id" }, { "name": "tenant_id" }, { "name": "amount" }]
}
JSON
cat > "$SCHEMA_DIR/order_lines.json" <<'JSON'
{
  "name": "order_lines",
  "primary_key": "id",
  "batch_scope": { "table": "orders", "size": 2 },
  "belongs_tos": [{ "table_name": "orders", "foreign_key": "order_id" }],
  "columns": [{ "name": "id" }, { "name": "order_id" }, { "name": "qty" }]
}
JSON
cat > "$SCHEMA_DIR/shipments.json" <<'JSON'
{
  "name": "shipments",
  "primary_key": "id",
  "scope_column": "tenant_id",
  "belongs_tos": [],
  "columns": [{ "name": "id" }, { "name": "tenant_id" }, { "name": "code" }]
}
JSON
cat > "$SCHEMA_DIR/shipment_events.json" <<'JSON'
{
  "name": "shipment_events",
  "primary_key": "id",
  "batch_scope": { "table": "shipments", "size": 1 },
  "belongs_tos": [{ "table_name": "shipments", "foreign_key": "shipment_id" }],
  "columns": [{ "name": "id" }, { "name": "shipment_id" }, { "name": "state" }]
}
JSON

export DATABASE_PASSWORD="test_password"
bundle exec exe/exwiw \
  --adapter=postgresql \
  --host=127.0.0.1 \
  --port=5432 \
  --user=postgres \
  --database="${FROM_DATABASE_NAME}" \
  --schema-dir="$SCHEMA_DIR" \
  --target-table=accounts \
  --ids=1 \
  --output-dir="$OUTPUT_DIR" \
  --log-level=debug 2>&1 | tee "$LOG_FILE"

for f in $(ls "$OUTPUT_DIR"/insert-*.sql | sort); do
  echo "Run $f"
  $PSQL_CMD -d "${TO_DATABASE_NAME}" -v ON_ERROR_STOP=1 -f - < "$f" > /dev/null
done

check_ids() {
  local table="$1" expected="$2"
  local actual
  actual=$($PSQL_CMD -d "${TO_DATABASE_NAME}" -t -A -c \
    "SELECT COALESCE(string_agg(id::text, ',' ORDER BY id::text), '') FROM $table;")
  actual=$(echo "$actual" | tr -d '[:space:]')
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
# Tenant 1 owns orders 1,2,4 and the 1111.../2222... shipments. A row emitted
# twice would have aborted the import on the primary key.
check_ids order_lines "1,2,4"
check_ids shipment_events "1,2"
check_ids accounts "1"
check_ids orders "1,2,4"
check_ids shipments "11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222"

echo "Verifying the extraction really ran in batches..."
check_log "Extracting in 2 batch(es) of up to 2 orders.id value(s) (3 in scope)"
check_log "Batch 1/2: 2 record(s), 2 so far"
check_log "Batch 2/2: 1 record(s), 3 so far"
check_log "JOIN orders ON order_lines.order_id = orders.id AND orders.id IN ('1', '2')"
check_log "JOIN orders ON order_lines.order_id = orders.id AND orders.id = '4'"
check_log "Extracting in 2 batch(es) of up to 1 shipments.id value(s) (2 in scope)"
check_log "AND shipments.id = '11111111-1111-4111-8111-111111111111'"

echo "✓ batch_scope extracted the same rows on postgresql, one scope-id slice per query"

#!/bin/bash

# Scope-column mode with two ID spaces. `tenants`/`projects` and
# `organizations`/`members` are not connected by any foreign key: tenants are
# keyed by integer ids (the default ID space) and organizations by uuids (the
# `org` ID space, declared with `id_space: org`). One run extracts tenant 1 and
# organization ORG1, and the shell hook receives each space's ids.

set -e

TARGET_DB_PATH="tmp/scenario-id-spaces-target.sqlite3"
NEW_DB_PATH="tmp/scenario-id-spaces-new.sqlite3"
OUTPUT_DIR="tmp/sqlite-id-spaces"
HOOK_PATH="tmp/id-spaces-hook.sh"

ORG1="0b6f4c1e-0000-4000-8000-000000000001"
ORG2="0b6f4c1e-0000-4000-8000-000000000002"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -f "$TARGET_DB_PATH" "$NEW_DB_PATH"

SCHEMA_SQL="
CREATE TABLE tenants (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE projects (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, title TEXT NOT NULL);
CREATE TABLE organizations (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE members (id INTEGER PRIMARY KEY, organization_id TEXT NOT NULL, email TEXT NOT NULL);
"

sqlite3 "$TARGET_DB_PATH" "$SCHEMA_SQL"
sqlite3 "$TARGET_DB_PATH" "
INSERT INTO tenants (id, name) VALUES (1, 'tenant-1'), (2, 'tenant-2');
INSERT INTO projects (id, tenant_id, title) VALUES (1, 1, 'p1'), (2, 1, 'p2'), (3, 2, 'p3');
INSERT INTO organizations (id, name) VALUES ('$ORG1', 'org-1'), ('$ORG2', 'org-2');
INSERT INTO members (id, organization_id, email) VALUES
  (1, '$ORG1', 'a@example.com'),
  (2, '$ORG2', 'b@example.com'),
  (3, '$ORG1', 'c@example.com');
"

sqlite3 "$NEW_DB_PATH" "$SCHEMA_SQL"

cat > "$HOOK_PATH" <<'SH'
#!/bin/bash
echo "$EXWIW_IDS $EXWIW_IDS_ORG" > "$EXWIW_OUTPUT_DIR/hook_ids.txt"
SH
chmod +x "$HOOK_PATH"

# `--ids=1` is the default ID space (the same as `--ids=default=1`).
bundle exec exe/exwiw \
  --adapter=sqlite \
  --database="${TARGET_DB_PATH}" \
  --schema-dir=e2e/id-spaces-schema \
  --target-table=tenants \
  --ids=1 \
  --ids=org="$ORG1" \
  --after-insert-hook="$HOOK_PATH" \
  --output-dir="$OUTPUT_DIR" \
  --log-level=debug

for f in $(ls "$OUTPUT_DIR"/insert-*.sql | sort); do
  echo "Run $f"
  sqlite3 "$NEW_DB_PATH" < "$f"
done

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

echo "Verifying extraction by ID space..."
check_ids tenants "1"
check_ids projects "1,2"
check_ids organizations "$ORG1"
check_ids members "1,3"

hook_ids=$(cat "$OUTPUT_DIR/hook_ids.txt")
if [ "$hook_ids" != "1 $ORG1" ]; then
  echo "✗ hook ids: expected '1 $ORG1', got '$hook_ids'"
  exit 1
fi
echo "✓ hook ids: $hook_ids"

echo "✓ each table group was extracted by the values of its own ID space"

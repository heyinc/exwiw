#!/bin/bash

set -eo pipefail

TARGET_DB_PATH="tmp/scenario-explain-target.sqlite3"
EXPLAIN_OUT="tmp/sqlite-explain.out"

# Clean up
rm -f "$TARGET_DB_PATH" "$EXPLAIN_OUT"
mkdir -p tmp

# Setup db
cp scenario/initdb/init.sqlite3 "$TARGET_DB_PATH"

# Snapshot the current `tmp/` listing so we can detect any unintended file
# creation by `exwiw explain` (it should write only to stdout, never to disk).
tmp_before=$(ls -1 tmp 2>/dev/null | sort)

# Run `exwiw explain` and capture stdout. stderr (the logger) is allowed
# through unchanged so CI users can read the progress lines on failure.
bundle exec exe/exwiw explain \
  --adapter=sqlite \
  --database="${TARGET_DB_PATH}" \
  --schema-dir=scenario/sqlite-schema \
  --target-table=shops \
  --ids=1 \
  | tee "$EXPLAIN_OUT"

# Structural markers — one block per dumped table.
grep -q '^-- \[1/8\] shops$'             "$EXPLAIN_OUT" || { echo "✗ missing shops header";        exit 1; }
grep -q '^-- \[8/8\] transactions$'      "$EXPLAIN_OUT" || { echo "✗ missing transactions header"; exit 1; }
grep -q '^-- EXPLAIN:$'                  "$EXPLAIN_OUT" || { echo "✗ missing EXPLAIN marker";      exit 1; }

# The compiled SELECT for the dump_target must appear verbatim.
grep -q 'SELECT shops.id'                "$EXPLAIN_OUT" || { echo "✗ missing compiled SELECT for shops"; exit 1; }
grep -q "FROM shops WHERE shops.id = '1'" "$EXPLAIN_OUT" || { echo "✗ missing WHERE clause for shops"; exit 1; }

# SQLite-specific: `EXPLAIN QUERY PLAN` emits SEARCH/SCAN nodes.
grep -Eq '^(SEARCH|SCAN) '               "$EXPLAIN_OUT" || { echo "✗ no EXPLAIN QUERY PLAN node found"; exit 1; }

# No file should have been created in tmp/ besides the target DB and our
# captured output. In particular, no `dump/` directory should be created.
tmp_after=$(ls -1 tmp | sort)
expected=$(printf '%s\n%s\n%s\n' "$tmp_before" "$(basename "$TARGET_DB_PATH")" "$(basename "$EXPLAIN_OUT")" | sort -u | grep -v '^$')
if [ "$tmp_after" != "$expected" ]; then
  echo "✗ explain created unexpected files in tmp/:"
  diff <(echo "$expected") <(echo "$tmp_after") || true
  exit 1
fi

echo "✓ sqlite explain produced expected output and wrote no extra files"

# Rejection case: dump-only flag must be refused.
# `tee` lets CI logs surface the rejection message; `|| true` lets us treat the
# expected non-zero exit as success in the surrounding `set -e` script.
echo "Testing explain rejection of --output-format..."
set +e
bundle exec exe/exwiw explain \
    --adapter=sqlite \
    --database="${TARGET_DB_PATH}" \
    --schema-dir=scenario/sqlite-schema \
    --output-format=copy \
    2>&1 | tee tmp/sqlite-explain.err
rejection_exit=${PIPESTATUS[0]}
set -e
if [ "$rejection_exit" -eq 0 ]; then
  echo "✗ explain should have rejected --output-format=copy (exit 0)"
  exit 1
fi
grep -q "not applicable in 'explain'" tmp/sqlite-explain.err || {
  echo "✗ unexpected rejection message:"
  cat tmp/sqlite-explain.err
  exit 1
}
echo "✓ sqlite explain rejects --output-format with the expected message"

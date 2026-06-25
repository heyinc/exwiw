#!/bin/bash

# Exercises the opt-in MongoDB fork-parallel dump (--parallel-workers) against a
# real MongoDB, across ALL three phases of the fork schedule.
#
# The scenario uses a dedicated schema (e2e/mongodb-parallel-schema) whose graph
# is shaped so the static plan puts work in every phase when dumping shops:
#   - Phase 1: leaf pool (brands, regions) + the optimistic genuine pass
#   - Phase 2: cascade reprocess (products belongs_to the brands leaf)
#   - Phase 3: a ref_bt reference component (region_settings <- region_locales)
#
# The whole promise of the parallel schedule is byte-identical output to a
# serial dump (only *which process* writes each collection changes, never the
# bytes), so this test:
#
#   1. dumps the scenario serially into one dir,
#   2. dumps the same scope with --parallel-workers into another,
#   3. asserts the plan actually classified work into all three phases,
#   4. asserts the two dirs are byte-for-byte identical (diff -r), and
#   5. imports the parallel output and runs verify, so we also know the
#      parallel-produced dump (incl. the Phase-3 ref_bt rows) is correct.
#
# A silent fall back to the serial path (e.g. fork unavailable) would make the
# diff pass for the wrong reason, so step 3 fails loudly if the fork schedule
# did not run with the expected classification.

set -e

export FROM_DATABASE_NAME="exwiw_scenario_parallel_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_parallel_dev_db"
export MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
export MONGO_PORT="${MONGO_PORT:-27017}"

WORKERS=4
SERIAL_DIR="tmp/mongodb-parallel-serial"
PARALLEL_DIR="tmp/mongodb-parallel-fork"

mkdir -p "$SERIAL_DIR" "$PARALLEL_DIR"
rm -f "$SERIAL_DIR"/* "$PARALLEL_DIR"/*

# Setup source db. Both dumps read the same (unmodified) source.
bundle exec ruby e2e/setup_with_mongodb_parallel.rb "${FROM_DATABASE_NAME}"

common_args=(
  --adapter=mongodb
  --uri="mongodb://${MONGO_HOST}:${MONGO_PORT}/${FROM_DATABASE_NAME}"
  --schema-dir=e2e/mongodb-parallel-schema
  --target-table=shops
  --ids=d00100000000000000000001
  --log-level=info
)

# 1) Serial dump (baseline).
echo "Serial dump -> ${SERIAL_DIR}"
bundle exec exe/exwiw "${common_args[@]}" --output-dir="$SERIAL_DIR"

# 2) Parallel dump. Capture the log so we can assert the fork path actually ran
# with work in all three phases.
echo "Parallel dump (--parallel-workers=${WORKERS}) -> ${PARALLEL_DIR}"
PARALLEL_LOG="$(bundle exec exe/exwiw "${common_args[@]}" --output-dir="$PARALLEL_DIR" --parallel-workers="$WORKERS" 2>&1)"
echo "$PARALLEL_LOG"

# 3) Assert the fork schedule ran AND classified work into every phase. ref_bt>0
# is what proves Phase 3 had a reference component to fork.
if ! grep -q "MongoDB parallel dump with ${WORKERS} worker(s): genuine=2, leaves=2, ref_bt=2" <<<"$PARALLEL_LOG"; then
  echo "✗ parallel path did not run with the expected 3-phase classification (genuine=2, leaves=2, ref_bt=2)"
  exit 1
fi
echo "✓ fork schedule ran with work in all three phases (genuine=2, leaves=2, ref_bt=2)"

# 3b) Assert the per-collection extracted-record summary was logged with the
# counts collected back from EVERY phase (genuine in the parent, the leaf pool
# fork, and the ref_bt component fork). The seed is deterministic, so the counts
# are fixed: shops/products are genuine, brands/regions are leaves, and
# region_settings/region_locales are the Phase-3 ref_bt component.
for expected in "shops: 1" "products: 2" "brands: 3" "regions: 2" "region_settings: 2" "region_locales: 3"; do
  if ! grep -qF "$expected" <<<"$PARALLEL_LOG"; then
    echo "✗ per-collection summary missing or wrong: expected a '$expected' line"
    exit 1
  fi
done
echo "✓ per-collection extracted-record summary logged with counts from all phases"

# 4) Byte-identity: the core guarantee of --parallel-workers.
if diff -r "$SERIAL_DIR" "$PARALLEL_DIR"; then
  echo "✓ parallel output is byte-identical to serial"
else
  echo "✗ parallel output differs from serial dump"
  exit 1
fi

# 5) Import the parallel output and verify, so we know the parallel-produced
# dump (including the Phase-3 ref_bt collections) is correct, not merely
# identical to the baseline.
bundle exec ruby e2e/import_with_mongodb.rb --input-dir "$PARALLEL_DIR" "${TO_DATABASE_NAME}"

echo "Verifying parallel import..."
if bundle exec ruby e2e/verify_with_mongodb_parallel.rb "${TO_DATABASE_NAME}"; then
  echo "✓ MongoDB parallel scenario passed"
else
  echo "✗ MongoDB parallel scenario verification failed"
  exit 1
fi

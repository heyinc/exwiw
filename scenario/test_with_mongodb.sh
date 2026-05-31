#!/bin/bash

set -e

export FROM_DATABASE_NAME="exwiw_scenario_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_dev_db"
export MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
export MONGO_PORT="${MONGO_PORT:-27017}"

mkdir -p tmp/mongodb
rm -f tmp/mongodb/*.jsonl

# Setup source db from seed. Target db is populated entirely by import
# (MongoDB adapter has no delete-*.jsonl; import_with_mongodb.rb drops
# each target collection before insert).
bundle exec ruby scenario/setup_with_mongodb.rb "${FROM_DATABASE_NAME}"

# Run exwiw
bundle exec exe/exwiw \
  --adapter=mongodb \
  --host="${MONGO_HOST}" \
  --port="${MONGO_PORT}" \
  --database="${FROM_DATABASE_NAME}" \
  --config-dir=scenario/mongodb-schema \
  --target-table=shops \
  --ids=a00100000000000000000001 \
  --output-dir=tmp/mongodb \
  --log-level=debug

# Import generated jsonl into target
bundle exec ruby scenario/import_with_mongodb.rb "${TO_DATABASE_NAME}"

# Verify scoped dump landed correctly
echo "Verifying import..."
if bundle exec ruby scenario/verify_with_mongodb.rb "${TO_DATABASE_NAME}"; then
  echo "✓ MongoDB scenario passed"
else
  echo "✗ MongoDB scenario verification failed"
  exit 1
fi

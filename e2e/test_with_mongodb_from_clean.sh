#!/bin/bash

# Variant of test_with_mongodb.sh that exercises the "fresh target DB" path.
# The TO database starts empty (no collections, no indexes), so the run must
# succeed purely on the strength of insert-000-schema.js creating each
# collection and its indexes before the insert-*.jsonl payload lands.
#
# Unlike test_with_mongodb.sh, import_with_mongodb.rb is invoked with
# --no-drop so the collections that insert-000-schema.js just created (and
# the indexes attached to them) survive into the verify step.

set -e

export FROM_DATABASE_NAME="exwiw_scenario_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_dev_clean_db"
export MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
export MONGO_PORT="${MONGO_PORT:-27017}"

mkdir -p tmp/mongodb-clean
rm -f tmp/mongodb-clean/*.jsonl tmp/mongodb-clean/*.js

# Wipe the TO database so the from-clean assumption (no collections, no
# indexes) actually holds. mongosh with --eval lets us do this without a
# helper script.
mongosh --quiet "mongodb://${MONGO_HOST}:${MONGO_PORT}/${TO_DATABASE_NAME}" \
  --eval 'db.dropDatabase()' > /dev/null

# Setup source db from seed (also creates representative indexes that
# dump_schema should pick up).
bundle exec ruby e2e/setup_with_mongodb.rb "${FROM_DATABASE_NAME}"

# Run exwiw — output to a dedicated dir so we don't collide with the default
# scenario's artifacts.
bundle exec exe/exwiw \
  --adapter=mongodb \
  --host="${MONGO_HOST}" \
  --port="${MONGO_PORT}" \
  --database="${FROM_DATABASE_NAME}" \
  --schema-dir=e2e/mongodb-schema \
  --target-table=shops \
  --ids=a00100000000000000000001 \
  --output-dir=tmp/mongodb-clean \
  --log-level=debug

# Apply insert-000-schema.js against the empty TO database. This must create
# every collection and index referenced by the subsequent insert-*.jsonl.
SCHEMA_FILE="tmp/mongodb-clean/insert-000-schema.js"
if [ ! -f "$SCHEMA_FILE" ]; then
  echo "✗ ${SCHEMA_FILE} not generated"
  exit 1
fi
echo "Run ${SCHEMA_FILE}"
mongosh --quiet "mongodb://${MONGO_HOST}:${MONGO_PORT}/${TO_DATABASE_NAME}" "$SCHEMA_FILE"

# Import the jsonl payload into the just-created collections. --no-drop keeps
# the collections (and the indexes the schema file just made) intact.
bundle exec ruby e2e/import_with_mongodb.rb --no-drop --input-dir tmp/mongodb-clean "${TO_DATABASE_NAME}"

# Verify scoped dump landed correctly AND that the indexes round-tripped.
echo "Verifying import to clean DB..."
if bundle exec ruby e2e/verify_with_mongodb.rb "${TO_DATABASE_NAME}" --with-indexes; then
  echo "✓ MongoDB from-clean scenario passed"
else
  echo "✗ MongoDB from-clean scenario verification failed"
  exit 1
fi

#!/bin/bash

set -e

export FROM_DATABASE_NAME="exwiw_scenario_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_dev_db"
export MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
export MONGO_PORT="${MONGO_PORT:-27017}"

mkdir -p tmp/mongodb
rm -f tmp/mongodb/*.jsonl

# Setup source db from seed. Target db is populated entirely by import
# (exwiw emits no delete files; import_with_mongodb.rb drops each target
# collection before insert).
bundle exec ruby e2e/setup_with_mongodb.rb "${FROM_DATABASE_NAME}"

# Run exwiw. This scenario connects via a full --uri (rather than
# --host/--port) so the URI code path is exercised end-to-end against a real
# server; the from-clean variant still covers the --host/--port path. The
# database name is intentionally left out of the CLI and taken from the URI
# path (mongodb://host:port/<db>) to verify it resolves from the URI.
#
# --mongodb-query-timeout-ms exercises the global, server-enforced query
# timeout end-to-end (set generously so the tiny seed always finishes within
# it). The per-collection override is exercised too: e2e/mongodb-schema/users.json
# carries its own query_timeout_ms.
bundle exec exe/exwiw \
  --adapter=mongodb \
  --uri="mongodb://${MONGO_HOST}:${MONGO_PORT}/${FROM_DATABASE_NAME}" \
  --schema-dir=e2e/mongodb-schema \
  --target-table=shops \
  --ids=a00100000000000000000001 \
  --output-dir=tmp/mongodb \
  --mongodb-query-timeout-ms=60000 \
  --log-level=debug

# Import generated jsonl into target
bundle exec ruby e2e/import_with_mongodb.rb "${TO_DATABASE_NAME}"

# Verify scoped dump landed correctly
echo "Verifying import..."
if bundle exec ruby e2e/verify_with_mongodb.rb "${TO_DATABASE_NAME}"; then
  echo "✓ MongoDB scenario passed"
else
  echo "✗ MongoDB scenario verification failed"
  exit 1
fi

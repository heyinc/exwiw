#!/bin/bash

# Scenario exercising `--ids-field`: the target collection is matched on a
# non-_id field (business_entities.uuid, a String) rather than its ObjectId
# `_id`. It also confirms downstream `references`-based FK propagation works
# from a uuid-targeted root (sites.business_entity_uuid -> business_entities.uuid).
#
# A dedicated schema-dir (scenario/mongodb-schema-ids-field) holds only
# business_entities + sites so the dump stays scoped: the default scenario
# config's root collections (shops, system_announcements) have no belongs_to
# and would otherwise each dump in full and cascade. For the same reason
# business_entities here drops its `belongs_to shops` — the target is matched by
# uuid and we only want to follow the sites chain downstream.

set -e

export FROM_DATABASE_NAME="exwiw_scenario_prod_db"
export TO_DATABASE_NAME="exwiw_scenario_dev_ids_field_db"
export MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
export MONGO_PORT="${MONGO_PORT:-27017}"

mkdir -p tmp/mongodb-ids-field
rm -f tmp/mongodb-ids-field/*.jsonl

# Setup source db from seed (shares the seed with test_with_mongodb.sh; the
# schema-dir, not the seed, is what scopes this scenario to two collections).
bundle exec ruby scenario/setup_with_mongodb.rb "${FROM_DATABASE_NAME}"

# Target business_entities by its `uuid` field via --ids-field (and exercise the
# mongodb-only --target-collection alias while we are at it).
bundle exec exe/exwiw \
  --adapter=mongodb \
  --host="${MONGO_HOST}" \
  --port="${MONGO_PORT}" \
  --database="${FROM_DATABASE_NAME}" \
  --schema-dir=scenario/mongodb-schema-ids-field \
  --target-collection=business_entities \
  --ids=be-uuid-0001 \
  --ids-field=uuid \
  --output-dir=tmp/mongodb-ids-field \
  --log-level=debug

# Import generated jsonl into target
bundle exec ruby scenario/import_with_mongodb.rb --input-dir tmp/mongodb-ids-field "${TO_DATABASE_NAME}"

# Verify scoped dump landed correctly
echo "Verifying import..."
if bundle exec ruby scenario/verify_with_mongodb_ids_field.rb "${TO_DATABASE_NAME}"; then
  echo "✓ MongoDB --ids-field scenario passed"
else
  echo "✗ MongoDB --ids-field scenario verification failed"
  exit 1
fi

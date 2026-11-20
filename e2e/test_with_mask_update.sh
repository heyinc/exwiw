#!/bin/bash

# Applies the UPDATEs (canonical Extended JSON lines for MongoDB, applied by e2e/mask_update_apply.js) from Exwiw::MaskUpdateRunner to a
# real database and compares the result with what export produces. The sqlite
# scenario runs without any server; the others need the test databases (see
# script/database_config.rb; MongoDB also needs mongosh on PATH). Pass adapter names to run a subset.

set -e

ADAPTERS=("$@")
if [ ${#ADAPTERS[@]} -eq 0 ]; then
  ADAPTERS=(sqlite postgresql mysql mongodb)
fi

for adapter in "${ADAPTERS[@]}"; do
  echo "== mask-update scenario: ${adapter}"
  bundle exec ruby e2e/mask_update_scenario.rb "${adapter}"
done

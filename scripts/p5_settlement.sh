#!/usr/bin/env bash
# scripts/p5_settlement.sh — generate 3PL settlement files, upload to external/
# RUN IN AZURE CLOUD SHELL. Needs Storage Blob Data Contributor on your own
# identity (granted in Part 4).
set -euo pipefail
cd "$(dirname "$0")/.."

SA="${SA:-snowflakeqcpoc25056}"
DAYS="${DAYS:-7}"
DIR="source/out/settlement"

echo "== generating"
python3 source/gen_settlement.py --days "$DAYS"

echo
echo "== uploading to $SA/external/settlement/"
for f in "$DIR"/*.csv; do
  az storage blob upload --account-name "$SA" --auth-mode login \
    --container-name external --name "settlement/$(basename "$f")" \
    --file "$f" --overwrite -o none
  echo "  uploaded $(basename "$f")"
done

az storage blob list --account-name "$SA" --auth-mode login \
  --container-name external --prefix settlement/ \
  --query "[].{name:name, size:properties.contentLength}" -o table

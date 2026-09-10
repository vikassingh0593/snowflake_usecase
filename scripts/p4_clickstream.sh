#!/usr/bin/env bash
# =============================================================================
# scripts/p4_clickstream.sh — generate the clickstream and upload it to landing/
#
# RUN IN AZURE CLOUD SHELL. It has python3 and az, and the generator is standard
# library only, so nothing needs installing on either machine.
#
# Why not from Snowflake: landing/ is granted Storage Blob Data READER to the
# Snowflake service principal. Snowflake reads that container and never writes
# it, which is the correct least privilege for a landing zone. Generating the
# files somewhere with write access keeps that intact instead of widening the
# grant for test data.
#
# PREREQUISITE, once per storage account. Owning the subscription lets you
# CREATE the storage account but grants no blob data access - control plane and
# data plane are separate in Azure, which is the same distinction that made
# SYSTEM$VERIFY_EXTERNAL_VOLUME fail on the delegation key. Without it,
# --auth-mode login returns "You do not have the required permissions":
#
#   ME=$(az ad signed-in-user show --query id -o tsv)
#   az role assignment create --assignee-object-id "$ME" \
#     --assignee-principal-type User --role "Storage Blob Data Contributor" \
#     --scope "/subscriptions/<sub>/resourceGroups/rg-qcpoc/providers/Microsoft.Storage/storageAccounts/<sa>"
#
# Deliberately not --auth-mode key. The account key is unscoped, never expires
# and would sit in shell history; a scoped grant on your own identity costs one
# command. Note the asymmetry: Snowflake's principal has READER on landing/
# because it only reads, while the producer needs CONTRIBUTOR.
#
#   git clone/pull, then:
#   bash scripts/p4_clickstream.sh              24 files, ~50k events
#   HOURS=4 TARGET=8000 bash scripts/p4_clickstream.sh    quick test
#   UPLOAD=0 bash scripts/p4_clickstream.sh     generate only, do not upload
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SA="${SA:-snowflakeqcpoc25056}"
HOURS="${HOURS:-24}"
TARGET="${TARGET:-50000}"
UPLOAD="${UPLOAD:-1}"
DIR="source/out/clickstream"

echo "== generating"
python3 source/gen_clickstream.py --hours "$HOURS" --target "$TARGET"

[ "$UPLOAD" = "1" ] || { echo "UPLOAD=0, stopping after generate"; exit 0; }

echo
echo "== uploading to $SA/landing/clickstream/"
# Uploaded one at a time on purpose. Each blob creation raises a separate
# Event Grid notification onto snowpipe-queue, so Snowpipe sees N distinct
# files arriving rather than one batch - which is what makes the auto-ingest
# behaviour visible in COPY_HISTORY instead of a single opaque load.
for f in "$DIR"/*.ndjson.gz; do
  az storage blob upload \
    --account-name "$SA" --auth-mode login \
    --container-name landing \
    --name "clickstream/$(basename "$f")" \
    --file "$f" --overwrite -o none
  echo "  uploaded $(basename "$f")"
done

echo
echo "== blobs now in landing/clickstream/"
az storage blob list --account-name "$SA" --auth-mode login \
  --container-name landing --prefix clickstream/ \
  --query "[].{name:name, size:properties.contentLength}" -o table

cat <<'EOF'

== Next, in Snowflake
   The pipe polls the Event Grid queue. Give it a minute, then:
     SELECT SYSTEM$PIPE_STATUS('QCOMMERCE.LAND.PIPE_CLICKSTREAM_AUTO');
     SELECT COUNT(*) FROM QCOMMERCE.RAW.CLICKSTREAM_AUTO;
EOF

#!/usr/bin/env bash
# =============================================================================
# scripts/p2_azure.sh — Azure side of the foundation.
#
# Run in Azure Cloud Shell (https://shell.azure.com) — az is preinstalled, so
# nothing to install on your Mac and the broken Homebrew stays out of it.
#
#   git clone https://github.com/vikassingh0593/snowflake_usecase.git
#   cd snowflake_usecase
#   bash scripts/p2_azure.sh            # READ-ONLY. Inspects and reports.
#   CREATE=1 bash scripts/p2_azure.sh   # Actually creates things.
#
# Cost: under 500 MB of hot blob. Azure free tier includes ~5 GB LRS hot
# (UNVERIFIED). Expect Rs 0-50 for the life of the PoC.
# =============================================================================
set -euo pipefail

SA="${SA:-snowflakefreeedition}"     # override: SA=snowflakeqcpoc123 bash ...
RG="${RG:-rg-qcpoc}"
LOC="westus2"
QUEUE="snowpipe-queue"
CREATE="${CREATE:-0}"

blue() { printf "\n\033[1;34m== %s\033[0m\n" "$1"; }

blue "Subscription and tenant"
az account show --query "{tenantId:tenantId, subscription:name, subId:id}" -o table

blue "Looking for storage account '$SA'"
FOUND=$(az storage account list --query "[?name=='$SA'] | [0]" -o json)

if [ "$FOUND" = "null" ] || [ -z "$FOUND" ]; then
  echo "  not found anywhere in this subscription"
  REUSE=no
  SA_RG=""
else
  SA_RG=$(echo "$FOUND" | python3 -c 'import json,sys; print(json.load(sys.stdin)["resourceGroup"])')
  SA_LOC=$(echo "$FOUND" | python3 -c 'import json,sys; print(json.load(sys.stdin)["location"])')
  SA_HNS=$(echo "$FOUND" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("isHnsEnabled"))')
  SA_KIND=$(echo "$FOUND" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')
  printf "  resource group : %s\n  location       : %s\n  HNS enabled    : %s\n  kind           : %s\n" \
         "$SA_RG" "$SA_LOC" "$SA_HNS" "$SA_KIND"

  # Hierarchical namespace must be OFF. With HNS on, the Iceberg dfs endpoint
  # was still Preview as of March 2026, and COPY ... PURGE fails because Azure
  # only deletes empty directories. Plain GPv2 blob is the GA path.
  # isHnsEnabled reports None when the flag was never set, which means
  # DISABLED. Only True is disqualifying.
  if [ "$SA_LOC" = "$LOC" ] && [ "$SA_HNS" != "True" ]; then
    REUSE=yes
  else
    REUSE=no
    [ "$SA_LOC" != "$LOC" ] && echo "  REJECT: not in $LOC"
    [ "$SA_HNS" = "True" ] && echo "  REJECT: hierarchical namespace is on — breaks Iceberg and COPY ... PURGE"
  fi
fi

blue "Verdict"
if [ "$REUSE" = "yes" ]; then
  TARGET_SA="$SA"; TARGET_RG="$SA_RG"
  echo "  reuse $SA in $SA_RG"
else
  # Reuse an account this script already created, so re-running does not
  # mint a second one. Only invent a name when rg-qcpoc has none.
  EXISTING=$(az storage account list -g "$RG" \
             --query "[?starts_with(name,'snowflakeqcpoc')] | [0].name" -o tsv 2>/dev/null || true)
  TARGET_RG="$RG"
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    TARGET_SA="$EXISTING"; REUSE=yes
    echo "  reuse $TARGET_SA, already created in $TARGET_RG"
  else
    TARGET_SA="snowflakeqcpoc$RANDOM"
    echo "  create a fresh account: $TARGET_SA in $TARGET_RG ($LOC)"
  fi
fi

if [ "$CREATE" != "1" ]; then
  cat <<EOF

  Read-only pass complete. Nothing was created.
  To proceed:   CREATE=1 SA=$TARGET_SA bash scripts/p2_azure.sh

  It would create:
    resource group   $TARGET_RG (if missing)
    storage account  $TARGET_SA  GPv2, LRS, hot, no public blob, TLS1_2, HNS OFF
    containers       landing archive external docs
    queue            $QUEUE
    event grid       system topic st-qcpoc -> $QUEUE, BlobCreated on landing/
    lifecycle        delete landing blobs after 14 days
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
blue "Creating"
if ! az group exists -n "$TARGET_RG" | grep -qi true; then
  az group create -n "$TARGET_RG" -l "$LOC" -o none
  echo "  resource group $TARGET_RG created"
fi

if [ "$REUSE" != "yes" ]; then
  # NOTE: --enable-hierarchical-namespace is deliberately NOT passed.
  az storage account create -n "$TARGET_SA" -g "$TARGET_RG" -l "$LOC" \
    --sku Standard_LRS --kind StorageV2 --access-tier Hot \
    --allow-blob-public-access false --min-tls-version TLS1_2 -o none
  echo "  storage account $TARGET_SA created"
fi

for c in landing archive external docs; do
  az storage container create -n "$c" --account-name "$TARGET_SA" --auth-mode login -o none
  echo "  container $c"
done

az storage queue create -n "$QUEUE" --account-name "$TARGET_SA" --auth-mode login -o none
echo "  queue $QUEUE"

blue "Event Grid -> storage queue (Snowpipe auto-ingest)"
# Registration is asynchronous. Creating the system topic before it finishes
# fails with "Couldn't verify the source resource", which reads like a
# permissions problem and is not one.
az provider register --namespace Microsoft.EventGrid -o none
for i in $(seq 1 30); do
  STATE=$(az provider show -n Microsoft.EventGrid --query registrationState -o tsv)
  [ "$STATE" = "Registered" ] && break
  echo "  Microsoft.EventGrid: $STATE (waiting, ${i}/30)"
  sleep 10
done
[ "$STATE" = "Registered" ] || { echo "  provider still $STATE after 5 min - re-run this script"; exit 1; }

SA_ID=$(az storage account show -n "$TARGET_SA" -g "$TARGET_RG" --query id -o tsv)

az eventgrid system-topic create -n st-qcpoc -g "$TARGET_RG" -l "$LOC" \
  --topic-type microsoft.storage.storageaccounts --source "$SA_ID" -o none || true

az eventgrid system-topic event-subscription create -n sub-snowpipe \
  -g "$TARGET_RG" --system-topic-name st-qcpoc \
  --endpoint-type storagequeue \
  --endpoint "$SA_ID/queueServices/default/queues/$QUEUE" \
  --included-event-types Microsoft.Storage.BlobCreated \
  --subject-begins-with /blobServices/default/containers/landing/ -o none
echo "  subscription sub-snowpipe -> $QUEUE, BlobCreated on landing/ only"

blue "Lifecycle: delete landing blobs after 14 days"
cat > /tmp/lifecycle.json <<'JSON'
{"rules":[{"enabled":true,"name":"expire-landing","type":"Lifecycle",
 "definition":{"actions":{"baseBlob":{"delete":{"daysAfterModificationGreaterThan":14}}},
 "filters":{"blobTypes":["blockBlob"],"prefixMatch":["landing/"]}}}]}
JSON
az storage account management-policy create --account-name "$TARGET_SA" \
  -g "$TARGET_RG" --policy @/tmp/lifecycle.json -o none
echo "  lifecycle rule applied"

blue "Done — values for the Snowflake integrations"
cat <<EOF
  STORAGE ACCOUNT : $TARGET_SA
  RESOURCE GROUP  : $TARGET_RG
  TENANT ID       : $(az account show --query tenantId -o tsv)

  Snowflake URLs use azure://, never https://
    azure://$TARGET_SA.blob.core.windows.net/landing/
    azure://$TARGET_SA.blob.core.windows.net/archive/
    azure://$TARGET_SA.blob.core.windows.net/external/
    azure://$TARGET_SA.blob.core.windows.net/docs/
  Queue for the notification integration:
    https://$TARGET_SA.queue.core.windows.net/$QUEUE

  Next: sql/p2_integrations.sql
EOF

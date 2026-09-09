#!/usr/bin/env bash
# =============================================================================
# scripts/p2_rbac.sh — grant the Snowflake service principals access.
# Run in Azure Cloud Shell, AFTER granting consent at both URLs.
#
# Snowflake issued TWO apps for this account:
#   n1fam5snowflakepacint  -> external volume + storage integration (blob)
#   14bjnhsnowflakepacint  -> notification integration (queue)
# Each needs its own consent before its service principal exists in the tenant.
#
# Scoped to individual containers, not the storage account, so the blob
# principal cannot read the queue and vice versa.
# =============================================================================
set -euo pipefail

SUB="d27ba827-26e0-419a-bc0b-2b1015e641bb"
RG="rg-qcpoc"
SA="snowflakeqcpoc25056"
APP_BLOB="n1fam5snowflakepacint"
APP_QUEUE="14bjnhsnowflakepacint"

SA_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$SA"

sp_id() {
  local id
  id=$(az ad sp list --filter "startswith(displayName,'$1')" --query "[0].id" -o tsv 2>/dev/null || true)
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    echo "NOT_FOUND"
  else
    echo "$id"
  fi
}

printf "\n== Locating service principals\n"
SP_BLOB=$(sp_id "$APP_BLOB")
SP_QUEUE=$(sp_id "$APP_QUEUE")
printf "  %-24s %s\n" "$APP_BLOB" "$SP_BLOB"
printf "  %-24s %s\n" "$APP_QUEUE" "$SP_QUEUE"

if [ "$SP_BLOB" = "NOT_FOUND" ] || [ "$SP_QUEUE" = "NOT_FOUND" ]; then
  cat <<EOF

  A principal is missing, which means its consent URL has not been accepted yet.
  Consent creates the service principal in your tenant; until then there is
  nothing to assign a role to.

    blob  https://login.microsoftonline.com/985bb39b-768f-4cc6-ba0f-0f544b826143/oauth2/authorize?client_id=505f7a2a-608f-4cb1-9958-0c82c2b97077&response_type=code
    queue https://login.microsoftonline.com/985bb39b-768f-4cc6-ba0f-0f544b826143/oauth2/authorize?client_id=2009ebee-ff58-4ae4-ad0a-e98d56345b3a&response_type=code

  Accept both, then re-run this script.
EOF
  exit 1
fi

assign() {   # assign <sp-object-id> <role> <scope>
  az role assignment create \
    --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
    --role "$2" --scope "$3" -o none 2>/dev/null \
    && echo "  granted: $2" \
    || echo "  already present (or failed): $2 on ${3##*/}"
}

printf "\n== Blob containers\n"
# archive is the only one Snowflake writes to: it stores Iceberg metadata and
# data files there. The other three are read-only by design.
assign "$SP_BLOB" "Storage Blob Data Contributor" "$SA_ID/blobServices/default/containers/archive"
for c in landing external docs; do
  assign "$SP_BLOB" "Storage Blob Data Reader" "$SA_ID/blobServices/default/containers/$c"
done

# Snowflake asks the storage account for a user delegation key, which it then
# uses to mint short-lived SAS tokens. That operation is only grantable at
# ACCOUNT scope -- a container-scoped role cannot cover it, which is why
# SYSTEM$VERIFY_EXTERNAL_VOLUME reports read/write/list/delete PASSED and
# azureGetUserDelegationKeyResult FAILED with 403 without it.
printf "\n== Account-scope delegation key\n"
assign "$SP_BLOB" "Storage Blob Delegator" "$SA_ID"

printf "\n== Queue\n"
assign "$SP_QUEUE" "Storage Queue Data Contributor" "$SA_ID/queueServices/default/queues/snowpipe-queue"

printf "\n== Assignments now in place\n"
# --all conflicts with --scope; listing at the storage account scope already
# includes the container and queue child scopes.
az role assignment list --scope "$SA_ID" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table

cat <<'EOF'

== Next
  RBAC propagation takes about 5 minutes. Do not debug a failure before then.

  When the wait is up, in Snowflake:
    SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('EXVOL_QC');

  Green means run STEP 4 of sql/p2_integrations.sql (file formats and stages).
EOF

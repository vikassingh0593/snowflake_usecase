#!/usr/bin/env bash
# teardown.sh — local + Azure side. STUB: fill in as resources are created (from Part 1).
# Everything this PoC creates must be destroyable by this one script.
set -euo pipefail

RG="rg-qcpoc"                      # the ONLY resource group this script may delete
KEEP_RG="databricksfreeedition"    # pre-existing, NOT ours — never touched

echo "== 1. Local docker stack =="
if [ -f docker-compose.yml ]; then
  docker compose down -v --remove-orphans
else
  echo "  (no docker-compose.yml yet)"
fi

echo "== 2. Azure =="
if ! command -v az >/dev/null 2>&1; then
  echo "  az CLI not found — skipping"
else
  if [ "$RG" = "$KEEP_RG" ]; then
    echo "  REFUSING: RG guard tripped. \$RG must never equal \$KEEP_RG." >&2
    exit 1
  fi
  if az group exists -n "$RG" | grep -qi true; then
    echo "  Deleting resource group $RG (Event Grid system topic, storage account,"
    echo "  containers landing/archive/external/docs, snowpipe-queue)"
    read -r -p "  Type the RG name to confirm: " confirm
    [ "$confirm" = "$RG" ] || { echo "  aborted"; exit 1; }
    az group delete -n "$RG" --yes --no-wait
  else
    echo "  Resource group $RG not present"
  fi

  # If Part 1 reused the pre-existing storage account instead of creating a fresh one,
  # delete only OUR containers/queue there — never the account, never its RG.
  # SA_EXISTING=snowflakefreeedition
  # for c in landing archive external docs; do
  #   az storage container delete -n "$c" --account-name "$SA_EXISTING" --auth-mode login
  # done
  # az storage queue delete -n snowpipe-queue --account-name "$SA_EXISTING" --auth-mode login
fi

echo "== 3. Local secrets and build artefacts =="
rm -f rsa_key.p8 rsa_key.pub rsa_key*.pem 2>/dev/null || true
rm -rf target/ logs/ dbt_packages/.cache 2>/dev/null || true
echo "  NOTE: .env is left in place — delete manually if you are done."

echo "== 4. Snowflake =="
echo "  Run teardown.sql as ACCOUNTADMIN, then re-run its verification block."
echo "  e.g. snow sql -c qcpoc -f teardown.sql"

echo "== 5. Verify =="
echo "  az resource list -g $RG        -> should error 'not found'"
echo "  docker ps                      -> no qc-* containers"
echo "  SHOW WAREHOUSES / TASKS / PIPES in Snowflake -> empty"

#!/usr/bin/env bash
# =============================================================================
# scripts/p7_source_reset.sh — rebuild the source stack from nothing.
#
# DESTRUCTIVE, deliberately. `docker compose down -v` removes both named volumes:
#
#   pgdata   Postgres tables            -> re-created by postgres/init/*
#   rpdata   every broker topic AND     -> Connect re-creates its own; the CDC
#            Connect's internal topics      topics come back from the snapshot
#
# That is normally the mistake this project warns about -- it destroyed the
# hand-produced qc.order_status topic once before with no way to re-snapshot it.
# It is the right move now for two reasons:
#
#   1. The broker is ALREADY empty. There is nothing left to preserve.
#   2. Everything here is reproducible. generate.py is seeded (SEED=20260909),
#      so the CSVs are byte-identical, 01_schema.sql and 02_load.sh run
#      automatically on a fresh pgdata, and Debezium snapshots from there.
#
# WHAT IS NOT RECOVERED: qc.order_status, which was produced by hand rather than
# captured. It does not matter -- those 79,663 events are already in Snowflake
# three times over from Part 3, and Part 7 needs the seven CDC tables, not them.
#
# WHAT IS NOT TOUCHED: Snowflake and Azure. Nothing in either is read or written
# by this script. RAW keeps all 376,808 rows.
#
#   bash scripts/p7_source_reset.sh          dry run. Says what it would destroy
#   RESET=1 bash scripts/p7_source_reset.sh  actually does it
#
# COST: zero. Entirely local.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

# Topic depth, summed across partitions. Parsed by HEADER NAME, not by field
# position: rpk's column layout varies with version and whether the ERROR
# column is populated, and `awk '{print $NF}'` silently reported 0 for topics
# that were full -- a zero that looked exactly like an empty topic.
depth() {
  docker exec qc-redpanda rpk topic describe -p "$1" 2>/dev/null | python3 -c '
import sys
col = None
total = 0
seen = False
for line in sys.stdin:
    f = line.split()
    if not f:
        continue
    if "LOG-END-OFFSET" in f:
        col = f.index("LOG-END-OFFSET")
        continue
    if col is not None and f[0].isdigit() and len(f) > col:
        try:
            total += int(f[col]); seen = True
        except ValueError:
            pass
print(total if seen else -1)
'
}

RESET="${RESET:-0}"
CONNECT="localhost:8083"

if [ "$RESET" != "1" ]; then
  cat <<'EOF'
DRY RUN. This would:

  1. Regenerate source/out/*.csv if missing        (seeded, deterministic)
  2. docker compose down -v                        DESTROYS pgdata and rpdata
  3. docker compose up -d                          re-inits Postgres from CSVs
  4. Register Debezium                             snapshots 171,403 rows
  5. Verify seven topics exist at the right depths

Destroyed and rebuilt:  Postgres tables, every broker topic, Connect's own
                        config/status/offset topics, and therefore every
                        registered connector.
Destroyed, not rebuilt: qc.order_status (hand-produced; already in Snowflake
                        three times over, so it is not needed again).
Untouched:              Snowflake, Azure, and everything in RAW.

To proceed:  RESET=1 bash scripts/p7_source_reset.sh
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
echo "== 1. source CSVs"
if [ ! -f source/out/dark_stores.csv ]; then
  echo "   not present, generating"
  python3 source/generate.py
else
  echo "   present: $(ls source/out/*.csv | wc -l | tr -d ' ') files"
fi
# 02_load.sh skips silently when /seed is empty, which would leave an empty
# database that looks healthy -- exactly the failure this project keeps hitting.
[ -f source/out/orders.csv ] || { echo "   orders.csv still missing, stopping"; exit 1; }

echo
echo "== 2. tearing down, volumes included"
(cd source && docker compose down -v)

echo
echo "== 3. bringing the stack up"
(cd source && docker compose up -d)

echo
echo "== 4. waiting for Postgres to finish initialising"
# The init scripts run on first start and take a while to \copy 171k rows.
# Polling the row count rather than the health check: healthy means accepting
# connections, not finished loading.
for i in $(seq 1 60); do
  n=$(docker exec qc-postgres psql -U postgres -d qcommerce -tA \
        -c "SELECT COUNT(*) FROM qc.orders" 2>/dev/null || echo 0)
  [ "$n" -ge 20000 ] 2>/dev/null && { echo "   orders loaded: $n"; break; }
  printf "   %ds — orders so far: %s\r" $((i*5)) "${n:-0}"
  sleep 5
done
echo

docker exec qc-postgres psql -U postgres -d qcommerce -c "
  SELECT 'dark_stores' AS t, COUNT(*) FROM qc.dark_stores
  UNION ALL SELECT 'customers',   COUNT(*) FROM qc.customers
  UNION ALL SELECT 'products',    COUNT(*) FROM qc.products
  UNION ALL SELECT 'riders',      COUNT(*) FROM qc.riders
  UNION ALL SELECT 'inventory',   COUNT(*) FROM qc.inventory
  UNION ALL SELECT 'orders',      COUNT(*) FROM qc.orders
  UNION ALL SELECT 'order_items', COUNT(*) FROM qc.order_items
  ORDER BY 2 DESC;"

echo "== 5. waiting for Kafka Connect"
# Connect takes 30-60s to load its plugins and form its internal topics. A POST
# before that returns a connection refused that reads like a config error.
for i in $(seq 1 40); do
  curl -sf "$CONNECT/connectors" >/dev/null 2>&1 && { echo "   ready after $((i*3))s"; break; }
  printf "   %ds\r" $((i*3)); sleep 3
done
curl -sf "$CONNECT/connectors" >/dev/null 2>&1 || { echo "   Connect never came up; docker logs qc-connect"; exit 1; }

echo
echo "== 6. registering Debezium"
curl -s -X POST -H "Content-Type: application/json" \
     --data @source/connectors/debezium-postgres.json \
     "$CONNECT/connectors" | python3 -m json.tool

echo
echo "== 7. waiting for the snapshot"
# order_items is the second largest table and the last to finish, so its depth
# is the signal that the snapshot is done rather than merely started.
snapshot_done=0
for i in $(seq 1 60); do
  hw=$(depth qc.order_items)
  [ "$hw" -ge 54635 ] 2>/dev/null && { echo "   snapshot complete: $hw records"; snapshot_done=1; break; }
  printf "   %ds — order_items: %s / 54635\r" $((i*5)) "$([ "$hw" = "-1" ] && echo "topic missing" || echo "$hw")"
  sleep 5
done
echo

# Fail loudly. Falling through to the next step on a snapshot that never
# happened is the same silent-success failure this project keeps hitting.
if [ "$snapshot_done" != "1" ]; then
  echo "SNAPSHOT DID NOT COMPLETE after 300s. Nothing further will work."
  echo "  curl -s localhost:8083/connectors/qc-postgres-cdc/status | python3 -m json.tool"
  echo "  docker logs qc-connect 2>&1 | grep -iE 'snapshot|ERROR' | tail -30"
  exit 1
fi

bash scripts/p7_cdc_sink.sh check

cat <<'EOF'

== Next
   bash scripts/p7_cdc_sink.sh create      land the seven topics in RAW
   bash scripts/p7_cdc_sink.sh status      lag, not the RUNNING state
   snow sql -c qcpoc -f sql/p7_cdc_verify.sql
EOF

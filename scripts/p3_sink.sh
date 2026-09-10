#!/usr/bin/env bash
# =============================================================================
# scripts/p3_sink.sh — register the Snowflake sink connectors.
#
#   bash scripts/p3_sink.sh v4     mechanism 1: Snowpipe Streaming, connector v4
#   bash scripts/p3_sink.sh v3     mechanism 3: Snowpipe file mode, connector v3
#   bash scripts/p3_sink.sh status
#   bash scripts/p3_sink.sh delete v4|v3
#
# The private key is read from rsa_kafka.p8 at submit time and inlined into the
# POST body. It is never written to a file in this repo. Connect stores it in
# its own config topic, which is the unavoidable part -- Snowflake's own advice
# for production is a ConfigProvider backed by a secrets manager, which is more
# machinery than a throwaway PoC earns.
#
# Both connectors read the SAME topic into DIFFERENT tables. Connect derives the
# consumer group from the connector name, so they consume independently and each
# sees all 79,663 events -- which is what makes the comparison fair.
#
# SCHEMATIZATION IS FORCED OFF on both. v4 flipped the default to true, where v3
# defaulted false. Left alone, v4 would infer typed columns from the JSON and v3
# would not, so the two tables would have different shapes and the comparison
# would be measuring the wrong thing. Off also matches the design: RAW holds the
# payload as VARIANT and typing happens in CORE, so a producer adding a field
# never breaks ingestion.
# =============================================================================
set -euo pipefail

ACCOUNT="AWTTGVH-OLB61128.snowflakecomputing.com:443"
USER="SVC_KAFKA"
ROLE="QC_LOADER"
DB="QCOMMERCE"
SCHEMA="RAW"
TOPIC="qc.order_status"
KEYFILE="${KEYFILE:-rsa_kafka.p8}"
CONNECT="localhost:8083"

cmd="${1:-status}"

if [ "$cmd" = "status" ]; then
  curl -s "$CONNECT/connectors" | python3 -m json.tool
  for c in $(curl -s "$CONNECT/connectors" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))'); do
    echo "-- $c"
    curl -s "$CONNECT/connectors/$c/status" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("   connector:", d["connector"]["state"])
for t in d.get("tasks", []):
    print("   task", t["id"], t["state"], t.get("trace","").split("\n")[0][:120])
'
  done
  exit 0
fi

if [ "$cmd" = "delete" ]; then
  case "${2:-}" in
    v4) NAME=qc-snowflake-v4-streaming ;;
    v3) NAME=qc-snowflake-v3-filemode ;;
    *) echo "usage: $0 delete v4|v3"; exit 1 ;;
  esac
  curl -s -X DELETE "$CONNECT/connectors/$NAME" && echo "deleted $NAME"
  exit 0
fi

[ -f "$KEYFILE" ] || { echo "no $KEYFILE — generate it first (see sql/p3_prep.sql section 1)"; exit 1; }
KEY=$(grep -v '^-----' "$KEYFILE" | tr -d '\n')

case "$cmd" in
  v4)
    NAME="qc-snowflake-v4-streaming"
    read -r -d '' EXTRA <<JSON || true
    "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
    "tasks.max": "3",
    "snowflake.topic2table.map": "$TOPIC:ORDER_STATUS_KAFKA_V4",
    "snowflake.streaming.classic.offset.migration": "skip",
    "snowflake.enable.schematization": "false",
JSON
    ;;
  v3)
    NAME="qc-snowflake-v3-filemode"
    # buffer.flush.time is what makes file mode file mode: rows are batched into
    # a file and only then handed to Snowpipe. 60s is deliberately visible next
    # to streaming's 5-10s, since measuring that gap is the point of mechanism 3.
    read -r -d '' EXTRA <<JSON || true
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "snowflake.ingestion.method": "SNOWPIPE",
    "tasks.max": "1",
    "snowflake.enable.schematization": "false",
    "snowflake.topic2table.map": "$TOPIC:ORDER_STATUS_KAFKA_V3FILE",
    "buffer.count.records": "10000",
    "buffer.flush.time": "60",
    "buffer.size.bytes": "5000000",
JSON
    ;;
  *) echo "usage: $0 v4|v3|status|delete"; exit 1 ;;
esac

BODY=$(cat <<JSON
{
  "name": "$NAME",
  "config": {
$EXTRA
    "topics": "$TOPIC",
    "snowflake.url.name": "$ACCOUNT",
    "snowflake.user.name": "$USER",
    "snowflake.role.name": "$ROLE",
    "snowflake.database.name": "$DB",
    "snowflake.schema.name": "$SCHEMA",
    "snowflake.private.key": "$KEY",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "errors.log.enable": "true",
    "errors.tolerance": "all"
  }
}
JSON
)

echo "== registering $NAME"
RESP=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
        "$CONNECT/connectors" -d "$BODY")
CODE=$(echo "$RESP" | tail -1)
echo "$RESP" | sed '$d' | python3 -m json.tool 2>/dev/null | grep -v private.key || echo "$RESP" | sed '$d'
echo "   HTTP $CODE"

if [ "$CODE" = "201" ]; then
  sleep 15
  echo "== status"
  curl -s "$CONNECT/connectors/$NAME/status" | python3 -m json.tool
fi

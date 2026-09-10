#!/usr/bin/env bash
# =============================================================================
# scripts/p3_connector.sh — install the Snowflake Kafka Connector v4 into the
# running Kafka Connect container. Run on your Mac, from the repo root.
#
# v4.1.0 is the current release: a ground-up rewrite on the Snowpipe Streaming
# High-Performance Architecture (v4.0 GA 2026-04-20). Up to 10 GB/s per table,
# 5-10s end to end, exactly-once and ordered.
#
# The jar is ~170 MB. It lands in source/connectors/plugins/, which is already
# mounted writable into the container and gitignored below.
# =============================================================================
set -euo pipefail

VER="${VER:-4.1.0}"
DIR="source/connectors/plugins"
JAR="$DIR/snowflake-kafka-connector-$VER.jar"
URL="https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/$VER/snowflake-kafka-connector-$VER.jar"

mkdir -p "$DIR"

if [ -f "$JAR" ]; then
  echo "== already present: $JAR ($(du -h "$JAR" | cut -f1))"
else
  echo "== downloading v$VER (~170 MB)"
  curl -fL --progress-bar -o "$JAR.part" "$URL"
  mv "$JAR.part" "$JAR"
  echo "   $(du -h "$JAR" | cut -f1)"
fi

echo "== restarting Kafka Connect to pick up the plugin"
docker compose -f source/docker-compose.yml restart connect

echo "== waiting for the REST API"
for i in $(seq 1 30); do
  if curl -fs localhost:8083/ >/dev/null 2>&1; then break; fi
  printf '.'; sleep 5
done
echo

# Do not guess the class name. v4 is a rewrite and may not use the v3 class.
# Connect reports exactly what it loaded, which is the authoritative answer.
echo "== sink connector classes Connect can see"
curl -s localhost:8083/connector-plugins \
  | python3 -c '
import json,sys
for p in json.load(sys.stdin):
    if p.get("type") == "sink" or "snowflake" in p.get("class","").lower():
        print(f"  {p[\"class\"]}   type={p.get(\"type\")}  version={p.get(\"version\")}")
'
cat <<'EOF'

== Next
  Paste the Snowflake class name above back, and the sink config gets written
  against the real class rather than a guessed one.
EOF

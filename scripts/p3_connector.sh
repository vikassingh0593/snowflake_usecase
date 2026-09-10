#!/usr/bin/env bash
# =============================================================================
# scripts/p3_connector.sh — install both Snowflake Kafka connectors.
# Run on your Mac, from the repo root.
#
# TWO connectors, because v4 dropped file mode:
#   v4.1.0  SnowflakeStreamingSinkConnector  — mechanism 1, Snowpipe Streaming
#   v3.5.4  SnowflakeSinkConnector           — mechanism 3, Snowpipe file mode
#
# v4 is a ground-up rewrite on the Snowpipe Streaming High-Performance
# Architecture and supports streaming only. Comparing streaming against file
# mode therefore needs both majors installed side by side, which is itself the
# clearest statement of what changed between them.
#
# They go in separate directories under plugin.path: Kafka Connect isolates a
# classloader per plugin directory, and two versions of the same packages in
# one directory would collide.
# =============================================================================
set -euo pipefail

V4="${V4:-4.1.0}"
V3="${V3:-3.5.4}"
BASE="https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector"

fetch() {   # fetch <version> <dir>
  local ver="$1" dir="source/connectors/plugins/$2"
  local jar="$dir/snowflake-kafka-connector-$ver.jar"
  mkdir -p "$dir"
  if [ -f "$jar" ]; then
    echo "  v$ver already present ($(du -h "$jar" | cut -f1))"
  else
    echo "  downloading v$ver"
    curl -fL --progress-bar -o "$jar.part" "$BASE/$ver/snowflake-kafka-connector-$ver.jar"
    mv "$jar.part" "$jar"
    echo "  v$ver $(du -h "$jar" | cut -f1)"
  fi
}

echo "== jars"
fetch "$V4" v4
fetch "$V3" v3

echo "== restarting Kafka Connect"
docker compose -f source/docker-compose.yml up -d connect   # picks up the new mounts

echo "== waiting for the REST API"
for i in $(seq 1 40); do
  curl -fs localhost:8083/ >/dev/null 2>&1 && break
  printf '.'; sleep 5
done
echo

echo "== Snowflake classes Connect loaded"
curl -s localhost:8083/connector-plugins | python3 -c '
import json, sys
found = 0
for p in json.load(sys.stdin):
    cls = p.get("class", "")
    if "snowflake" in cls.lower():
        found += 1
        print("  " + cls + "  version=" + str(p.get("version")))
if not found:
    print("  none yet - Connect may still be scanning the jars, retry in 30s")
'

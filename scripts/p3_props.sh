#!/usr/bin/env bash
# Dump the config properties a connector actually accepts, from the running
# Connect worker. v4 is a rewrite; property names cannot be assumed to match v3.
# Usage: bash scripts/p3_props.sh [class-name]
set -euo pipefail
CLS="${1:-com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector}"
SHORT="${CLS##*.}"

curl -s -X PUT -H 'Content-Type: application/json' \
  "localhost:8083/connector-plugins/$SHORT/config/validate" \
  -d "{\"connector.class\":\"$CLS\",\"name\":\"probe\",\"topics\":\"x\",\"tasks.max\":\"1\"}" \
| python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = []
for c in d.get("configs", []):
    k = c.get("definition", {})
    if k.get("name"):
        rows.append((k["name"], k.get("required"), k.get("default_value")))
for name, req, dflt in sorted(rows):
    mark = "*" if req else " "
    print(" %s %-52s default=%s" % (mark, name, dflt))
print("\n  %d properties  (* = required)" % len(rows))
'

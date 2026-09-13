#!/usr/bin/env bash
#
# Run a SQL file and print only the result tables.
#
# snow sql echoes every statement before its result. On files that carry
# their reasoning in comments -- which is most of this repo -- the echo is
# the bulk of the output, and a long run pushes the interesting tables off
# the top of the scrollback. This keeps the boxes and the errors and drops
# the rest.
#
#   scripts/sql.sh sql/p9_report.sql          tables and errors only
#   scripts/sql.sh sql/p9_report.sql --full   everything, as snow prints it
#
set -euo pipefail

FILE="${1:?usage: scripts/sql.sh <file.sql> [--full]}"
CONN="${SNOW_CONN:-qcpoc}"

if [ ! -f "$FILE" ]; then
    echo "no such file: $FILE" >&2
    exit 1
fi

if [ "${2:-}" = "--full" ]; then
    exec snow sql -c "$CONN" -f "$FILE"
fi

# Box-drawing for results is | and +; snow draws errors with the heavier
# set, so those are kept too -- a filter that hides failures would be worse
# than no filter at all.
set +e
snow sql -c "$CONN" -f "$FILE" 2>&1 | grep -E '^[|+]|^[[:space:]]*[│╭╰─]|[Ee]rror'
status="${PIPESTATUS[0]}"
set -e

exit "$status"

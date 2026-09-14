#!/usr/bin/env bash
#
# Run a SQL file and print only the result tables.
#
# snow sql echoes every statement before its result. On files that carry their
# reasoning in comments -- which is most of this repo -- the echo is the bulk of
# the output, and a long run pushes the interesting tables off the top of the
# scrollback. This keeps the boxes and the errors and drops the rest.
#
#   scripts/sql.sh sql/p9_report.sql          tables and errors only
#   scripts/sql.sh sql/p9_report.sql --full   everything, as snow prints it
#
# The filtering itself is snow_file in scripts/lib.sh, where rebuild.sh and the
# rest of the scripts reach it too. This file stays because it is the entry
# point the documentation names and the one fingers remember.
#
. "$(dirname "$0")/lib.sh"

FILE="${1:?usage: scripts/sql.sh <file.sql> [--full]}"
if [ "${2:-}" = "--full" ]; then FULL=1; fi

snow_file "$FILE"

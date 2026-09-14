# =============================================================================
# scripts/lib.sh — the things every script in this repo was repeating.
#
# Sourced, never executed:
#
#   . "$(dirname "$0")/lib.sh"
#
# Seventeen scripts each re-declared strict mode, the connection name, an ad-hoc
# way of printing a heading, and their own spelling of the dry-run guard. None
# of that is interesting and all of it drifts. What it gives back is a single
# place to change the connection, and a confirm gate that behaves the same way
# everywhere something destructive is about to happen.
# =============================================================================

set -euo pipefail

# Every script runs from the repo root regardless of where it was invoked.
cd "$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")/.." && pwd)"

CONN="${SNOW_CONN:-qcpoc}"
DB="${SNOW_DB:-QCOMMERCE}"

# Colour only when attached to a terminal, so piping into a file or into CI
# produces plain text.
if [ -t 1 ]; then
    _B=$'\033[1m'; _D=$'\033[2m'; _R=$'\033[31m'; _Y=$'\033[33m'; _G=$'\033[32m'; _0=$'\033[0m'
else
    _B=""; _D=""; _R=""; _Y=""; _G=""; _0=""
fi

step() { printf '\n%s==> %s%s\n' "$_B" "$*" "$_0"; }
say()  { printf '    %s\n' "$*"; }
note() { printf '    %s%s%s\n' "$_D" "$*" "$_0"; }
ok()   { printf '    %s✓%s %s\n' "$_G" "$_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$_Y" "$_0" "$*" >&2; }
die()  { printf '    %s✗%s %s\n' "$_R" "$_0" "$*" >&2; exit 1; }

# --- preconditions -----------------------------------------------------------
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }
need_file() { [ -f "$1" ] || die "${2:-missing file: $1}"; }

# --- Snowflake ---------------------------------------------------------------
# snow_file runs a .sql file and keeps only result boxes and errors, which is
# what scripts/sql.sh did and what every caller actually wanted. --full passes
# the raw output through.
snow_file() {
    local file="$1"; shift
    need_file "$file"
    if [ "${FULL:-0}" = "1" ]; then
        snow sql -c "$CONN" -f "$file" "$@"
    else
        set +e
        snow sql -c "$CONN" -f "$file" "$@" 2>&1 \
            | grep -E '^[|+]|^[[:space:]]*[│╭╰─]|[Ee]rror'
        local rc="${PIPESTATUS[0]}"
        set -e
        return "$rc"
    fi
}

snow_q() { snow sql -c "$CONN" -q "$*"; }

# One scalar back, unadorned. For tests like "does this object exist".
snow_scalar() {
    snow sql -c "$CONN" -q "$*" --format json 2>/dev/null \
        | python3 -c 'import json,sys
try:
    rows = json.load(sys.stdin)
    print(list(rows[0].values())[0] if rows else "")
except Exception:
    print("")'
}

# SHOW returns forty-odd columns and the box it draws in an 80-column terminal is
# unreadable -- SHOW WAREHOUSES came back as blank cells. Everything worth
# knowing from a SHOW here is the name column, so re-read the result set and
# project it. RESULT_SCAN needs the SHOW in the same session, hence one -q.
#
#   snow_names "SHOW WAREHOUSES LIKE 'WH_%'" ["<extra WHERE predicate>"]
snow_names() {
    local show="$1" where="${2:-}"
    local q="$show; SELECT \"name\" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))"
    [ -n "$where" ] && q="$q WHERE $where"
    snow sql -c "$CONN" -q "$q" --format json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit
# A multi-statement run returns one result set per statement; a single
# statement returns the rows directly. Accept either rather than guess.
if d and isinstance(d[0], list):
    d = d[-1]
names = [str(r.get("name", r.get("NAME", ""))) for r in d if isinstance(r, dict)]
names = [n for n in names if n]
print(", ".join(names) if names else "-")'
}

# --- the destructive gate ----------------------------------------------------
# One spelling, everywhere. FORCE=1 skips it for CI; nothing else does.
confirm() {
    local what="$1"
    if [ "${FORCE:-0}" = "1" ]; then
        warn "FORCE=1 — not asking about: $what"
        return 0
    fi
    printf '\n%s%s%s\n' "$_Y" "$what" "$_0"
    printf 'Type %syes%s to continue: ' "$_B" "$_0"
    local answer; read -r answer
    [ "$answer" = "yes" ] || die "cancelled"
}

# --- containers ---------------------------------------------------------------
# This Mac's Python is an Intel build under Rosetta, so several dependencies
# have no installable wheel: the Snowpipe Streaming SDK ships no macOS x86_64
# wheel at all, and the connector's pandas extra pulls pyarrow and cryptography,
# whose recent versions are arm64-only on macOS. An arm64 Linux container has
# manylinux aarch64 wheels for every one of them, and an arm64 Mac runs those
# natively. The repo is mounted read-write so a script inside sees exactly the
# files it would see outside.
#
#   in_container "pkg [pkg...]" script.py [args...]
in_container() {
    local packages="$1"; shift
    local script="$1"; shift
    need_cmd docker
    need_file "$script"
    docker run --rm -it \
        -e SS_LOG_LEVEL="${SS_LOG_LEVEL:-warn}" \
        -v "$PWD":/work -w /work \
        python:3.12-slim \
        bash -c "pip install -q --disable-pip-version-check $packages && python $script $*"
}

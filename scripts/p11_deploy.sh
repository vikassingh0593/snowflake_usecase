#!/usr/bin/env bash
#
# Deploy the Streamlit app.
#
# Two steps: PUT app.py onto the internal stage the probe created, then point a
# STREAMLIT object at it. Re-running is how you ship a change -- CREATE OR
# REPLACE STREAMLIT keeps the same url_id, so a bookmarked link survives.
#
# No environment.yml. CREATE STREAMLIT supplies python 3.11,
# snowflake-snowpark-python and streamlit 1.52 by default, which is everything
# app.py imports. A declared dependency that buys nothing is a dependency that
# can break a deploy.
#
# This script briefly carried an ALTER STREAMLIT ... SET DEFAULT_PACKAGES,
# which Snowflake rejected: invalid property 'DEFAULT_PACKAGES' for 'STREAMLIT'.
# That name appears in DESCRIBE STREAMLIT output and I took it for a settable
# property. It is read-only, it reports what the platform supplies, and the
# statement bought nothing even if it had worked. Extra packages go in an
# environment.yml beside app.py, which this app does not need.
#
#   scripts/p11_deploy.sh           show what would run
#   DEPLOY=1 scripts/p11_deploy.sh  run it, then print the app URL
#
set -euo pipefail

DEPLOY="${DEPLOY:-0}"
CONN="${SNOW_CONN:-qcpoc}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/streamlit/app.py"

[ -f "$APP" ] || { echo "missing $APP" >&2; exit 1; }

echo "== $APP"
echo "   $(wc -l < "$APP") lines, $(wc -c < "$APP") bytes"

# Compile locally first. A syntax error found here costs nothing; the same
# error found after deploying is a stack trace in a browser tab with no
# terminal to read it in.
if ! python3 -m py_compile "$APP" 2>/dev/null; then
    echo "ABORT: app.py does not compile" >&2
    python3 -m py_compile "$APP"
    exit 1
fi
echo "   compiles"

PUT_STMT="PUT file://$APP @QCOMMERCE.APP.STG_APP/console AUTO_COMPRESS=FALSE OVERWRITE=TRUE"

read -r -d '' STATEMENTS <<'SQL' || true
CREATE OR REPLACE STREAMLIT QCOMMERCE.APP.QC_CONSOLE
  ROOT_LOCATION = '@QCOMMERCE.APP.STG_APP/console'
  MAIN_FILE = '/app.py'
  QUERY_WAREHOUSE = WH_APP_XS
  TITLE = 'Quick-commerce operations console'
  COMMENT = 'Part 11. Reads SERVE only, writes SERVE.ACTION_LOG';

SHOW STREAMLITS IN SCHEMA QCOMMERCE.APP;
SQL

if [ "$DEPLOY" != "1" ]; then
    echo
    echo "== DRY RUN. Nothing sent to Snowflake."
    echo
    echo "$PUT_STMT;"
    echo
    echo "$STATEMENTS"
    echo "== WH_APP_XS runs only while the app is open. Idle costs nothing."
    echo "== Rerun with: DEPLOY=1 scripts/p11_deploy.sh"
    exit 0
fi

echo "== uploading"
snow sql -c "$CONN" -q "USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p11:deploy';
$PUT_STMT;"

echo "== creating the app"
snow sql -c "$CONN" -q "USE ROLE ACCOUNTADMIN;
USE DATABASE QCOMMERCE;
ALTER SESSION SET QUERY_TAG = 'p11:deploy';
$STATEMENTS"

echo
echo "== open it from Snowsight: Projects -> Streamlit -> Quick-commerce"
echo "   operations console. The url_id in the SHOW output above is the"
echo "   stable part of the link and survives a redeploy."

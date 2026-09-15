#!/usr/bin/env bash
#
# Deploy the Streamlit app.
#
# Two steps: PUT app.py onto the internal stage the probe created, then point a
# STREAMLIT object at it.
#
# The PUT is what ships a code change. The app resolves its source from the
# stage when it is opened, so a new app.py is live on the next page load with
# no DDL at all. The CREATE is only needed the first time, or when a property
# of the object itself changes -- the warehouse, the title, the main file.
#
# Hence IF NOT EXISTS rather than OR REPLACE. An earlier version of this script
# used OR REPLACE and claimed it preserved url_id; that was never checked and
# is very likely wrong, since replacing an object creates a new one. A changing
# url_id breaks every bookmark to the app, which is a poor trade for a
# statement that was not needed. RECREATE=1 forces it when a property really
# has to change.
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
#   scripts/p11_deploy.sh                        show what would run
#   DEPLOY=1 scripts/p11_deploy.sh               upload, create if absent
#   DEPLOY=1 RECREATE=1 scripts/p11_deploy.sh    replace the object too
#
set -euo pipefail

DEPLOY="${DEPLOY:-0}"
RECREATE="${RECREATE:-0}"
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

# The stage this PUTs into was created by sql/p11_streamlit_probe.sql, which is
# a probe and is excluded from the build path -- so on a rebuild it does not
# exist and the PUT fails with "Stage 'QCOMMERCE.APP.STG_APP' does not exist or
# not authorized". A deploy that depends on a diagnostic having been run by hand
# is not a deploy. It creates its own stage, the way scripts/p10_truth.sh does.
# DIRECTORY = (ENABLE = TRUE) and the comment are copied from the probe, so
# running either one first leaves the same object.
STAGE_STMT="CREATE STAGE IF NOT EXISTS QCOMMERCE.APP.STG_APP
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Streamlit source. app.py and environment.yml live here'"

PUT_STMT="PUT file://$APP @QCOMMERCE.APP.STG_APP/console AUTO_COMPRESS=FALSE OVERWRITE=TRUE"

CREATE_VERB="CREATE STREAMLIT IF NOT EXISTS"
[ "$RECREATE" = "1" ] && CREATE_VERB="CREATE OR REPLACE STREAMLIT"

read -r -d '' STATEMENTS <<SQL || true
$CREATE_VERB QCOMMERCE.APP.QC_CONSOLE
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
    echo "$STAGE_STMT;"
    echo
    echo "$PUT_STMT;"
    echo
    echo "$STATEMENTS"
    echo "== WH_APP_XS runs only while the app is open. Idle costs nothing."
    if [ "$RECREATE" = "1" ]; then
        echo "== RECREATE=1: the object is replaced and its url_id changes."
    else
        echo "== The PUT alone ships a code change. CREATE only fires if the"
        echo "== app does not exist yet, so url_id and bookmarks survive."
    fi
    echo "== Rerun with: DEPLOY=1 scripts/p11_deploy.sh"
    exit 0
fi

echo "== uploading"
snow sql -c "$CONN" -q "USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p11:deploy';
$STAGE_STMT;
$PUT_STMT;"

echo "== creating the app"
snow sql -c "$CONN" -q "USE ROLE ACCOUNTADMIN;
USE DATABASE QCOMMERCE;
ALTER SESSION SET QUERY_TAG = 'p11:deploy';
$STATEMENTS"

echo
echo "== open it from Snowsight: Projects -> Streamlit -> Quick-commerce"
echo "   operations console. The url_id above is stable as long as the object"
echo "   is not replaced -- a plain code change only needs the PUT."

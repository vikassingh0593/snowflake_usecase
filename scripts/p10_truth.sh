#!/usr/bin/env bash
#
# Load the complaint answer key for evaluation.
#
# The 300 complaint PDFs went to Azure blob in Part 6 and _truth.csv was
# deliberately held back, so the classifier trains on 60 hand labels and has to
# earn the other 240. Scoring it still needs the key. This puts it somewhere the
# training path cannot reach: a Snowflake INTERNAL stage, never the blob
# container the documents live in, and a table in OPS rather than RAW or CORE.
#
# The separation is greppable, not promised:
#   grep -v '^--' sql/p10_classify.sql | grep -c COMPLAINT_TRUTH   -> must be 0
#
# (comment lines excluded: the classifier's own header explains the separation
#  and would otherwise count against it)
#
# The key is regenerated rather than recovered. gen_complaints.py is seeded, so
# a rerun reproduces the identical corpus -- and the guard below proves it by
# checking the regenerated dbt seeds against the committed ones. If they differ,
# the generator has changed and the key would no longer describe the PDFs that
# are actually in the account, so the script stops.
#
#   scripts/p10_truth.sh           regenerate, verify, print the statements
#   LOAD=1 scripts/p10_truth.sh    and execute them
#
set -euo pipefail

LOAD="${LOAD:-0}"
CONN="${SNOW_CONN:-qcpoc}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRUTH="$ROOT/source/out/complaints/_truth.csv"

echo "== regenerating the complaint corpus (deterministic, SEED is fixed)"
python3 "$ROOT/source/gen_complaints.py" >/dev/null

if [ ! -f "$TRUTH" ]; then
    echo "ABORT: $TRUTH was not produced" >&2
    exit 1
fi

echo "== verifying the regenerated corpus matches the committed one"
if ! git -C "$ROOT" diff --quiet -- dbt/seeds/complaint_label.csv \
                                   dbt/seeds/complaint_reason_code.csv; then
    echo "ABORT: regenerating changed the committed seeds." >&2
    echo "The generator no longer reproduces the corpus that is in the account," >&2
    echo "so this answer key would be scoring the wrong documents." >&2
    git -C "$ROOT" --no-pager diff --stat -- dbt/seeds/ >&2
    exit 1
fi
echo "   seeds identical -- the key describes the PDFs already uploaded"
echo "   $(( $(wc -l < "$TRUTH") - 1 )) rows in $TRUTH"

read -r -d '' STATEMENTS <<'SQL' || true
CREATE STAGE IF NOT EXISTS QCOMMERCE.OPS.STG_EVAL
  COMMENT = 'evaluation answer keys. Never read by a training or feature path';

-- OR REPLACE, not IF NOT EXISTS plus TRUNCATE: the key gained a
-- TEMPLATE_INDEX column and IF NOT EXISTS would silently keep the old shape.
-- The table is rebuilt from the file on every load anyway.
CREATE OR REPLACE TABLE QCOMMERCE.OPS.COMPLAINT_TRUTH (
  TICKET_ID       STRING,
  SOURCE_ORDER_ID NUMBER,
  STORE_ID        NUMBER,
  RAISED_AT       TIMESTAMP_NTZ,
  REASON_CODE     STRING,
  TEMPLATE_INDEX  NUMBER,
  LOADED_AT       TIMESTAMP_NTZ DEFAULT SYSDATE()
);

COPY INTO QCOMMERCE.OPS.COMPLAINT_TRUTH
     (TICKET_ID, SOURCE_ORDER_ID, STORE_ID, RAISED_AT, REASON_CODE, TEMPLATE_INDEX)
FROM (
  SELECT t.$1,
         t.$2::NUMBER,
         t.$3::NUMBER,
         TRY_TO_TIMESTAMP_NTZ(REPLACE(t.$4, 'Z', '')),
         t.$5,
         t.$6::NUMBER
  FROM @QCOMMERCE.OPS.STG_EVAL/_truth.csv t
)
FILE_FORMAT = (FORMAT_NAME = QCOMMERCE.LAND.FF_CSV)
ON_ERROR = ABORT_STATEMENT;

SELECT COUNT(*) AS rows_loaded,
       COUNT(DISTINCT TICKET_ID) AS tickets,
       COUNT(DISTINCT REASON_CODE) AS classes,
       COUNT(DISTINCT REASON_CODE || ':' || TEMPLATE_INDEX) AS code_template_pairs,
       MIN(RAISED_AT)::DATE AS from_date,
       MAX(RAISED_AT)::DATE AS to_date
FROM QCOMMERCE.OPS.COMPLAINT_TRUTH;
SQL

PUT_STMT="PUT file://$TRUTH @QCOMMERCE.OPS.STG_EVAL AUTO_COMPRESS=FALSE OVERWRITE=TRUE"

if [ "$LOAD" != "1" ]; then
    echo
    echo "== DRY RUN. Nothing has been sent to Snowflake."
    echo "== Statements that LOAD=1 would run, in order:"
    echo
    echo "$PUT_STMT;"
    echo
    echo "$STATEMENTS"
    echo "== WH_TRANSFORM_XS resumes for the COPY. Under 0.01 credits."
    echo "== Rerun with: LOAD=1 scripts/p10_truth.sh"
    exit 0
fi

echo "== PUT to the internal stage"
snow sql -c "$CONN" -q "USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p10:truth';
CREATE STAGE IF NOT EXISTS QCOMMERCE.OPS.STG_EVAL
  COMMENT = 'evaluation answer keys. Never read by a training or feature path';
$PUT_STMT;"

echo "== create and load"
snow sql -c "$CONN" -q "USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p10:truth';
$STATEMENTS"

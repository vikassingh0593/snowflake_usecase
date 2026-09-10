#!/usr/bin/env bash
# =============================================================================
# scripts/p6_dbt_run.sh — mechanism 14: dbt seeds.
#
# Runs in a container for the same reason as p3_sdk_run.sh and p6_pandas_run.sh:
# dbt-snowflake pulls cryptography, and cryptography 50.x has no macOS x86_64
# wheel, so pip would build it from source against the Intel Homebrew on a Mac
# whose Python is itself an Intel build under Rosetta.
#
# PREREQUISITE — SVC_CI needs a key pair. It was created with TYPE = SERVICE and
# no RSA_PUBLIC_KEY, so it cannot authenticate at all yet:
#
#   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_ci.p8 -nocrypt
#   openssl rsa -in rsa_ci.p8 -pubout -out rsa_ci.pub
#   chmod 600 rsa_ci.p8
#   grep -v "^-----" rsa_ci.pub | tr -d '\n'
#
# then ONE statement in Snowflake, with that single line pasted in:
#   ALTER USER SVC_CI SET RSA_PUBLIC_KEY = '<paste>';
#
# rsa_ci.p8 is gitignored by the existing *.p8 rule. Never commit it.
#
#   bash scripts/p6_dbt_run.sh            debug, then seed and test
#   bash scripts/p6_dbt_run.sh debug      connection check only, loads nothing
#   bash scripts/p6_dbt_run.sh seed       seeds without the tests
#
# COST: resumes WH_TRANSFORM_XS. Four seeds totalling 125 rows, plus ten tests.
# Under 0.01 credits.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f rsa_ci.p8 ] || {
  echo "rsa_ci.p8 not found in repo root."
  echo "SVC_CI has no key registered yet -- see the header of this script."
  exit 1
}

CMD="${1:-build}"
case "$CMD" in
  debug) DBT_ARGS="debug" ;;
  seed)  DBT_ARGS="seed" ;;
  build) DBT_ARGS="build" ;;      # seeds + their tests, in one pass
  *)     DBT_ARGS="$*" ;;
esac

# dbt-snowflake is left unpinned here and its version printed, because the
# right pin is the one that actually resolved. Pin it in CI (Part 14) once
# this run tells you what that is -- an unpinned build server is a different
# problem from an unpinned laptop.
docker run --rm -it \
  -v "$PWD":/work -w /work/dbt \
  -e DBT_KEY_PATH=/work/rsa_ci.p8 \
  python:3.12-slim \
  bash -c "pip install -q --disable-pip-version-check dbt-snowflake \
           && dbt --version \
           && dbt $DBT_ARGS --profiles-dir . --target dev"

cat <<'EOF'

== Verify in Snowflake
   snow sql -c qcpoc -q "
     SELECT TABLE_NAME, ROW_COUNT
     FROM QCOMMERCE.INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = 'RAW'
       AND TABLE_NAME IN ('CATEGORY_HIERARCHY','SLA_THRESHOLD',
                          'COMPLAINT_REASON_CODE','COMPLAINT_LABEL')
     ORDER BY TABLE_NAME"

   The labels only mean something joined to the corpus:
   snow sql -c qcpoc -q "
     SELECT l.REASON_CODE, COUNT(*) AS labelled, COUNT(d.TICKET_ID) AS matched
     FROM QCOMMERCE.RAW.COMPLAINT_LABEL l
     LEFT JOIN QCOMMERCE.RAW.COMPLAINT_DOC d USING (TICKET_ID)
     GROUP BY 1 ORDER BY 2 DESC"
EOF

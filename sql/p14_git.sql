-- =============================================================================
-- PART 14 — CI/CD, and one question this project has earned the right to ask.
--
-- §14 designs three things: a Git repository stage so Snowflake can read this
-- repo directly, EXECUTE IMMEDIATE FROM that stage for SQL deploys, and a
-- zero-copy clone of MART for dbt to build against on a pull request.
--
-- THE QUESTION. A clone is a new object built from an existing one. Everything
-- Part 13 found says that is exactly where protection goes missing:
--
--   materialised aggregate   the row filter never reached it
--   a share                  accepted the protected table without objecting
--   a promoted table         would freeze rows under the builder's visibility
--
-- DOES A ZERO-COPY CLONE CARRY THE ROW ACCESS POLICIES? If it does not, CI
-- builds against an unprotected copy of the fact table every time a pull
-- request opens, and the copy outlives the run if anything aborts. Nobody
-- documents clone and policy behaviour from both sides. STEP 4 measures it.
--
-- ON THE GIT INTEGRATION BEING AVAILABLE AT ALL. §1 Finding 3 is that external
-- access integrations are refused on this account. A Git repository stage is a
-- different object with a different integration type, but it also reaches the
-- public internet, so it is a fair guess that it is gated too. Attempted, not
-- assumed, and isolated so a refusal costs one row.
--
-- ON COST. A clone is free and instant -- it copies metadata, not data.
-- Everything else is metadata. Nothing is left behind. ~0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p14:git';
USE DATABASE QCOMMERCE;

CREATE OR REPLACE PROCEDURE QCOMMERCE.LAB.TMP_P14_PROBE()
RETURNS TABLE (SURFACE STRING, VERDICT STRING, DETAIL STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.types import StringType, StructField, StructType

SCHEMA = StructType([
    StructField("SURFACE", StringType()),
    StructField("VERDICT", StringType()),
    StructField("DETAIL", StringType()),
])

REPO_URL = "https://github.com/vikassingh0593/snowflake_usecase"


def run(session):
    rows = []

    def classify(msg):
        low = msg.lower()
        if "not available" in low or "not enabled" in low or "not supported" in low:
            return "GATED"
        if "unsupported feature" in low:
            return "NO SUCH FEATURE"
        if "syntax error" in low:
            return "NO SUCH SYNTAX"
        if "insufficient privileges" in low:
            return "NO PRIVILEGE"
        return "ERROR"

    def attempt(surface, stmt, summarise=None):
        try:
            res = session.sql(stmt).collect()
        except Exception as e:
            msg = str(e).replace(chr(10), " ")
            rows.append((surface, classify(msg), msg[:350]))
            return None
        detail = "{} row(s)".format(len(res)) if summarise is None else summarise(res)
        rows.append((surface, "OK", str(detail)[:350]))
        return res

    def drop(stmt):
        try:
            session.sql(stmt).collect()
        except Exception:
            pass

    # -- 1. The Git integration. Public repo, so no secret is needed -- which
    #       also makes this the cleanest possible test of whether the feature
    #       exists, with no credential handling to confuse a refusal.
    api_ok = attempt(
        "api integration for git",
        "CREATE OR REPLACE API INTEGRATION TMP_P14_GIT_API "
        "API_PROVIDER = git_https_api "
        "API_ALLOWED_PREFIXES = ('https://github.com/vikassingh0593') "
        "ENABLED = TRUE",
    )

    if api_ok is not None:
        repo_ok = attempt(
            "git repository stage",
            "CREATE OR REPLACE GIT REPOSITORY QCOMMERCE.LAB.TMP_P14_REPO "
            "API_INTEGRATION = TMP_P14_GIT_API "
            "ORIGIN = '" + REPO_URL + "'",
        )
        if repo_ok is not None:
            attempt("git fetch", "ALTER GIT REPOSITORY QCOMMERCE.LAB.TMP_P14_REPO FETCH")
            attempt(
                "list files on main",
                "LS @QCOMMERCE.LAB.TMP_P14_REPO/branches/main/sql/",
                lambda r: "{} file(s)".format(len(r)),
            )
            # EXECUTE IMMEDIATE FROM is the deploy mechanism. It used to point
            # at sql/p13_probe.sql, chosen for changing no state -- and that
            # file opens with USE ROLE on line 48. EXECUTE IMMEDIATE FROM runs
            # a file as a Snowflake Scripting block, where USE does not exist,
            # so the probe reported
            #
            #   090236 (42601): ... on line 48 at position 0: Unsupported
            #   statement type 'USE'
            #
            # and read as the feature failing when the feature was fine. Step
            # 54 deploys through the same mechanism and succeeds.
            #
            # sql/deploy/ exists for exactly this contract and its own header
            # documents this error -- the repository already knew, in a
            # different file from the one probing. CREATE OR REPLACE VIEW, so
            # running it here and again in step 54 lands the same object twice.
            attempt(
                "EXECUTE IMMEDIATE FROM the repo",
                "EXECUTE IMMEDIATE FROM "
                "@QCOMMERCE.LAB.TMP_P14_REPO/branches/main/sql/deploy/"
                "v_share_entitlement.sql",
            )
            drop("DROP GIT REPOSITORY QCOMMERCE.LAB.TMP_P14_REPO")
        drop("DROP API INTEGRATION TMP_P14_GIT_API")
        rows.append(("git: cleanup", "OK", "repository and integration dropped"))

    return session.create_dataframe(rows, schema=SCHEMA)
$$;

CALL QCOMMERCE.LAB.TMP_P14_PROBE();

DROP PROCEDURE IF EXISTS QCOMMERCE.LAB.TMP_P14_PROBE();

-- =============================================================================
-- STEP 4 — the clone, and whether protection survives it.
--
-- Plain DDL rather than a procedure: a clone is free, instant and droppable,
-- and the answer matters enough to be read directly rather than summarised.
-- =============================================================================
CREATE OR REPLACE SCHEMA QCOMMERCE.MART_CI CLONE QCOMMERCE.MART;

-- The original, for comparison.
SELECT 'MART.FCT_ORDER'   AS OBJECT_NAME,
       COUNT(*)           AS POLICY_REFS
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.MART.FCT_ORDER',
           REF_ENTITY_DOMAIN => 'TABLE'));

SELECT 'MART_CI.FCT_ORDER' AS OBJECT_NAME,
       COUNT(*)            AS POLICY_REFS
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.MART_CI.FCT_ORDER',
           REF_ENTITY_DOMAIN => 'TABLE'));

-- And the reading that matters: does the clone filter for a constrained role?
-- Equal counts across the two roles on the clone would mean CI builds against
-- an unprotected copy of the fact table on every pull request.
GRANT USAGE  ON SCHEMA QCOMMERCE.MART_CI            TO ROLE QC_ANALYST;
GRANT SELECT ON TABLE  QCOMMERCE.MART_CI.FCT_ORDER  TO ROLE QC_ANALYST;

SELECT 'ACCOUNTADMIN' AS WHOAMI,
       (SELECT COUNT(DISTINCT STORE_SK) FROM QCOMMERCE.MART.FCT_ORDER)    AS STORES_ORIGINAL,
       (SELECT COUNT(DISTINCT STORE_SK) FROM QCOMMERCE.MART_CI.FCT_ORDER) AS STORES_CLONE;

USE ROLE QC_ANALYST;
USE WAREHOUSE WH_APP_XS;

SELECT 'QC_ANALYST' AS WHOAMI,
       (SELECT COUNT(DISTINCT STORE_SK) FROM QCOMMERCE.MART.FCT_ORDER)    AS STORES_ORIGINAL,
       (SELECT COUNT(DISTINCT STORE_SK) FROM QCOMMERCE.MART_CI.FCT_ORDER) AS STORES_CLONE;

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
USE DATABASE QCOMMERCE;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'clone_carries_row_access_policy',
       'MART_CI.FCT_ORDER',
       COUNT(*) >= 1,
       COUNT(*),
       'a zero-copy clone keeps the row access policy of its source',
       TO_VARIANT('if zero, CI builds against an unprotected copy of the fact table')
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.MART_CI.FCT_ORDER',
           REF_ENTITY_DOMAIN => 'TABLE'));

-- Nothing left behind. A clone costs nothing until the source diverges, but an
-- unprotected copy of the fact table is not a thing to leave lying about while
-- the answer is still being read.
DROP SCHEMA IF EXISTS QCOMMERCE.MART_CI;

SELECT CHECK_NAME, TARGET, PASSED, OBSERVED
FROM   OPS.DQ_RESULTS
WHERE  CHECK_NAME = 'clone_carries_row_access_policy'
ORDER  BY CHECK_TS DESC
LIMIT  1;

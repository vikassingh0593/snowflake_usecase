-- =============================================================================
-- PART 12 / STEP 0 — which governance features this account actually has.
--
-- §1 Finding 2 established that the account is Enterprise-shaped, by CREATE
-- MASKING POLICY succeeding rather than by reading an edition string. That
-- says nothing about the rest of §12: data metric functions, tag-based
-- masking, SYSTEM$CLASSIFY, alerts and notification integrations are all
-- separately gated, and this account has already refused external access while
-- permitting everything around it.
--
-- Every attempt runs inside one procedure with its own try/except, because
-- snow sql aborts the whole file on the first error and the point here is to
-- learn about ten things rather than the first one. Each creates a throwaway
-- object and drops it.
--
-- ON COST. Two items in §12 maintain themselves in the background and are
-- exactly the always-on serverless the cost rules exist to prevent. Search
-- optimization is only ESTIMATED here, never built. The materialized view is
-- built on MART.DIM_STORE -- eight rows -- and dropped in the same call, so
-- its maintenance cost rounds to nothing. Neither is left behind.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:probe';
USE DATABASE QCOMMERCE;

CREATE OR REPLACE PROCEDURE LAB.TMP_GOV_PROBE()
RETURNS TABLE (FEATURE STRING, VERDICT STRING, DETAIL STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.types import StringType, StructField, StructType

SCHEMA = StructType([
    StructField("FEATURE", StringType()),
    StructField("VERDICT", StringType()),
    StructField("DETAIL", StringType()),
])


def run(session):
    rows = []

    def attempt(feature, statements, cleanup=(), capture=None):
        """Run statements in order; record the first failure or the capture.

        Cleanup runs whether or not the attempt succeeded, and its own errors
        are swallowed -- a probe that leaves objects behind because teardown
        raised is worse than one that reports a little less.
        """
        detail = "ok"
        verdict = "YES"
        try:
            for st in statements:
                res = session.sql(st).collect()
            if capture is not None:
                got = session.sql(capture).collect()
                detail = str(got[0][0])[:300] if got else "no rows"
        except Exception as exc:
            verdict = "NO"
            detail = "%s: %s" % (type(exc).__name__,
                                 str(exc).replace("\n", " ")[:280])
        finally:
            for st in cleanup:
                try:
                    session.sql(st).collect()
                except Exception:
                    pass
        rows.append((feature, verdict, detail))

    # 1 -- masking policy. Confirmed in Session 2; re-run so this table is a
    #      complete picture rather than a picture with a footnote.
    attempt("masking policy",
            ["""CREATE OR REPLACE MASKING POLICY LAB.TMP_MASK AS (v STRING)
                RETURNS STRING ->
                CASE WHEN CURRENT_ROLE() = 'ACCOUNTADMIN' THEN v ELSE '***' END"""],
            ["DROP MASKING POLICY IF EXISTS LAB.TMP_MASK"])

    # 2 -- row access policy
    attempt("row access policy",
            ["""CREATE OR REPLACE ROW ACCESS POLICY LAB.TMP_RAP AS (store STRING)
                RETURNS BOOLEAN ->
                CURRENT_ROLE() = 'ACCOUNTADMIN' OR store = 'DS001'"""],
            ["DROP ROW ACCESS POLICY IF EXISTS LAB.TMP_RAP"])

    # 3 -- tag-based masking. The interesting one: attach a policy to a TAG and
    #      it applies everywhere the tag does, which is what object tags on
    #      their own never gave.
    attempt("tag-based masking",
            ["CREATE OR REPLACE TAG LAB.TMP_TAG",
             """CREATE OR REPLACE MASKING POLICY LAB.TMP_TAGMASK AS (v STRING)
                RETURNS STRING -> '***'""",
             "ALTER TAG LAB.TMP_TAG SET MASKING POLICY LAB.TMP_TAGMASK"],
            ["ALTER TAG IF EXISTS LAB.TMP_TAG UNSET MASKING POLICY LAB.TMP_TAGMASK",
             "DROP MASKING POLICY IF EXISTS LAB.TMP_TAGMASK",
             "DROP TAG IF EXISTS LAB.TMP_TAG"])

    # 4 -- data metric function
    attempt("data metric function",
            # The body is single-quoted on purpose. This procedure is
            # delimited by a dollar-quote pair and those do not nest, so a
            # dollar-quoted body here would end the procedure early,
            # mid-statement. The first draft of this comment said so using the
            # characters themselves and would have caused exactly that: the
            # parser scans for the closing delimiter and has no idea it is
            # reading a Python comment.
            ["""CREATE OR REPLACE DATA METRIC FUNCTION LAB.TMP_DMF(t TABLE(c STRING))
                RETURNS NUMBER AS 'SELECT COUNT(*) FROM t WHERE c IS NULL'"""],
            ["DROP FUNCTION IF EXISTS LAB.TMP_DMF(TABLE(STRING))"])

    # 5 -- can a DMF actually be attached and scheduled, which is a separate
    #      privilege from creating one
    attempt("data metric schedule",
            ["ALTER TABLE MART.DIM_STORE SET DATA_METRIC_SCHEDULE = '60 MINUTE'"],
            ["ALTER TABLE MART.DIM_STORE UNSET DATA_METRIC_SCHEDULE"])

    # 6 -- built-in classification. Restores something Cortex's absence took.
    for label, sql in (
        ("SYSTEM$CLASSIFY (brace config)",
         "SELECT SYSTEM$CLASSIFY('QCOMMERCE.MART.DIM_CUSTOMER', {'auto_tag': false})"),
        ("SYSTEM$CLASSIFY (object config)",
         "SELECT SYSTEM$CLASSIFY('QCOMMERCE.MART.DIM_CUSTOMER', "
         "OBJECT_CONSTRUCT('auto_tag', FALSE))"),
    ):
        attempt(label, [], capture=sql)

    # 7 -- search optimization: estimated, never built. Building it starts
    #      background maintenance that outlives the session.
    attempt("search optimization estimate", [],
            capture="SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS("
                    "'QCOMMERCE.MART.FCT_ORDER')")

    # 8 -- materialized view, on eight rows, dropped immediately
    attempt("materialized view",
            ["""CREATE OR REPLACE MATERIALIZED VIEW LAB.TMP_MV AS
                SELECT STORE_CODE, CITY FROM MART.DIM_STORE"""],
            ["DROP MATERIALIZED VIEW IF EXISTS LAB.TMP_MV"])

    # 9 -- alerting, and the notification integration email needs
    attempt("alert",
            ["""CREATE OR REPLACE ALERT LAB.TMP_ALERT
                  WAREHOUSE = WH_TRANSFORM_XS
                  SCHEDULE = '1440 MINUTE'
                  IF (EXISTS (SELECT 1 FROM OPS.DQ_RESULTS WHERE NOT PASSED))
                  THEN SELECT 1"""],
            ["DROP ALERT IF EXISTS LAB.TMP_ALERT"])

    attempt("email notification integration",
            ["""CREATE OR REPLACE NOTIFICATION INTEGRATION TMP_EMAIL
                  TYPE = EMAIL ENABLED = TRUE"""],
            ["DROP INTEGRATION IF EXISTS TMP_EMAIL"])

    # 10 -- lineage. ACCESS_HISTORY is Enterprise and lags by up to three
    #       hours, so an empty result is ambiguous between "not available" and
    #       "not caught up". Both are reported.
    attempt("ACCESS_HISTORY readable", [],
            capture="SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY")
    attempt("OBJECT_DEPENDENCIES readable", [],
            capture="SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES")
    attempt("QUERY_ATTRIBUTION_HISTORY readable", [],
            capture="SELECT COUNT(*) FROM "
                    "SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY")

    return session.create_dataframe(rows, schema=SCHEMA)
$$;

CALL LAB.TMP_GOV_PROBE();

DROP PROCEDURE IF EXISTS LAB.TMP_GOV_PROBE();

-- =============================================================================
-- Nothing above is left behind. Confirm it.
-- =============================================================================
SHOW MASKING POLICIES IN SCHEMA LAB;
SHOW ROW ACCESS POLICIES IN SCHEMA LAB;
SHOW TAGS IN SCHEMA LAB;
SHOW ALERTS IN SCHEMA LAB;
SHOW MATERIALIZED VIEWS IN SCHEMA LAB;

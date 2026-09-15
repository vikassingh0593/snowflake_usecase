-- =============================================================================
-- PART 12 / REPAIR — governance broke the performance layer, and the account
-- default warehouse outspent the entire project.
--
-- TWO FIXES, BOTH DDL, BOTH AGREED BEFORE WRITING.
--
-- -----------------------------------------------------------------------------
-- FIX 1 — SERVE.SLA_STORE_HOUR_AGG has been failing since 2026-09-13.
--
-- DYNAMIC_TABLE_REFRESH_HISTORY, five consecutive failures from 12:07 to 15:31
-- on 09-13, last success INCREMENTAL at 10:18:
--
--   002766: Dynamic table SERVE.SLA_STORE_HOUR_AGG is no longer
--   incrementalizable because of reason 'Change tracking is not supported on
--   queries with correlated subquery expressions.'. Please recreate the
--   dynamic table.
--
-- The query never changed. "No longer" is the whole message. A row access
-- policy body IS a correlated subquery, injected into every query touching the
-- protected table, and GOV.RAP_STORE went onto MART.FCT_ORDER between 11:15
-- and 12:07 on 09-13. This aggregate reads MART.FCT_ORDER.
--
-- THE THIRD CONSEQUENCE OF ONE POLICY, AND THE WORST-BEHAVED.
--
--   materialized view on FCT_ORDER   refused at CREATE. Loud, immediate,
--                                    already documented in §12.
--   dynamic table on FCT_ORDER       accepted, validated INCREMENTAL, then
--                                    stopped. Failed five times and suspended
--                                    itself.
--   the application                  served 11:15 Wednesday data ever since,
--                                    with nothing on screen to say so.
--
-- This inverts §11's own design principle. That section declared
-- REFRESH_MODE = INCREMENTAL explicitly so an unmaintainable query would fail
-- at CREATE rather than downgrade silently -- and it did exactly that, once.
-- What no CREATE-time check can cover is the table underneath changing later.
-- §11 and §12 were built in isolation and §12 silently broke §11.
--
-- STEP 2 ATTEMPTS INCREMENTAL FIRST AND WAS REFUSED. Measured on the run of
-- 2026-09-14 06:55:01, recovered from QUERY_HISTORY:
--
--   FAILED_WITH_ERROR   SQL compilation error: line 2 at position 5:
--                       Change tracking is not supported on queries with
--                       correlated subquery expressions.
--
-- A COMPILATION ERROR, NOT A REFRESH ERROR. Snowflake's create-time check does
-- see the attached row access policy and does refuse. The policy is proven to
-- be the cause rather than inferred from the timing of the failures, which is
-- what the diagnostic attempt was for.
--
-- THAT SHARPENS THE FINDING RATHER THAN SOFTENING IT. The check is not blind
-- to policies; it only runs at CREATE. An already-created dynamic table is
-- never re-validated when a policy is attached to its source. It keeps the
-- INCREMENTAL mode it was granted and discovers at the next refresh that the
-- mode is no longer achievable. The exact statement refused outright today was
-- already running yesterday, and nothing revisited it.
--
-- The file lands on REFRESH_MODE = FULL, which re-aggregates all 19,377 rows
-- hourly. At this size that is seconds and the credits round to nothing. THE
-- HONEST STATEMENT IS THAT GOVERNANCE FORCED THE PERFORMANCE LAYER BACK TO A
-- FULL REBUILD, and at a size where that mattered this would be an
-- architectural conflict rather than a footnote.
--
-- MEASURED AFTER THE REPAIR. refresh_mode FULL, configured_refresh_mode FULL,
-- refresh_mode_reason None, scheduling_state ACTIVE, last_suspended_on None,
-- 7,626 rows. Four checks green, including 19,377 orders summed reconciling
-- exactly to 19,377 delivered in MART.FCT_ORDER. The two refreshes that
-- followed read FULL, the ON_CREATE initialize, then NO_DATA, the forced
-- refresh finding no delta -- correct, because MART has not moved since.
--
-- THE APPLICATION SERVED STALE DATA FOR 19 HOURS 39 MINUTES. Last good refresh
-- 2026-09-13 11:15:28, five failures, repaired 2026-09-14 06:55:04. Nothing on
-- any screen said so, and nothing would have.
--
-- Rejected alternatives: sourcing the aggregate from CORE instead of MART
-- (SERVE would stop being governed, which is the point of SERVE); moving
-- RAP_STORE off the base fact onto a view (§12's finding is that a policy
-- attached at the base travels every path -- moving it defeats the
-- demonstration); dropping the policy (loses the governance layer to save a
-- refresh mode).
--
-- -----------------------------------------------------------------------------
-- FIX 2 — 55.0% of warehouse spend is unmonitored.
--
-- Per-warehouse, 2026-09-07 onward:
--
--   SNOWFLAKE_LEARNING_WH   3.142465   unmonitored   7 days
--   WH_TRANSFORM_XS         1.775760   RM_POC        5 days
--   WH_APP_XS               0.708300   RM_POC        2 days
--   WH_INGEST_XS            0.086368   RM_POC        6 days
--   CLOUD_SERVICES_ONLY     0.001714   n/a           4 days
--
-- A Snowflake-provided default warehouse is the single biggest consumer on the
-- account, on more days than any warehouse this project built, and nothing
-- watches it. The three designed warehouses are 45% of the total.
--
-- RM_POC is not repairable into the right shape. It is level = WAREHOUSE, so
-- it can never cover a warehouse created later, and FREQUENCY = NEVER with
-- start_time 2026-09-09 11:50:26 means its 60 credits are a LIFETIME cap that
-- never resets -- at 60 it suspends the three project warehouses until someone
-- resets it by hand. Its figure reconciles exactly: 2.566476 computed against
-- 2.55 reported, so both causes of the gap are fully accounted for.
--
-- RM_POC IS LEFT IN PLACE DELIBERATELY. It is a working hard stop on the
-- project's own warehouses and the account monitor sits above it, not instead
-- of it.
--
-- NO SUSPEND TRIGGER ON THE ACCOUNT MONITOR. An account-level monitor that
-- suspends stops every warehouse at once, including the one needed to
-- investigate why. Notify at 50/75/90 and let the 80-credit budget be the
-- backstop above that.
--
-- ON COST. The FULL refresh reads 19,377 rows. The monitor statements are
-- metadata. Estimated spend: ~0.03 credits including the auto-suspend tail.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:serve_repair';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — before. What the app has been serving, and for how long.
-- =============================================================================
SELECT COUNT(*)                        AS ROWS_NOW,
       MAX(PLACED_DATE)                AS LATEST_DATE,
       MAX(IST_HOUR)                   AS LATEST_HOUR_ON_THAT_DATE,
       SUM(ORDERS)                     AS ORDERS_COVERED
FROM   SERVE.SLA_STORE_HOUR_AGG;

SELECT STATE,
       COUNT(*)                        AS N,
       MIN(REFRESH_START_TIME)         AS FIRST_SEEN,
       MAX(REFRESH_START_TIME)         AS LAST_SEEN
FROM   TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
           NAME => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG'))
GROUP  BY STATE
ORDER  BY LAST_SEEN DESC;

-- =============================================================================
-- STEP 2 — attempt INCREMENTAL, expect refusal, then land on FULL.
--
-- Both statements live inside a procedure because snow sql -f aborts the file
-- on the first error and the refusal is an expected result rather than a
-- failure. The body is byte-identical to p11_serve.sql apart from the refresh
-- mode, so nothing about the aggregate changes and the app's contract holds.
-- =============================================================================
CREATE OR REPLACE PROCEDURE LAB.TMP_SERVE_REPAIR()
RETURNS TABLE (STEP STRING, VERDICT STRING, DETAIL STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.types import StringType, StructField, StructType

SCHEMA = StructType([
    StructField("STEP", StringType()),
    StructField("VERDICT", StringType()),
    StructField("DETAIL", StringType()),
])

BODY = """
AS
SELECT s.STORE_CODE,
       s.CITY,
       o.PLACED_TS::DATE                                    AS PLACED_DATE,
       HOUR(DATEADD('minute', 330, o.PLACED_TS))            AS IST_HOUR,
       COUNT(*)                                             AS ORDERS,
       SUM(IFF(o.IS_BREACHED, 1, 0))                        AS BREACHED,
       SUM(DATEDIFF('second', o.PLACED_TS, o.PROMISED_TS))  AS PROMISED_SEC,
       SUM(DATEDIFF('second', o.PLACED_TS, o.DELIVERED_TS)) AS DELIVERED_SEC,
       COUNT(o.DELIVERED_TS)                                AS DELIVERED_N,
       SUM(o.ORDER_TOTAL_PAISE)                             AS GROSS_PAISE
FROM   MART.FCT_ORDER o
JOIN   MART.DIM_STORE s ON s.STORE_SK = o.STORE_SK
WHERE  o.STATUS = 'DELIVERED'
GROUP  BY s.STORE_CODE, s.CITY, PLACED_DATE, IST_HOUR
"""


def head(mode, comment):
    return (
        "CREATE OR REPLACE DYNAMIC TABLE SERVE.SLA_STORE_HOUR_AGG "
        "TARGET_LAG = '60 minutes' "
        "WAREHOUSE = WH_TRANSFORM_XS "
        "REFRESH_MODE = " + mode + " "
        "COMMENT = '" + comment + "' " + BODY
    )


def run(session):
    rows = []

    # The diagnostic attempt. A refusal here is the result, not a problem: it
    # proves the row access policy is what made the query non-incrementalizable
    # rather than leaving it inferred from the timing of the failures.
    incremental_held = False
    try:
        session.sql(head("INCREMENTAL", "diagnostic attempt")).collect()
        incremental_held = True
        rows.append((
            "INCREMENTAL attempt",
            "ACCEPTED",
            "Snowflake did not refuse. The create-time check does not see the "
            "attached row access policy, so this table would fail again at its "
            "next refresh. Worse than a refusal, and replaced below.",
        ))
    except Exception as e:
        msg = str(e).replace("\n", " ")
        low = msg.lower()
        if "incrementaliz" in low or "correlated subquery" in low or "change tracking" in low:
            verdict = "REFUSED, AS EXPECTED"
        else:
            verdict = "REFUSED, DIFFERENT REASON"
        rows.append(("INCREMENTAL attempt", verdict, msg[:400]))

    # The landing state. Runs whichever way the attempt went -- an accepted
    # INCREMENTAL is a table that fails at its next refresh, so it is not a
    # state to leave behind.
    try:
        session.sql(head(
            "FULL",
            "additive aggregates only. FULL because GOV.RAP_STORE on "
            "MART.FCT_ORDER injects a correlated subquery and change tracking "
            "cannot incrementalize one. See p12_serve_repair.sql",
        )).collect()
        rows.append((
            "FULL create",
            "OK",
            "replaced" if incremental_held else "created after the refusal",
        ))
    except Exception as e:
        rows.append(("FULL create", "ERROR", str(e).replace("\n", " ")[:400]))
        return session.create_dataframe(rows, schema=SCHEMA)

    # Force one refresh now rather than waiting up to an hour to find out
    # whether FULL actually works against a policy-protected base table.
    try:
        session.sql("ALTER DYNAMIC TABLE SERVE.SLA_STORE_HOUR_AGG REFRESH").collect()
        rows.append(("forced refresh", "OK", "completed"))
    except Exception as e:
        rows.append(("forced refresh", "ERROR", str(e).replace("\n", " ")[:400]))

    return session.create_dataframe(rows, schema=SCHEMA)
$$;

CALL LAB.TMP_SERVE_REPAIR();

DROP PROCEDURE IF EXISTS LAB.TMP_SERVE_REPAIR();

-- =============================================================================
-- STEP 3 — the account-level monitor.
--
-- CREATE IF NOT EXISTS rather than OR REPLACE: replacing a monitor already
-- attached to the account detaches it for the length of the statement, and
-- Part 12 established that CREATE OR REPLACE on an attached policy is refused
-- outright for the same class of reason. IF NOT EXISTS also makes the file
-- re-runnable, which is the property a governance script most needs.
-- =============================================================================
CREATE RESOURCE MONITOR IF NOT EXISTS RM_ACCOUNT
  WITH CREDIT_QUOTA    = 60
       FREQUENCY       = MONTHLY
       START_TIMESTAMP = IMMEDIATELY
       NOTIFY_USERS    = ('VIKASSINGH0593')
  TRIGGERS ON 50 PERCENT DO NOTIFY
           ON 75 PERCENT DO NOTIFY
           ON 90 PERCENT DO NOTIFY;

ALTER ACCOUNT SET RESOURCE_MONITOR = RM_ACCOUNT;

-- =============================================================================
-- STEP 4 — checks.
-- =============================================================================
WITH dt AS (
    SELECT STATE, REFRESH_START_TIME
    FROM   TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
               NAME => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG'))
    -- NULLS LAST, because DESC is NULLS FIRST in Snowflake and a refresh that
    -- never started has no REFRESH_START_TIME. The teardown drops
    -- WH_TRANSFORM_XS, so a scheduled refresh lands as FAILED 002725
    -- "warehouse is missing" with a null start time -- and that row then sorted
    -- ahead of every real refresh and became "the latest". The giveaway was
    -- DETAIL printing as None: STATE || ' at ' || NULL is NULL.
    QUALIFY ROW_NUMBER() OVER (ORDER BY REFRESH_START_TIME DESC NULLS LAST) = 1
),
agg AS (
    SELECT COUNT(*) AS N, SUM(ORDERS) AS ORDERS FROM SERVE.SLA_STORE_HOUR_AGG
),
vw AS (
    SELECT COUNT(*) AS N FROM SERVE.SLA_BY_STORE_HOUR
),
src AS (
    SELECT COUNT(*) AS N FROM MART.FCT_ORDER WHERE STATUS = 'DELIVERED'
)
SELECT 'latest_refresh_succeeded' AS CHECK_NAME,
       (SELECT STATE FROM dt) = 'SUCCEEDED' AS PASSED,
       (SELECT STATE || ' at ' || REFRESH_START_TIME::STRING FROM dt) AS DETAIL
UNION ALL
SELECT 'aggregate_is_not_empty',
       (SELECT N FROM agg) > 0,
       (SELECT N::STRING || ' rows' FROM agg)
UNION ALL
SELECT 'view_matches_aggregate',
       (SELECT N FROM vw) = (SELECT N FROM agg),
       (SELECT (SELECT N FROM vw)::STRING || ' view vs ' || (SELECT N FROM agg)::STRING || ' agg')
UNION ALL
SELECT 'orders_reconcile_to_fct_order',
       (SELECT ORDERS FROM agg) = (SELECT N FROM src),
       (SELECT (SELECT ORDERS FROM agg)::STRING || ' summed vs ' || (SELECT N FROM src)::STRING || ' delivered');

-- Every warehouse now answers to something. A blank MONITOR here after the
-- account monitor is attached would mean ALTER ACCOUNT did not take effect,
-- because an account-level monitor does not populate the per-warehouse column.
SHOW WAREHOUSES;

SELECT "name" AS WAREHOUSE, "resource_monitor" AS WAREHOUSE_MONITOR
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER  BY 1;

SHOW RESOURCE MONITORS;

SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

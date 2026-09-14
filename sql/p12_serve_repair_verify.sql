-- =============================================================================
-- PART 12 / REPAIR — verification reprint.
--
-- p12_serve_repair.sql ran and its two DDL fixes both appear to have landed,
-- but SHOW WAREHOUSES and SHOW RESOURCE MONITORS render one character per
-- column in snow sql and pushed everything above them off the scrollback. The
-- account monitor was readable in what survived:
--
--   RM_ACCOUNT  quota 60  used 0.00  level ACCOUNT  MONTHLY
--               suspend_at None  suspend_immediately_at None
--   RM_POC      quota 60  used 2.59  level WAREHOUSE  NEVER
--
-- level = ACCOUNT is the proof that ALTER ACCOUNT SET RESOURCE_MONITOR took
-- effect. Fix 2 is done. Fix 1's outcome is unknown and this file recovers it.
--
-- NOTHING HERE RE-RUNS THE REPAIR. Every statement is a read. Re-running the
-- CREATE would destroy the evidence this file exists to read.
--
-- THE ONE THING WORTH RECOVERING. The diagnostic attempt in STEP 2 -- whether
-- CREATE ... REFRESH_MODE = INCREMENTAL was refused against a table carrying a
-- row access policy -- was reported in the CALL result and is gone. It is not
-- lost: the statement was issued inside the procedure and INFORMATION_SCHEMA's
-- QUERY_HISTORY table function keeps seven days account-wide at low latency,
-- error message included. STEP 4 reads it back.
--
-- Run this one through the wrapper rather than snow sql directly:
--
--   scripts/sql.sh sql/p12_serve_repair_verify.sql
--
-- It keeps result boxes and error lines and drops the echoed statements, which
-- is what made the last run unreadable. That is what the wrapper is for and I
-- should have said so before the previous file, not after.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:serve_repair_verify';
USE DATABASE QCOMMERCE;

-- STEP 1 -- what the dynamic table is now.
-- Column names taken from the header the earlier SHOW actually printed rather
-- than guessed, which is the third time this session that would have mattered.
SHOW DYNAMIC TABLES IN SCHEMA SERVE;

SELECT "name"                AS DT,
       "target_lag"          AS TARGET_LAG,
       "refresh_mode"        AS REFRESH_MODE,
       "refresh_mode_reason" AS REASON,
       "scheduling_state"    AS SCHEDULING_STATE,
       "rows"                AS ROWS_IN_DT,
       "last_suspended_on"   AS LAST_SUSPENDED_ON
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- STEP 2 -- did the forced refresh work, and is the failure streak over?
SELECT STATE,
       STATE_CODE,
       LEFT(COALESCE(STATE_MESSAGE, ''), 120) AS MESSAGE,
       REFRESH_ACTION,
       REFRESH_START_TIME
FROM   TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
           NAME => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG'))
ORDER  BY REFRESH_START_TIME DESC
LIMIT  6;

-- STEP 3 -- the four checks, re-run.
WITH dt AS (
    SELECT STATE, REFRESH_START_TIME
    FROM   TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
               NAME => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG'))
    QUALIFY ROW_NUMBER() OVER (ORDER BY REFRESH_START_TIME DESC) = 1
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

-- STEP 4 -- the diagnostic, recovered.
-- Both CREATE statements the procedure issued, newest first. The INCREMENTAL
-- one is the answer: FAIL with a message naming incrementalizability or a
-- correlated subquery means the row access policy is proven to be the cause
-- rather than inferred from the timing of the failures. SUCCESS means the
-- create-time check is blind to the attached policy, which is the worse
-- finding and the one worth writing down.
SELECT START_TIME,
       EXECUTION_STATUS,
       CASE WHEN QUERY_TEXT ILIKE '%REFRESH_MODE = INCREMENTAL%' THEN 'INCREMENTAL'
            WHEN QUERY_TEXT ILIKE '%REFRESH_MODE = FULL%'        THEN 'FULL'
            ELSE 'other' END                      AS ATTEMPT,
       LEFT(COALESCE(ERROR_MESSAGE, 'none'), 300) AS ERROR_MESSAGE
FROM   TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 1000))
WHERE  QUERY_TEXT ILIKE '%DYNAMIC TABLE SERVE.SLA_STORE_HOUR_AGG%'
  AND  QUERY_TEXT ILIKE 'CREATE%'
ORDER  BY START_TIME DESC
LIMIT  8;

-- STEP 5 -- how stale the app was, for the record.
-- The gap between the last successful INCREMENTAL refresh and the repair is
-- the window in which the store heatmap showed Wednesday-morning data with
-- nothing on screen to say so.
SELECT MIN(CASE WHEN STATE = 'SUCCEEDED' THEN REFRESH_START_TIME END) AS FIRST_SUCCESS,
       MAX(CASE WHEN STATE = 'FAILED'    THEN REFRESH_START_TIME END) AS LAST_FAILURE,
       COUNT(CASE WHEN STATE = 'FAILED' THEN 1 END)                   AS FAILURES,
       MAX(CASE WHEN STATE = 'SUCCEEDED' THEN REFRESH_START_TIME END) AS LAST_SUCCESS
FROM   TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
           NAME => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG'));

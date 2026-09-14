-- =============================================================================
-- PART 12 / ADDENDUM 2 — the monitor gap resolved, and something worse found.
--
-- WHY RM_POC REPORTS LESS THAN HALF. Two causes compounding, not one.
--
--   1. Three of six warehouses have no monitor at all:
--        COMPUTE_WH                    null   auto_suspend 600
--        SNOWFLAKE_LEARNING_WH         null   auto_suspend 300
--        SYSTEM$STREAMLIT_NOTEBOOK_WH  null   auto_suspend 60
--      COMPUTE_WH is the account default, so anything run without an explicit
--      USE WAREHOUSE lands there and is never counted.
--
--   2. RM_POC has FREQUENCY = NEVER, start_time 2026-09-09 11:50:26, end_time
--      None. It began counting two days into the build and misses 09-07
--      (0.2387) and 09-08 (0.5668) entirely.
--
-- THE QUOTA IS A LIFETIME CAP, NOT A MONTHLY ONE. FREQUENCY = NEVER means the
-- 60 credits never reset: at 60 it suspends the three project warehouses and
-- stays suspended until someone resets it by hand. Currently 2.55. This was
-- never the intent and the docs describe it as if it recurred.
--
-- A CORRECTION TO THE PREVIOUS FILE'S HEADER. It recorded WH_TRANSFORM_XS at
-- ~4.7530 "inferred by subtraction". That inference was unsound -- the
-- per-warehouse output was truncated at the top and the two system warehouses
-- were almost certainly among the hidden rows. STEP 1 prints the real split.
--
-- THE SERVERLESS TASK IS NOT OURS. SERVERLESS_TASK_HISTORY names _BACKFILL_TASK
-- with TASK_ID 1 and a null database -- a Snowflake-internal task. SHOW TASKS
-- returns exactly one task account-wide, CORTEX_BASE_MODELS_REFRESH_TASK in
-- SNOWFLAKE.MODELS, started, serverless, cron 33 12 * * * UTC, owner SNOWFLAKE.
-- Neither can be stopped. Neither is a breach of the "nothing runs 24/7" rule,
-- but the account is never truly at zero and the cost model should say so.
--
-- AND THIS PROJECT HAS NO TASKS AT ALL, which makes §7 -- the FINALIZER,
-- SYSTEM$SET_RETURN_VALUE, stream-gated tasks, serverless-vs-warehouse
-- comparison -- design rather than as-built. STEP 2 confirms it inside
-- QCOMMERCE specifically, because SHOW ... IN ACCOUNT can be role-scoped in
-- ways that hide things.
--
-- THE THING THAT MATTERS MOST. SHOW DYNAMIC TABLES reports
-- SERVE.SLA_STORE_HOUR_AGG with scheduling_state = SUSPENDED and
-- last_suspended_on 2026-09-13 15:31:30 -- inside the Part 12 governance
-- window. SERVE.SLA_BY_STORE_HOUR is a view over it and the app reads that
-- view, so the store heatmap may have been frozen since Wednesday afternoon.
--
-- Part 12 already established that a row access policy makes materialized
-- views on FCT_ORDER impossible. If the same collision suspends dynamic tables
-- it is a second, larger consequence of the same decision -- and unlike the
-- materialized view, nothing refused at CREATE time. It went quiet instead.
-- STEP 3 asks the refresh history for the reason rather than inferring it from
-- a state column.
--
-- ON COST. Metadata and ACCOUNT_USAGE reads. Nothing created, altered,
-- resumed or dropped -- the dynamic table stays suspended until its cause is
-- known, because resuming it before that just repeats whatever happened.
-- Estimated spend: ~0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:monitor_gap2';
USE DATABASE QCOMMERCE;

-- STEP 1 -- the real per-warehouse split, replacing an unsound inference.
-- Monitored and unmonitored side by side, so the gap is arithmetic rather than
-- argument. SINCE_MONITOR is the slice RM_POC could in principle have seen.
SELECT WAREHOUSE_NAME,
       ROUND(SUM(CREDITS_USED), 6)                                      AS TOTAL,
       ROUND(SUM(CASE WHEN START_TIME >= '2026-09-09 11:50:26'
                      THEN CREDITS_USED ELSE 0 END), 6)                 AS SINCE_MONITOR,
       ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 6)                       AS CLOUD_SERVICES,
       COUNT(DISTINCT DATE(START_TIME))                                 AS DAYS
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= '2026-09-07'
GROUP BY WAREHOUSE_NAME
ORDER BY TOTAL DESC;

-- The three project warehouses only, since the monitor started. This should
-- reconcile to RM_POC's used_credits of 2.55 -- if it does, both causes are
-- fully accounted for and nothing else is hiding.
SELECT ROUND(SUM(CREDITS_USED), 6) AS RECONCILES_TO_RM_POC
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= '2026-09-09 11:50:26'
  AND WAREHOUSE_NAME IN ('WH_TRANSFORM_XS', 'WH_INGEST_XS', 'WH_APP_XS');

-- STEP 2 -- does this project own any task at all?
SHOW TASKS IN DATABASE QCOMMERCE;

SELECT COUNT(*) AS QCOMMERCE_TASKS
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- STEP 3 -- why did the dynamic table stop, and when did it last succeed?
-- The refresh history carries STATE and STATE_MESSAGE. A suspension caused by
-- the row access policy will say so there; a manual suspension will not.
SELECT NAME,
       STATE,
       STATE_CODE,
       STATE_MESSAGE,
       REFRESH_START_TIME,
       REFRESH_END_TIME,
       REFRESH_ACTION
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG'))
ORDER BY REFRESH_START_TIME DESC
LIMIT 20;

-- How stale is what the app is serving right now.
SELECT COUNT(*)              AS ROWS_IN_AGG,
       MAX(STORE_HOUR)       AS LATEST_HOUR
FROM SERVE.SLA_STORE_HOUR_AGG;

-- STEP 4 -- placed last, UNVERIFIED column name.
-- The account-level view of the same history, in case the INFORMATION_SCHEMA
-- function is scoped in a way that hides a suspension reason.
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
ORDER BY REFRESH_START_TIME DESC
LIMIT 20;

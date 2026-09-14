-- =============================================================================
-- PART 12 / ADDENDUM — what metered as AI on an account that refuses AI?
--
-- The budget's spending history carries two lines that should not exist on an
-- account where every Cortex call fails with "not available for trial
-- accounts" (§1 Finding 1):
--
--   AI_FUNCTIONS   0.000636   2026-09-08
--   AI_INFERENCE   0.000057   2026-09-11
--
-- 2026-09-11 is the day Part 9 scored its model. The working hypothesis is
-- that Model Registry inference bills under AI_INFERENCE rather than warehouse
-- metering -- which would mean this project has been spending AI credits since
-- Part 9 while documenting the AI layer as unavailable. 2026-09-08 is earlier
-- and has no obvious cause.
--
-- The view names below were ENUMERATED, not guessed. SHOW VIEWS LIKE
-- '%USAGE_HISTORY%' IN SCHEMA SNOWFLAKE.ACCOUNT_USAGE returned twenty AI and
-- model views; three of them can carry these two charges. Part 12 lost four
-- runs to invented object names and two more to invented method names, and
-- listing what exists before calling anything is what ended it.
--
-- No WHERE clause and no column names. These views hold at most a handful of
-- rows on this account, and the column list is itself part of the answer --
-- guessing a date column would repeat the mistake this file exists to avoid.
--
-- ON COST. Read-only. ACCOUNT_USAGE selects need a warehouse but scan almost
-- nothing. Estimated spend: ~0.01 credits.
--
-- ON LATENCY. These views share ACCOUNT_USAGE's lag of up to three hours. The
-- 09-08 and 09-11 charges are days old and will be present; anything from
-- today may not be.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:cost_ai_trace';

-- The hypothesis. If Part 9 scoring is what metered as AI_INFERENCE, it shows
-- here with a model name this project will recognise.
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.MODEL_SERVING_USAGE_HISTORY LIMIT 50;

-- The 09-08 charge. Both Cortex function views, because the split between them
-- is not documented anywhere this account can see.
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY LIMIT 50;

SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY LIMIT 50;

-- Which query did it, if the views above name a query id.
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY LIMIT 50;

-- =============================================================================
-- The other open discrepancy: two instruments, two totals.
--
--   budget GET_SPENDING_HISTORY   WAREHOUSE_METERING   5.394110
--   METERING_DAILY_HISTORY        WAREHOUSE_METERING   5.546495
--
-- ACCOUNT_USAGE reads 0.152385 HIGHER, which rules out latency -- latency
-- would make it read low. And METERING_DAILY_HISTORY carries SERVERLESS_TASK
-- 0.001771 on 09-14 that the budget's 27 rows do not list at all, so the
-- budget is not the complete view of serverless it appeared to be.
--
-- UNVERIFIED: the likeliest cause of the 0.152385 is the 10% cloud services
-- free allowance, applied by one instrument and not the other. Day-level
-- figures below are directly comparable to the 27 rows already printed.
-- =============================================================================
SELECT USAGE_DATE,
       ROUND(SUM(CREDITS_USED_COMPUTE), 6)        AS COMPUTE,
       ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 6) AS CLOUD_SERVICES,
       ROUND(SUM(CREDITS_ADJUSTMENT_CLOUD_SERVICES), 6) AS CS_ADJUSTMENT,
       ROUND(SUM(CREDITS_USED), 6)                AS TOTAL
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= '2026-09-07'
  AND SERVICE_TYPE = 'WAREHOUSE_METERING'
GROUP BY USAGE_DATE
ORDER BY USAGE_DATE;

-- Every service type by day, so SERVERLESS_TASK on 09-14 can be placed against
-- the budget's silence on it.
SELECT USAGE_DATE,
       SERVICE_TYPE,
       ROUND(SUM(CREDITS_USED), 6) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= '2026-09-07'
  AND SERVICE_TYPE <> 'WAREHOUSE_METERING'
GROUP BY USAGE_DATE, SERVICE_TYPE
ORDER BY USAGE_DATE, CREDITS DESC;

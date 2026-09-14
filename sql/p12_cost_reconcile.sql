-- =============================================================================
-- PART 12 / ADDENDUM — three instruments, three different totals.
--
-- The account budget reports spend by SERVICE_TYPE and is the first instrument
-- in this project that sees both warehouse and serverless. Running it produced
-- a reconciliation that contradicts an assumption held since Part 3.
--
--   BUDGET, 2026-09-07 to 2026-09-14, 8 days
--     WAREHOUSE_METERING                        5.394110   99.70%
--     everything else, all serverless           0.016307    0.30%
--     total                                     5.410417   6.8% of the 80 limit
--
--   RM_POC (SHOW RESOURCE MONITORS)             2.42       level=WAREHOUSE
--   QUERY_ATTRIBUTION_HISTORY (p12_quality)     0.3844     tagged queries only
--
-- THREE READINGS, IN DESCENDING ORDER OF HOW MUCH THEY MATTER.
--
-- 1. RM_POC SEES 45% OF WAREHOUSE SPEND, NOT 100%. The standing assumption was
--    that the monitor covered warehouse compute fully and missed serverless
--    entirely. The second half is right; the first half is not. 2.42 against
--    5.39 on the same metering type is a 2.97 credit blind spot inside the one
--    thing the monitor was supposed to be authoritative about. STEP 1 finds
--    out why -- the likeliest cause is warehouses that were never assigned to
--    it, and level=WAREHOUSE already says there is no account-level monitor
--    sitting above it to catch the remainder.
--
-- 2. THE SERVERLESS WORRY WAS STRUCTURALLY RIGHT AND NUMERICALLY IRRELEVANT.
--    0.0163 credits over eight days. PIPE totals 0.000113 with four of seven
--    days at exactly zero -- two continuously-running ingestion mechanisms for
--    a rounding error. The cost rules spent real design effort here. Worth
--    recording honestly rather than quietly dropping.
--
-- 3. IDLE TIME IS THE COST STORY, NOT COMPUTE. Attributed query credits are
--    0.3844 against 5.3941 metered: 93% of warehouse spend was not attributed
--    query execution. An XS warehouse bills 1 credit/hour and AUTO_SUSPEND is
--    60 seconds, so every isolated statement in an interactive session buys a
--    minute of billed time plus resume for a few seconds of work, hundreds of
--    times over. At this scale batching statements matters far more than
--    warehouse size -- which is the opposite of the usual advice, and only
--    visible because all three instruments were read together.
--
-- TWO ANOMALIES, QUERIES NOT CONCLUSIONS.
--
--   AI_FUNCTIONS   0.000636 on 2026-09-08
--   AI_INFERENCE   0.000057 on 2026-09-11
--
-- Both metered on an account that refuses Cortex with "not available for trial
-- accounts" (§1 Finding 1). UNVERIFIED: the 09-11 date lines up with Part 9
-- model scoring, so registry inference may bill under AI_INFERENCE rather than
-- warehouse metering. STEP 4 looks for the usage view that would say.
--
-- QUERY_ACCELERATION at 0.005849 on 09-08 needs no query: it confirms the §16
-- delta. The feature is on by default, it did bill as serverless, and setting
-- ENABLE_QUERY_ACCELERATION = FALSE was correct. The evidence arrived six days
-- after the decision.
--
-- ON COST. Read-only throughout. No ALTER, no resource monitor change, no
-- budget change -- STEP 1 diagnoses the coverage gap and the fix is a separate
-- decision. Estimated spend: ~0.02 credits.
--
-- ON LATENCY. ACCOUNT_USAGE views lag by up to three hours, so today's figures
-- will read low against the budget, which does not use ACCOUNT_USAGE. A gap on
-- the current day is expected and is not the discrepancy being investigated.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:cost_reconcile';
USE DATABASE QCOMMERCE;

-- STEP 1 -- which warehouses does RM_POC actually monitor?
-- The resource_monitor column is empty for any warehouse running unwatched.
-- This is the decisive statement for reading 1.
SHOW WAREHOUSES;

SELECT "name"             AS WAREHOUSE,
       "size"             AS SIZE,
       "resource_monitor" AS MONITOR,
       "auto_suspend"     AS AUTO_SUSPEND
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY 1;

SHOW RESOURCE MONITORS;

-- STEP 2 -- the same eight days, split by warehouse.
-- Sums to the budget's 5.394110 if every warehouse is present. Whichever
-- warehouse carries the missing 2.97 is the one not assigned to RM_POC.
SELECT WAREHOUSE_NAME,
       ROUND(SUM(CREDITS_USED_COMPUTE), 6)        AS COMPUTE_CREDITS,
       ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 6) AS CLOUD_SERVICES,
       ROUND(SUM(CREDITS_USED), 6)                AS TOTAL,
       COUNT(DISTINCT DATE(START_TIME))           AS DAYS
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= '2026-09-07'
GROUP BY WAREHOUSE_NAME
ORDER BY TOTAL DESC;

-- STEP 3 -- the budget's own numbers, from the other side.
-- Two independent instruments on one period. They should agree on
-- WAREHOUSE_METERING; where they do not, ACCOUNT_USAGE latency is the first
-- suspect and only for the current day.
SELECT SERVICE_TYPE,
       ROUND(SUM(CREDITS_USED), 6) AS CREDITS,
       MIN(USAGE_DATE)             AS FIRST_DAY,
       MAX(USAGE_DATE)             AS LAST_DAY
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= '2026-09-07'
GROUP BY SERVICE_TYPE
ORDER BY CREDITS DESC;

-- STEP 4 -- which view explains the AI metering?
-- Enumerated rather than guessed. Part 12 lost four runs to invented object
-- names and two more to invented method names; the discipline that ended it
-- was listing what exists before calling anything. Placed last because a SHOW
-- that fails aborts the file and everything above is already printed.
SHOW VIEWS LIKE '%USAGE_HISTORY%' IN SCHEMA SNOWFLAKE.ACCOUNT_USAGE;

SELECT "name" AS VIEW_NAME
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" ILIKE '%AI%'
   OR "name" ILIKE '%CORTEX%'
   OR "name" ILIKE '%INFERENCE%'
   OR "name" ILIKE '%MODEL%'
ORDER BY 1;

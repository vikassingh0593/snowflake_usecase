-- =============================================================================
-- PART 12 / ADDENDUM — RM_POC reports 2.42. The budget reports 5.39.
--
-- Two instruments on the same WAREHOUSE_METERING over the same eight days:
--
--   budget GET_SPENDING_HISTORY    5.394110
--   RM_POC used_credits            2.42        level=WAREHOUSE
--
-- The monitor sees 45% of warehouse spend. For twelve parts this project has
-- assumed RM_POC covered warehouse compute fully and missed only serverless.
-- The second half holds -- serverless totalled 0.0163 and the monitor sees
-- none of it -- but the first half does not, and a 2.97 credit blind spot sits
-- inside the one thing the monitor was supposed to be authoritative about.
--
-- 2.42 matches no clean subset of the per-warehouse totals:
--
--   WH_TRANSFORM_XS   ~4.7530   (inferred by subtraction)
--   WH_APP_XS          0.7083
--   WH_INGEST_XS       0.0836
--   CLOUD_SERVICES_ONLY 0.0016
--
-- So the cause is probably not which warehouses are assigned. The next
-- candidate is the monitor's own interval: used_credits counts the CURRENT
-- period, and a FREQUENCY with a START_TIMESTAMP part-way through these eight
-- days would reset the counter mid-window. STEP 2 prints every column of the
-- single monitor row so frequency and start_time can be read rather than
-- guessed.
--
-- TWO OUTCOMES, TWO DIFFERENT RESPONSES.
--
--   A warehouse with a blank resource_monitor has been running unwatched since
--   bootstrap. That is a finding for §16 and a one-line fix.
--
--   A monitor whose interval simply started late is working correctly, the
--   60-credit quota is real, and the only change needed is to the sentence in
--   the docs claiming it covers everything but serverless.
--
-- STEP 3 -- WHAT IS STILL RUNNING. METERING_DAILY_HISTORY shows
-- SERVERLESS_TASK 0.001771 on 2026-09-14. The cost rules say nothing runs
-- 24/7, and Part 12 detached a data metric function specifically to stop an
-- hourly job nobody asked for. A task with an empty warehouse column is
-- serverless, so that column is the answer.
--
-- ON COST. Metadata only -- SHOW statements and RESULT_SCAN over their output.
-- Nothing created, nothing altered, nothing dropped. Estimated spend: ~0.02
-- credits, almost all of it the auto-suspend tail.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:monitor_gap';
USE DATABASE QCOMMERCE;

-- STEP 1 -- which warehouses are watched at all.
-- A blank MONITOR is a warehouse spending credits that RM_POC never counts.
SHOW WAREHOUSES;

SELECT "name"             AS WAREHOUSE,
       "size"             AS SIZE,
       "resource_monitor" AS MONITOR,
       "auto_suspend"     AS AUTO_SUSPEND,
       "state"            AS STATE
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY 1;

-- STEP 2 -- the monitor's own interval.
-- Every column, not a projection. There is one row, so the width is readable,
-- and Part 12 lost two runs to guessing which spelling a SHOW uses -- taking
-- all of them removes the category rather than betting on it.
SHOW RESOURCE MONITORS;

SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- STEP 3 -- what is scheduled, and what of it is serverless.
-- An empty WAREHOUSE on a task means serverless compute, which is what put
-- SERVERLESS_TASK in the metering on 2026-09-14. STARTED state on any of them
-- is the thing to look at.
SHOW TASKS IN ACCOUNT;

SELECT "name"          AS TASK,
       "schema_name"   AS SCHEMA,
       "state"         AS STATE,
       "schedule"      AS SCHEDULE,
       "warehouse"     AS WAREHOUSE,
       "condition"     AS GATE
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY 3 DESC, 1;

-- The other two things that maintain themselves without being asked.
-- One dynamic table is expected and budgeted for; a second is not.
SHOW DYNAMIC TABLES IN ACCOUNT;

SHOW ALERTS IN ACCOUNT;

-- STEP 4 -- placed last because the view name is UNVERIFIED.
-- If it does not exist the file has already printed everything above.
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
ORDER BY START_TIME DESC
LIMIT 20;

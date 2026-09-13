-- =============================================================================
-- PART 12 / STEP 4 — search optimization and the materialized view.
--
-- These are the two features in §12 that maintain themselves in the
-- background. Everything else in this part is free once built; these two spend
-- credits for as long as they exist, without anybody running anything. That is
-- exactly what this project's cost rules forbid, so the whole cycle --
-- estimate, build, measure, DROP -- happens in this one file and nothing
-- survives it.
--
-- PREDICTION, recorded before the measurements. MART.FCT_ORDER is 20,000 rows
-- of narrow columns, which is very likely a SINGLE micro-partition. Search
-- optimization and clustering both work by letting the engine skip partitions.
-- With one partition there is nothing to skip, so both should show NO
-- improvement at all, and the estimate already says the search optimization
-- build costs 0.000323 credits plus storage to achieve it.
--
-- If that holds, the finding is the one worth writing down: these are features
-- for tables two or three orders of magnitude larger than this, and the way to
-- know is to count partitions before building anything.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:serverless';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — how many partitions are there to skip.
--
-- This is the question that decides whether either feature can help, and it
-- costs nothing to ask.
-- =============================================================================
SHOW TABLES LIKE 'FCT_ORDER' IN SCHEMA MART;

SELECT "name", "rows", "bytes",
       ROUND("bytes" / 1024.0 / 1024.0, 2) AS mb,
       "clustering_key",
       "search_optimization"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT SYSTEM$CLUSTERING_INFORMATION('MART.FCT_ORDER', '(ORDER_ID)')
         AS clustering_information;

-- =============================================================================
-- STEP 2 — the baseline lookup, measured rather than timed by eye.
--
-- INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION, not ACCOUNT_USAGE: the local
-- one is near-real-time, so the query just run can be measured immediately.
-- The ACCOUNT_USAGE view lags hours and is useless for a before-and-after in
-- a single sitting.
--
-- PARTITIONS_SCANNED over PARTITIONS_TOTAL is the number that matters. Elapsed
-- time on a warm XS warehouse is mostly noise at this size.
-- =============================================================================
SELECT COUNT(*) AS found, MAX(ORDER_TOTAL_PAISE) AS total_paise
FROM   MART.FCT_ORDER
WHERE  ORDER_ID = 909089;

SELECT QUERY_ID, PARTITIONS_SCANNED, PARTITIONS_TOTAL,
       EXECUTION_TIME AS exec_ms, BYTES_SCANNED
FROM   TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
WHERE  QUERY_TEXT ILIKE '%ORDER_ID = 909089%'
  AND  QUERY_TEXT NOT ILIKE '%QUERY_HISTORY_BY_SESSION%'
ORDER  BY START_TIME DESC
LIMIT  1;

-- =============================================================================
-- STEP 3 — build search optimization, measure, and drop it.
--
-- The estimate from p12_probe.sql said 0.000323 credits to build. The build is
-- asynchronous: ADD SEARCH OPTIMIZATION returns immediately and the structure
-- fills in behind it, so SHOW TABLES is checked afterwards to see how far it
-- got. On one partition it should be instant and useless in equal measure.
-- =============================================================================
ALTER TABLE MART.FCT_ORDER ADD SEARCH OPTIMIZATION ON EQUALITY(ORDER_ID);

SHOW TABLES LIKE 'FCT_ORDER' IN SCHEMA MART;
SELECT "name", "search_optimization", "search_optimization_progress",
       "search_optimization_bytes"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT COUNT(*) AS found, MAX(ORDER_TOTAL_PAISE) AS total_paise
FROM   MART.FCT_ORDER
WHERE  ORDER_ID = 909090;

SELECT QUERY_ID, PARTITIONS_SCANNED, PARTITIONS_TOTAL,
       EXECUTION_TIME AS exec_ms, BYTES_SCANNED
FROM   TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
WHERE  QUERY_TEXT ILIKE '%ORDER_ID = 909090%'
  AND  QUERY_TEXT NOT ILIKE '%QUERY_HISTORY_BY_SESSION%'
ORDER  BY START_TIME DESC
LIMIT  1;

-- Gone. Not left for later, not left "just to see" -- this is the statement
-- the whole file exists to reach.
ALTER TABLE MART.FCT_ORDER DROP SEARCH OPTIMIZATION;

-- =============================================================================
-- STEP 4 — the materialized view, and the restriction that decides it.
--
-- SERVE.SLA_STORE_HOUR_AGG joins MART.FCT_ORDER to MART.DIM_STORE. A
-- materialized view CANNOT DO THAT -- no joins, no HAVING, no window
-- functions, one table only. So the comparison is not "which is faster" but
-- "only one of them can express the aggregate at all", which is a shorter
-- conversation and a more useful one.
--
-- The illegal version is attempted inside a procedure so the error is recorded
-- rather than aborting the file.
-- =============================================================================
CREATE OR REPLACE PROCEDURE LAB.TMP_MV_PROBE()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
'
def run(session):
    stmt = """CREATE OR REPLACE MATERIALIZED VIEW LAB.TMP_MV_JOINED AS
              SELECT s.STORE_CODE, COUNT(*) AS ORDERS
              FROM   MART.FCT_ORDER o
              JOIN   MART.DIM_STORE s ON s.STORE_SK = o.STORE_SK
              GROUP  BY s.STORE_CODE"""
    try:
        session.sql(stmt).collect()
        session.sql("DROP MATERIALIZED VIEW IF EXISTS LAB.TMP_MV_JOINED").collect()
        return "a joined materialized view was ACCEPTED, which contradicts the docs"
    except Exception as exc:
        return "joined MV refused: %s" % str(exc).replace(chr(10), " ")[:260]
';

CALL LAB.TMP_MV_PROBE();
DROP PROCEDURE IF EXISTS LAB.TMP_MV_PROBE();

-- The legal version: one table, no join, so the store surrogate key rather
-- than the store code. Which means anything reading it still has to join to
-- get a name -- the join did not disappear, it moved to every reader.
CREATE OR REPLACE MATERIALIZED VIEW LAB.MV_ORDERS_BY_STORE AS
SELECT STORE_SK,
       COUNT(*)                        AS ORDERS,
       SUM(IFF(IS_BREACHED, 1, 0))     AS BREACHED,
       SUM(ORDER_TOTAL_PAISE)          AS GROSS_PAISE
FROM   MART.FCT_ORDER
WHERE  STATUS = 'DELIVERED'
GROUP  BY STORE_SK;

SHOW MATERIALIZED VIEWS IN SCHEMA LAB;
SELECT "name", "rows", "bytes", "refreshed_on", "behind_by", "invalid_reason"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT 'materialized view' AS source, STORE_SK, ORDERS, BREACHED
FROM   LAB.MV_ORDERS_BY_STORE ORDER BY ORDERS DESC LIMIT 3;

SELECT 'dynamic table' AS source, STORE_CODE, SUM(ORDERS) AS ORDERS,
       SUM(BREACHED) AS BREACHED
FROM   SERVE.SLA_STORE_HOUR_AGG GROUP BY STORE_CODE ORDER BY ORDERS DESC LIMIT 3;

-- =============================================================================
-- STEP 5 — checks, taken while both structures still exist.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'materialized_view_agrees_with_the_dynamic_table', 'LAB.MV_ORDERS_BY_STORE',
       (SELECT SUM(ORDERS) FROM LAB.MV_ORDERS_BY_STORE)
         = (SELECT SUM(ORDERS) FROM SERVE.SLA_STORE_HOUR_AGG)
       AND (SELECT SUM(BREACHED) FROM LAB.MV_ORDERS_BY_STORE)
         = (SELECT SUM(BREACHED) FROM SERVE.SLA_STORE_HOUR_AGG),
       (SELECT SUM(ORDERS) FROM LAB.MV_ORDERS_BY_STORE),
       'two maintained aggregates over the same fact table agree. If they '
         || 'disagree one of them is stale, and finding out which is the whole '
         || 'maintenance burden these objects carry',
       OBJECT_CONSTRUCT('mv',      (SELECT SUM(ORDERS) FROM LAB.MV_ORDERS_BY_STORE),
                        'dynamic', (SELECT SUM(ORDERS) FROM SERVE.SLA_STORE_HOUR_AGG));

-- =============================================================================
-- STEP 6 — DROP THE MATERIALIZED VIEW.
--
-- The reason this is a separate step with its own heading is that forgetting
-- it is the entire failure mode. A materialized view left behind is a small
-- recurring charge against a fixed trial balance, invisible in every warehouse
-- credit report because it is serverless, and discovered when the balance runs
-- out rather than when it is created.
-- =============================================================================
DROP MATERIALIZED VIEW IF EXISTS LAB.MV_ORDERS_BY_STORE;

SHOW MATERIALIZED VIEWS IN SCHEMA LAB;
SHOW TABLES LIKE 'FCT_ORDER' IN SCHEMA MART;
SELECT "name", "search_optimization", "clustering_key"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'nothing_serverless_survives_this_file', 'QCOMMERCE',
       (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS
         WHERE TABLE_SCHEMA = 'LAB' AND TABLE_NAME = 'MV_ORDERS_BY_STORE') = 0,
       (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_SCHEMA = 'LAB'),
       'the materialized view is gone and the search optimization is dropped. '
         || 'Observed is the number of views left in LAB, which should not '
         || 'include a materialized one',
       NULL;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('LAB.MV_ORDERS_BY_STORE', 'QCOMMERCE')
ORDER  BY CHECK_TS DESC
LIMIT  3;

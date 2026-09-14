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

-- ANY before-and-after in Snowflake has to turn this off first. The first
-- version of this file did not, and the baseline came back with
-- BYTES_SCANNED 0, EXECUTION_TIME 1 ms and a single operator reading
-- QUERY RESULT REUSE -- the query had been run in an earlier attempt, so the
-- result was served from cache and never executed. The comparison was a cache
-- hit against a real scan, which is not a comparison.
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- =============================================================================
-- STEP 1 — how many partitions are there to skip.
--
-- This is the question that decides whether either feature can help, and it
-- costs nothing to ask.
-- =============================================================================
SHOW TABLES LIKE 'FCT_ORDER' IN SCHEMA MART;

-- cluster_by, not clustering_key. SHOW TABLES and the ACCOUNT_USAGE views
-- name the same property differently, and I took the name from the wrong one.
SELECT "name", "rows", "bytes",
       ROUND("bytes" / 1024.0 / 1024.0, 2) AS mb,
       "cluster_by",
       "search_optimization",
       -- Snowflake micro-partitions hold roughly 16 MB compressed. A table
       -- smaller than one of them has nothing to prune, which decides this
       -- whole file before a single structure is built.
       CEIL("bytes" / 1024.0 / 1024.0 / 16.0) AS partitions_at_most
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
-- It does NOT carry PARTITIONS_SCANNED. That column is in ACCOUNT_USAGE's
-- QUERY_HISTORY and this is a different object with a different shape --
-- the eleventh time in this part I have named a column from the wrong
-- catalogue view. BYTES_SCANNED is here and is the honest proxy: pruning
-- shows up as bytes not read.
--
-- GET_QUERY_OPERATOR_STATS does report pruning precisely and in near-real
-- time, so it is queried with SELECT * rather than by naming keys I have not
-- seen. STEP 1 has in any case already answered the question:
-- total_partition_count is 1.
-- =============================================================================
SELECT COUNT(*) AS found, MAX(ORDER_TOTAL_PAISE) AS total_paise
FROM   MART.FCT_ORDER
WHERE  ORDER_ID = 909089;

SET before_id = (
  SELECT QUERY_ID
  FROM   TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
  WHERE  QUERY_TEXT ILIKE '%ORDER_ID = 909089%'
    AND  QUERY_TEXT NOT ILIKE '%QUERY_HISTORY_BY_SESSION%'
  ORDER  BY START_TIME DESC
  LIMIT  1);

SELECT 'before' AS phase, QUERY_ID, EXECUTION_TIME AS exec_ms,
       BYTES_SCANNED, ROWS_PRODUCED
FROM   TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
WHERE  QUERY_ID = $before_id;

-- SELECT *, because the shape of this one has not been seen yet and guessing
-- at it is what produced the error this statement replaces.
SELECT *
FROM   TABLE(GET_QUERY_OPERATOR_STATS($before_id));

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

SET after_id = (
  SELECT QUERY_ID
  FROM   TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
  WHERE  QUERY_TEXT ILIKE '%ORDER_ID = 909090%'
    AND  QUERY_TEXT NOT ILIKE '%QUERY_HISTORY_BY_SESSION%'
  ORDER  BY START_TIME DESC
  LIMIT  1);

SELECT 'after' AS phase, QUERY_ID, EXECUTION_TIME AS exec_ms,
       BYTES_SCANNED, ROWS_PRODUCED
FROM   TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
WHERE  QUERY_ID = $after_id;

SELECT *
FROM   TABLE(GET_QUERY_OPERATOR_STATS($after_id));

-- Gone. Not left for later, not left "just to see" -- this is the statement
-- the whole file exists to reach.
ALTER TABLE MART.FCT_ORDER DROP SEARCH OPTIMIZATION;

-- =============================================================================
-- STEP 4 — the materialized view, and the two restrictions that decide it.
--
-- The first was expected. SERVE.SLA_STORE_HOUR_AGG joins MART.FCT_ORDER to
-- MART.DIM_STORE and a materialized view cannot contain a join:
--
--   002212 (42601): Invalid materialized view definition. More than one table
--   referenced in the view definition
--
-- The second was not, and it is the more interesting one:
--
--   000002 (0A000): Unsupported feature 'Create Materialized view on entity
--   protected by row access policy'.
--
-- THE ROW ACCESS POLICY THIS PART ATTACHED IN STEP 3 OF p12_policies.sql MAKES
-- MATERIALIZED VIEWS ON MART.FCT_ORDER IMPOSSIBLE. Not slower, not partially
-- maintained -- refused outright. A governance control and a performance
-- feature that are documented pages apart turn out to be mutually exclusive on
-- the same table, and neither one's documentation is where you find that out.
--
-- It only surfaced because both were built. Either alone looks fine, and a
-- design that reviewed them separately would have shipped a plan containing
-- both.
--
-- So the legal MV moves to MART.FCT_ORDER_ITEM, which carries no row access
-- policy. Both refusals are attempted inside a procedure so they are recorded
-- rather than aborting the file -- which is how the second one was found, by
-- a file that aborted.
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
    attempts = [
        ("joined, two tables", """CREATE OR REPLACE MATERIALIZED VIEW LAB.TMP_MV_JOINED AS
              SELECT s.STORE_CODE, COUNT(*) AS ORDERS
              FROM   MART.FCT_ORDER o
              JOIN   MART.DIM_STORE s ON s.STORE_SK = o.STORE_SK
              GROUP  BY s.STORE_CODE"""),
        ("single table, but row-access protected", """CREATE OR REPLACE MATERIALIZED VIEW LAB.TMP_MV_RAP AS
              SELECT STORE_SK, COUNT(*) AS ORDERS
              FROM   MART.FCT_ORDER
              GROUP  BY STORE_SK"""),
    ]
    out = []
    for label, stmt in attempts:
        try:
            session.sql(stmt).collect()
            out.append("%s: ACCEPTED" % label)
        except Exception as exc:
            out.append("%s: refused -- %s"
                       % (label, str(exc).replace(chr(10), " ")[:200]))
        finally:
            for v in ("LAB.TMP_MV_JOINED", "LAB.TMP_MV_RAP"):
                try:
                    session.sql("DROP MATERIALIZED VIEW IF EXISTS " + v).collect()
                except Exception:
                    pass
    return " || ".join(out)
';

CALL LAB.TMP_MV_PROBE();
DROP PROCEDURE IF EXISTS LAB.TMP_MV_PROBE();

-- The legal version, on FCT_ORDER_ITEM because FCT_ORDER is off limits. One
-- table, no join, grouped on the product id -- so anything wanting a product
-- name still has to join. The join did not disappear, it moved to every
-- reader.
CREATE OR REPLACE MATERIALIZED VIEW LAB.MV_LINES_BY_PRODUCT AS
SELECT PRODUCT_ID,
       COUNT(*)                        AS LINES_,
       SUM(QTY)                        AS UNITS,
       SUM(LINE_TOTAL_PAISE)           AS GROSS_PAISE
FROM   MART.FCT_ORDER_ITEM
GROUP  BY PRODUCT_ID;

SHOW MATERIALIZED VIEWS IN SCHEMA LAB;
SELECT "name", "rows", "bytes", "refreshed_on", "behind_by", "invalid_reason"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT 'materialized view' AS source, PRODUCT_ID, LINES_, UNITS
FROM   LAB.MV_LINES_BY_PRODUCT ORDER BY LINES_ DESC LIMIT 3;

SELECT 'straight aggregate' AS source, PRODUCT_ID, COUNT(*) AS LINES_,
       SUM(QTY) AS UNITS
FROM   MART.FCT_ORDER_ITEM GROUP BY PRODUCT_ID ORDER BY LINES_ DESC LIMIT 3;

-- =============================================================================
-- STEP 5 — checks, taken while both structures still exist.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'materialized_view_agrees_with_the_source', 'LAB.MV_LINES_BY_PRODUCT',
       (SELECT SUM(LINES_) FROM LAB.MV_LINES_BY_PRODUCT)
         = (SELECT COUNT(*) FROM MART.FCT_ORDER_ITEM)
       AND (SELECT SUM(UNITS) FROM LAB.MV_LINES_BY_PRODUCT)
         = (SELECT SUM(QTY) FROM MART.FCT_ORDER_ITEM),
       (SELECT SUM(LINES_) FROM LAB.MV_LINES_BY_PRODUCT),
       'the maintained aggregate agrees with the table it aggregates. If it '
         || 'does not, it is stale, and noticing that is the maintenance '
         || 'burden these objects carry',
       OBJECT_CONSTRUCT('mv',     (SELECT SUM(LINES_) FROM LAB.MV_LINES_BY_PRODUCT),
                        'source', (SELECT COUNT(*) FROM MART.FCT_ORDER_ITEM));

-- =============================================================================
-- STEP 6 — DROP THE MATERIALIZED VIEW.
--
-- The reason this is a separate step with its own heading is that forgetting
-- it is the entire failure mode. A materialized view left behind is a small
-- recurring charge against a fixed trial balance, invisible in every warehouse
-- credit report because it is serverless, and discovered when the balance runs
-- out rather than when it is created.
-- =============================================================================
DROP MATERIALIZED VIEW IF EXISTS LAB.MV_LINES_BY_PRODUCT;

SHOW MATERIALIZED VIEWS IN SCHEMA LAB;
SHOW TABLES LIKE 'FCT_ORDER' IN SCHEMA MART;
SELECT "name", "search_optimization", "cluster_by"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'nothing_serverless_survives_this_file', 'QCOMMERCE',
       (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS
         WHERE TABLE_SCHEMA = 'LAB' AND TABLE_NAME = 'MV_LINES_BY_PRODUCT') = 0,
       (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_SCHEMA = 'LAB'),
       'the materialized view is gone and the search optimization is dropped. '
         || 'Observed is the number of views left in LAB, which should not '
         || 'include a materialized one',
       NULL;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('LAB.MV_LINES_BY_PRODUCT', 'QCOMMERCE')
ORDER  BY CHECK_TS DESC
LIMIT  3;

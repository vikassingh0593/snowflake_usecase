-- =============================================================================
-- PART 12 / STEP 3 — one quality rule expressed three ways, lineage two ways,
-- and the first real per-part credit report.
--
-- All three are read-mostly. The two items in §12 that maintain themselves in
-- the background -- search optimization and the materialized view -- are not
-- here; they get their own file so that estimate, build, measure and drop
-- happen in one sitting and nothing is left running.
--
-- ON THE DMF SCHEDULE. A scheduled data metric function is recurring
-- serverless compute, which the cost rules exist to prevent. So the metric is
-- called DIRECTLY first, which costs one query and nothing after it, and the
-- scheduled form is attached, shown, and then UNSET at the end of this file.
-- The mechanism gets demonstrated; nothing keeps running.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:quality_lineage';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — one rule, three expressions.
--
-- The rule: every line on an order resolves to a product version. This is not
-- a hypothetical. In Part 8 it was null on all 54,635 rows because the SCD2
-- seed used the wrong lower bound, and the dbt not_null test is what caught
-- it -- the relationships test passed, because relationship tests ignore
-- nulls.
--
-- Expression 1, dbt generic test: runs when someone runs dbt, fails the build,
--   visible in the dbt log and nowhere else.
-- Expression 2, SQL check into OPS.DQ_RESULTS: runs when the script runs,
--   keeps a dated history, visible in the app's health tab.
-- Expression 3, data metric function: runs on the platform's schedule with no
--   pipeline involved at all, and keeps its own history.
--
-- The third is the only one that still runs when nobody runs anything.
-- =============================================================================

-- Called directly. A DMF is an ordinary function and does not have to be
-- attached to anything to be useful, which is the cheapest way to get the
-- number and the one most easily missed.
-- NULL_COUNT and DUPLICATE_COUNT take one column each. ROW_COUNT is NOT here,
-- and the reason is worth keeping: its signature is TABLE() with zero columns,
-- so SELECT * hands it twelve and it refuses --
--
--   000939 (22023): too many arguments for function [ROW_COUNT$V1(...)]
--   expected 0, got 1
--
-- It is built to be ATTACHED to a table, where the platform supplies the
-- table, not to be called with a projection. COUNT(*) is the direct-call
-- answer and always was; reaching for a DMF to count rows was showing off.
SELECT SNOWFLAKE.CORE.NULL_COUNT(SELECT PRODUCT_SK FROM MART.FCT_ORDER_ITEM)
         AS null_product_sk,
       SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT ORDER_ITEM_SK FROM MART.FCT_ORDER_ITEM)
         AS duplicate_keys,
       (SELECT COUNT(*) FROM MART.FCT_ORDER_ITEM)
         AS rows_;

-- Expression 2, so the same rule has a dated history beside the other two.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'every_line_resolves_to_a_product_version', 'MART.FCT_ORDER_ITEM',
       (SELECT COUNT(*) FROM MART.FCT_ORDER_ITEM WHERE PRODUCT_SK IS NULL) = 0
       AND (SELECT COUNT(*) FROM MART.FCT_ORDER_ITEM) > 0,
       (SELECT COUNT(*) FROM MART.FCT_ORDER_ITEM WHERE PRODUCT_SK IS NULL),
       'no order line without a product version. The same rule dbt asserts as '
         || 'a not_null test and a data metric function measures on a schedule',
       OBJECT_CONSTRUCT('lines', (SELECT COUNT(*) FROM MART.FCT_ORDER_ITEM));

-- Expression 3, attached. TRIGGER_ON_CHANGES rather than a clock: MART only
-- changes when dbt runs, so a clock schedule would spend credits measuring a
-- table nobody touched.
ALTER TABLE MART.FCT_ORDER_ITEM SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE MART.FCT_ORDER_ITEM
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (PRODUCT_SK);

SELECT METRIC_NAME, REF_ENTITY_NAME, REF_ARGUMENTS, SCHEDULE, SCHEDULE_STATUS
FROM   TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
              REF_ENTITY_NAME => 'QCOMMERCE.MART.FCT_ORDER_ITEM',
              REF_ENTITY_DOMAIN => 'TABLE'));

-- =============================================================================
-- STEP 2 — lineage, column-level against object-level.
--
-- ACCESS_HISTORY records which COLUMNS a query touched and which columns fed
-- which outputs. QUERY_HISTORY records that a query happened and its text.
-- OBJECT_DEPENDENCIES records the static graph -- what references what --
-- whether or not anybody ever ran it.
--
-- The three answer different questions and only the first answers the one that
-- matters after a policy is attached: who actually read this column.
-- =============================================================================

-- ACCOUNT_USAGE lags. The documented figure is up to about 3 hours for
-- ACCESS_HISTORY, so the queries run minutes ago in this session will not be
-- here yet and an empty result proves nothing.
SELECT MAX(QUERY_START_TIME)                              AS newest_row,
       DATEDIFF('minute', MAX(QUERY_START_TIME), CURRENT_TIMESTAMP()) AS lag_minutes,
       COUNT(*)                                           AS rows_
FROM   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY;

-- Who read which column of the customer dimension, and when. This is the
-- question a masking policy raises and a grant cannot answer.
SELECT ah.USER_NAME,
       col.value:columnName::STRING                       AS column_read,
       COUNT(*)                                           AS reads,
       MAX(ah.QUERY_START_TIME)                           AS last_read
FROM   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.BASE_OBJECTS_ACCESSED) obj,
       LATERAL FLATTEN(input => obj.value:columns)        col
WHERE  obj.value:objectName::STRING = 'QCOMMERCE.MART.DIM_CUSTOMER'
GROUP  BY ah.USER_NAME, column_read
ORDER  BY reads DESC
LIMIT  15;

-- The same question through QUERY_HISTORY, which is the Standard substitute.
-- It knows a query ran and what its text was. It does not know which columns
-- came back, so answering "who read the email column" means parsing SQL.
SELECT QUERY_TAG,
       COUNT(*)                                           AS queries,
       SUM(IFF(QUERY_TEXT ILIKE '%DIM_CUSTOMER%', 1, 0))  AS mentions_the_table,
       SUM(IFF(QUERY_TEXT ILIKE '%EMAIL%', 1, 0))         AS mentions_a_column_name
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE  START_TIME > DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND  QUERY_TAG <> ''
GROUP  BY QUERY_TAG
ORDER  BY queries DESC
LIMIT  15;

-- The static graph. Nothing had to run for this to be true, which is its
-- advantage and its limit: it says what COULD read the column, not what did.
SELECT REFERENCING_SCHEMA || '.' || REFERENCING_OBJECT_NAME AS referencing,
       REFERENCING_OBJECT_DOMAIN                            AS kind,
       REFERENCED_SCHEMA || '.' || REFERENCED_OBJECT_NAME   AS references_
FROM   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
WHERE  REFERENCED_DATABASE = 'QCOMMERCE'
  AND  REFERENCED_SCHEMA IN ('MART', 'CORE', 'LAB')
ORDER  BY referencing
LIMIT  25;

-- =============================================================================
-- STEP 3 — what each part of this project actually cost.
--
-- Every script in this repo sets a QUERY_TAG on its session, which was cheap
-- discipline at the time and is the whole reason this query is possible. The
-- tags are p01: through p12: and they map to the parts.
--
-- QUERY_ATTRIBUTION_HISTORY attributes warehouse credits to individual
-- queries, which QUERY_HISTORY cannot do -- it knows elapsed time, not cost,
-- and a query that waits on a warehouse someone else woke is cheap despite
-- taking a while.
--
-- The same ACCOUNT_USAGE lag applies. This undercounts the last few hours.
-- =============================================================================
SELECT COALESCE(NULLIF(SPLIT_PART(qh.QUERY_TAG, ':', 1), ''), '(untagged)') AS part,
       COUNT(*)                                                     AS queries,
       ROUND(SUM(qa.CREDITS_ATTRIBUTED_COMPUTE), 4)                 AS credits,
       ROUND(SUM(qa.CREDITS_ATTRIBUTED_COMPUTE) * 100
             / NULLIF(SUM(SUM(qa.CREDITS_ATTRIBUTED_COMPUTE)) OVER (), 0), 1) AS pct
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qa
JOIN   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY             qh
       ON qh.QUERY_ID = qa.QUERY_ID
GROUP  BY part
ORDER  BY credits DESC NULLS LAST;

SELECT ROUND(SUM(CREDITS_ATTRIBUTED_COMPUTE), 4) AS total_attributed_credits,
       MIN(START_TIME)::DATE                     AS from_date,
       MAX(START_TIME)::DATE                     AS to_date
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY;

-- =============================================================================
-- STEP 4 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'data_metric_function_is_attached', 'MART.FCT_ORDER_ITEM',
       (SELECT COUNT(*) FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
                 REF_ENTITY_NAME => 'QCOMMERCE.MART.FCT_ORDER_ITEM',
                 REF_ENTITY_DOMAIN => 'TABLE'))) >= 1,
       (SELECT COUNT(*) FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
                 REF_ENTITY_NAME => 'QCOMMERCE.MART.FCT_ORDER_ITEM',
                 REF_ENTITY_DOMAIN => 'TABLE'))),
       'the null-count metric is attached to the column dbt also tests, so the '
         || 'same rule now runs on a pipeline AND on the platform',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'query_tags_cover_the_spend', 'SNOWFLAKE.ACCOUNT_USAGE',
       (SELECT SUM(IFF(NULLIF(qh.QUERY_TAG, '') IS NULL,
                       qa.CREDITS_ATTRIBUTED_COMPUTE, 0))
             / NULLIF(SUM(qa.CREDITS_ATTRIBUTED_COMPUTE), 0)
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qa
        JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh ON qh.QUERY_ID = qa.QUERY_ID) < 0.5,
       (SELECT ROUND(SUM(IFF(NULLIF(qh.QUERY_TAG, '') IS NULL,
                             qa.CREDITS_ATTRIBUTED_COMPUTE, 0))
                   / NULLIF(SUM(qa.CREDITS_ATTRIBUTED_COMPUTE), 0) * 10000)
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qa
        JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh ON qh.QUERY_ID = qa.QUERY_ID),
       'less than half the attributed credits are untagged, in basis points. '
         || 'Untagged spend is spend that cannot be explained, and the tags '
         || 'were set for exactly this query',
       NULL;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('MART.FCT_ORDER_ITEM', 'SNOWFLAKE.ACCOUNT_USAGE')
ORDER  BY CHECK_TS DESC
LIMIT  3;

-- =============================================================================
-- STEP 5 — stop the schedule.
--
-- The metric stays attached, so the reference and the mechanism survive in the
-- catalogue for anyone reading this later. The SCHEDULE does not, because a
-- schedule is the part that spends credits when nobody is looking, and this
-- project's rule is that nothing runs on its own.
--
-- Re-attach it by re-running STEP 1.
-- =============================================================================
ALTER TABLE MART.FCT_ORDER_ITEM UNSET DATA_METRIC_SCHEDULE;

SELECT METRIC_NAME, SCHEDULE, SCHEDULE_STATUS
FROM   TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
              REF_ENTITY_NAME => 'QCOMMERCE.MART.FCT_ORDER_ITEM',
              REF_ENTITY_DOMAIN => 'TABLE'));

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- ALTER TABLE MART.FCT_ORDER_ITEM
--   DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (PRODUCT_SK);

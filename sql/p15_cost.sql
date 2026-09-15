-- =============================================================================
-- PART 15 — what the whole thing cost, measured rather than estimated.
--
-- The question that has been open since Part 3 was "which part spent it".
-- Part 12 answered that with QUERY_ATTRIBUTION_HISTORY and the answer turned
-- out to be the least interesting number available. Reading four instruments
-- together says something none of them says alone.
--
--   budget GET_SPENDING_HISTORY       every service type, allowance applied
--   ACCOUNT_USAGE.METERING_DAILY      every service type, allowance NOT applied
--   WAREHOUSE_METERING_HISTORY        per warehouse, compute and cloud services
--   QUERY_ATTRIBUTION_HISTORY         per query, and therefore per part
--
-- WHAT MAKES THEM DISAGREE, ESTABLISHED 2026-09-14. The budget applies the 10%
-- cloud services allowance and ACCOUNT_USAGE does not, so CREDITS_USED is not
-- what you pay. RM_POC was narrower than anyone read it as: three of six
-- warehouses unassigned, and FREQUENCY = NEVER starting two days into the
-- build. And attribution counts query execution only, which turned out to be
-- 7% of warehouse spend.
--
-- THE THREE THINGS THIS REPORT EXISTS TO SAY, all of which run against the
-- advice usually given:
--
--   1  Waiting costs more than working. Attributed query compute is a small
--      fraction of metered compute; the rest is resume and the 60-second idle
--      window, paid hundreds of times for statements lasting seconds.
--   2  Serverless was the wrong thing to fear. Continuous ingestion of
--      ~548,000 rows across thirteen routes cost a rounding error.
--   3  The largest consumer was never part of the design. A vendor-default
--      warehouse nobody configured outspent the entire pipeline.
--
-- ON COST. Read-only. ACCOUNT_USAGE scans and one CALL. ~0.02 credits, which
-- this report will not include, which is itself the last joke in the project.
--
-- ON LATENCY. ACCOUNT_USAGE lags up to three hours. Today's figures read low.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p15:cost';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — the bill, from the only instrument that applies the allowance.
-- =============================================================================
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_LIMIT();

CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_HISTORY();

SELECT IFF(SERVICE_TYPE = 'WAREHOUSE_METERING', 'warehouse', 'serverless') AS KIND,
       ROUND(SUM(CREDITS_SPENT), 6)                                        AS CREDITS,
       ROUND(100.0 * SUM(CREDITS_SPENT)
             / NULLIF(SUM(SUM(CREDITS_SPENT)) OVER (), 0), 2)              AS PCT,
       COUNT(DISTINCT SERVICE_TYPE)                                        AS SERVICE_TYPES,
       MIN(MEASUREMENT_DATE)                                               AS FROM_DATE,
       MAX(MEASUREMENT_DATE)                                               AS TO_DATE
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
GROUP  BY KIND
ORDER  BY CREDITS DESC;

-- =============================================================================
-- STEP 2 — per warehouse, and whether anything was watching it.
-- =============================================================================
SELECT w.WAREHOUSE_NAME,
       ROUND(SUM(w.CREDITS_USED_COMPUTE), 4)        AS COMPUTE_CREDITS,
       ROUND(SUM(w.CREDITS_USED_CLOUD_SERVICES), 4) AS CLOUD_SERVICES,
       ROUND(SUM(w.CREDITS_USED), 4)                AS TOTAL,
       ROUND(100.0 * SUM(w.CREDITS_USED)
             / NULLIF(SUM(SUM(w.CREDITS_USED)) OVER (), 0), 1) AS PCT,
       IFF(w.WAREHOUSE_NAME LIKE 'WH\_%', 'designed for this project', 'vendor default') AS ORIGIN,
       COUNT(DISTINCT DATE(w.START_TIME))           AS ACTIVE_DAYS
FROM   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
WHERE  w.START_TIME >= '2026-09-07'
GROUP  BY w.WAREHOUSE_NAME
ORDER  BY TOTAL DESC;

-- =============================================================================
-- STEP 3 — per part, from the query tag set on every session since Part 3.
-- The discipline that makes this possible cost nothing and is the only reason
-- the question is answerable at all.
-- =============================================================================
SELECT CASE
         -- Snowflake's own surfaces set a JSON query tag. Streamlit's is
         -- {"StreamlitEngine": {...}}, and SPLIT_PART on ':' turned that into
         -- a part named {"StreamlitEngine -- which then came TOP of this table
         -- at 46% of attributed credits, above every real part. A tag that is
         -- not of the form part:thing is not a part, and the fix is to say so
         -- rather than to let it sort into the middle of the list unnoticed.
         -- String handling, not TRY_PARSE_JSON: the only thing needed is the
         -- first key, and a malformed tag should degrade rather than error.
         WHEN LEFT(qh.QUERY_TAG, 1) = '{'
           THEN 'vendor:' || LTRIM(SPLIT_PART(REPLACE(qh.QUERY_TAG, '"', ''), ':', 1), '{')
         ELSE COALESCE(NULLIF(SPLIT_PART(qh.QUERY_TAG, ':', 1), ''), '(untagged)')
       END                                                                 AS PART,
       COUNT(*)                                                            AS QUERIES,
       ROUND(SUM(qa.CREDITS_ATTRIBUTED_COMPUTE), 4)                        AS CREDITS,
       ROUND(SUM(qa.CREDITS_ATTRIBUTED_COMPUTE) * 100
             / NULLIF(SUM(SUM(qa.CREDITS_ATTRIBUTED_COMPUTE)) OVER (), 0), 1) AS PCT,
       -- THIS TABLE HAS NO TIME WINDOW, which is deliberate -- the question is
       -- what the whole thing cost -- but it is invisible in the output, and a
       -- reader who has just watched a rebuild finish will read these as the
       -- rebuild's numbers. They are not: they span every build in
       -- ACCOUNT_USAGE retention, and with the three-hour lag noted above, a
       -- run that finished minutes ago is barely in here at all.
       MIN(qh.START_TIME)::DATE                                            AS FROM_DATE,
       MAX(qh.START_TIME)::DATE                                            AS TO_DATE
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qa
JOIN   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY             qh
       ON qh.QUERY_ID = qa.QUERY_ID
GROUP  BY PART
ORDER  BY CREDITS DESC NULLS LAST;

-- =============================================================================
-- STEP 4 — the finding. Attributed execution against metered compute.
--
-- An XS warehouse bills one credit an hour and AUTO_SUSPEND is 60 seconds, so
-- every isolated statement in an interactive session buys a minute of billed
-- time plus a resume, for a few seconds of work. Hundreds of times over.
-- =============================================================================
WITH attributed AS (
    SELECT SUM(CREDITS_ATTRIBUTED_COMPUTE) AS C
    FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
),
metered AS (
    SELECT SUM(CREDITS_USED_COMPUTE) AS C
    FROM   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE  START_TIME >= '2026-09-07'
)
SELECT ROUND((SELECT C FROM attributed), 4)                      AS QUERY_EXECUTION,
       ROUND((SELECT C FROM metered), 4)                         AS METERED_COMPUTE,
       ROUND((SELECT C FROM metered) - (SELECT C FROM attributed), 4) AS IDLE_AND_RESUME,
       ROUND(100.0 * (1 - (SELECT C FROM attributed)
                          / NULLIF((SELECT C FROM metered), 0)), 1) AS PCT_NOT_EXECUTION;

-- =============================================================================
-- STEP 5 — storage, the one line item nobody has looked at.
-- Storage is billed per terabyte-month. At this scale it rounds to nothing, and
-- saying so with a number is better than assuming it.
-- =============================================================================
SELECT TABLE_SCHEMA,
       COUNT(*)                                                AS TABLES_COUNTED,
       ROUND(SUM(ACTIVE_BYTES)      / POWER(1024, 2), 2)       AS ACTIVE_MB,
       ROUND(SUM(TIME_TRAVEL_BYTES) / POWER(1024, 2), 2)       AS TIME_TRAVEL_MB,
       ROUND(SUM(FAILSAFE_BYTES)    / POWER(1024, 2), 2)       AS FAILSAFE_MB
FROM   SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE  TABLE_CATALOG = 'QCOMMERCE'
  AND  DELETED = FALSE
GROUP  BY TABLE_SCHEMA
ORDER  BY ACTIVE_MB DESC;

-- =============================================================================
-- STEP 6 — the closing record, into OPS so it survives this terminal.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'project_within_budget',
       'ACCOUNT_ROOT_BUDGET',
       SUM(CREDITS_USED) < 80,
       ROUND(SUM(CREDITS_USED), 4),
       'the whole build inside the 80 credit limit',
       TO_VARIANT('warehouse plus serverless, every service type, since 2026-09-07')
FROM   SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE  USAGE_DATE >= '2026-09-07';

SELECT CHECK_NAME, TARGET, PASSED, OBSERVED
FROM   OPS.DQ_RESULTS
WHERE  CHECK_NAME = 'project_within_budget'
ORDER  BY CHECK_TS DESC
LIMIT  1;

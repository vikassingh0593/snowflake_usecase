-- =============================================================================
-- PART 13 / STEP 2 — close the two defects that would otherwise be exported.
--
-- Part 13 set out to probe four outbound surfaces and found five defects
-- instead. Three of them are about sharing. Two are not, and both predate any
-- outbound work:
--
--   1  materialisation launders the row filter   measured: 8 stores vs 3
--   2  QC_ANALYST holds SELECT on MART base tables, which the docs deny
--   3  five of six SERVE views are not secure
--   4  SERVE references LAB, CORE and RAW directly
--   5  a share accepts a RAP-protected table, and a non-secure view once
--      SECURE_OBJECTS_ONLY is off
--
-- THIS FILE FIXES 1 AND 3. Both are small, both preserve grants, and both are
-- preconditions for pointing any outbound surface at SERVE. 2 and 4 are
-- documentation and dbt work respectively and are scoped separately; 5 is a
-- property of sharing rather than a defect to repair.
--
-- DEFECT 1, AND WHY A SECOND POLICY RATHER THAN THE EXISTING ONE.
--
-- GOV.RAP_STORE takes (store_sk STRING) and translates through DIM_STORE:
--
--   CURRENT_ROLE() IN ('ACCOUNTADMIN','QC_ADMIN','QC_ENGINEER')
--   OR EXISTS (SELECT 1 FROM GOV.ROLE_STORE_ENTITLEMENT e
--              JOIN MART.DIM_STORE s ON s.STORE_CODE = e.STORE_CODE
--              WHERE e.ROLE_NAME = CURRENT_ROLE() AND s.STORE_SK = store_sk)
--
-- SERVE.SLA_STORE_HOUR_AGG groups by STORE_CODE and never carries STORE_SK.
-- A POLICY DOES NOT FOLLOW A KEY CHANGE. The aggregate would have to carry a
-- surrogate key it has no other use for, purely so an existing policy could be
-- reused -- which is the tail wagging the dog. GOV.RAP_STORE_CODE reads the
-- same entitlement table with one fewer join.
--
-- That is the generalisable part: a derived object is keyed on what the
-- business asked for, and the protection has to be expressed in those terms
-- too. One policy per protected concept is the wrong unit; one policy per
-- protected concept PER KEY is closer.
--
-- DEFECT 3, AND WHY ALTER RATHER THAN CREATE OR REPLACE.
--
-- CREATE OR REPLACE VIEW drops and recreates, which drops the grants with it.
-- QC_ANALYST would lose access to all five views and the application would
-- break for that role with no error pointing back here. ALTER VIEW ... SET
-- SECURE changes the property in place and grants survive.
--
-- p12_policies.sql already argues the case, in its own comments, for the one
-- view it made secure: "a non-secure view can leak protected data through
-- error messages and through the optimizer's choice of filter order." It then
-- built five non-secure ones. The reasoning was written down and not applied.
--
-- TWO THINGS THIS MUST PROVE, NOT ASSUME.
--
--   Does the dynamic table still REFRESH with a policy attached to it? Part 12
--   established that a policy on the SOURCE forces FULL refresh. A policy on
--   the dynamic table ITSELF is a different question and UNVERIFIED. STEP 3
--   forces a refresh rather than waiting an hour to find out.
--
--   Does QC_ANALYST then read 3 stores through the aggregate instead of 8?
--   Verified by assuming the role. Part 8 established that reading a grant
--   proves nothing and Part 12 that reading what SHOW says is attached proves
--   nothing either.
--
-- ON ORDERING AND RE-RUNNABILITY. DROP ALL ROW ACCESS POLICIES comes before
-- ADD because ADD is refused when one is already attached, and a governance
-- script that runs once and then aborts is one nobody re-runs -- Part 12's
-- own conclusion. Whether that statement is valid on a DYNAMIC TABLE is
-- UNVERIFIED. It is placed first deliberately: if the syntax is wrong the file
-- aborts having changed nothing, which is the safe failure.
--
-- ON COST. One forced FULL refresh over 19,377 rows, two role switches, a
-- second warehouse resumed for the analyst's own test. ~0.03 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p13:serve_harden';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 0 — before. Both numbers are expected to read 8.
-- =============================================================================
SELECT 'BEFORE / ACCOUNTADMIN' AS WHEN_WHO,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.SLA_BY_STORE_HOUR) AS STORES_VIA_AGGREGATE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.ORDER_RISK)        AS STORES_VIA_VIEW;

USE ROLE QC_ANALYST;
USE WAREHOUSE WH_APP_XS;

SELECT 'BEFORE / QC_ANALYST' AS WHEN_WHO,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM QCOMMERCE.SERVE.SLA_BY_STORE_HOUR) AS STORES_VIA_AGGREGATE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM QCOMMERCE.SERVE.ORDER_RISK)        AS STORES_VIA_VIEW;

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — the policy, created fail-closed and altered into place.
--
-- The Part 12 pattern, and the reason for it: a policy created with its real
-- body is briefly attachable to a column before anyone has checked it. Created
-- returning FALSE, nothing is ever exposed by an object that attaches to it
-- between these two statements.
-- =============================================================================
CREATE ROW ACCESS POLICY IF NOT EXISTS GOV.RAP_STORE_CODE AS (store_code STRING)
RETURNS BOOLEAN -> FALSE
COMMENT = 'RAP_STORE keyed on the code a derived object carries. Same entitlement table, one fewer join';

ALTER ROW ACCESS POLICY GOV.RAP_STORE_CODE SET BODY ->
  CURRENT_ROLE() IN ('ACCOUNTADMIN', 'QC_ADMIN', 'QC_ENGINEER')
  OR EXISTS (
       SELECT 1
       FROM   GOV.ROLE_STORE_ENTITLEMENT e
       WHERE  e.ROLE_NAME  = CURRENT_ROLE()
         AND  e.STORE_CODE = store_code
     );

-- =============================================================================
-- STEP 2 — attach it to the materialised aggregate.
-- =============================================================================
ALTER DYNAMIC TABLE SERVE.SLA_STORE_HOUR_AGG DROP ALL ROW ACCESS POLICIES;

ALTER DYNAMIC TABLE SERVE.SLA_STORE_HOUR_AGG
  ADD ROW ACCESS POLICY GOV.RAP_STORE_CODE ON (STORE_CODE);

SELECT POLICY_NAME,
       REF_ENTITY_NAME      AS ATTACHED_TO,
       REF_ARG_COLUMN_NAMES AS ON_COLUMNS
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG',
           REF_ENTITY_DOMAIN => 'TABLE'));

-- =============================================================================
-- STEP 3 — does it still refresh with a policy on itself?
-- A policy on the SOURCE forced FULL refresh (Part 12). A policy on the table
-- ITSELF is a different question, and the last time this object surprised us it
-- served stale data for nineteen hours.
-- =============================================================================
ALTER DYNAMIC TABLE SERVE.SLA_STORE_HOUR_AGG REFRESH;

SELECT STATE,
       STATE_CODE,
       LEFT(COALESCE(STATE_MESSAGE, ''), 120) AS MESSAGE,
       REFRESH_ACTION,
       REFRESH_START_TIME
FROM   TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
           NAME => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG'))
ORDER  BY REFRESH_START_TIME DESC
LIMIT  3;

-- =============================================================================
-- STEP 4 — make the other five views secure, in place.
-- =============================================================================
ALTER VIEW SERVE.SLA_BY_STORE_HOUR SET SECURE;
ALTER VIEW SERVE.ORDER_RISK        SET SECURE;
ALTER VIEW SERVE.COMPLAINT_TRIAGE  SET SECURE;
ALTER VIEW SERVE.DATA_HEALTH       SET SECURE;
ALTER VIEW SERVE.MODEL_SCOREBOARD  SET SECURE;

SHOW VIEWS IN SCHEMA QCOMMERCE.SERVE;

SELECT "name" AS VIEW_NAME, "is_secure" AS IS_SECURE
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER  BY 2, 1;

-- =============================================================================
-- STEP 5 — after. The analyst should now read 3 both ways.
-- =============================================================================
SELECT 'AFTER / ACCOUNTADMIN' AS WHEN_WHO,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.SLA_BY_STORE_HOUR) AS STORES_VIA_AGGREGATE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.ORDER_RISK)        AS STORES_VIA_VIEW;

USE ROLE QC_ANALYST;
USE WAREHOUSE WH_APP_XS;

SELECT 'AFTER / QC_ANALYST' AS WHEN_WHO,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM QCOMMERCE.SERVE.SLA_BY_STORE_HOUR) AS STORES_VIA_AGGREGATE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM QCOMMERCE.SERVE.ORDER_RISK)        AS STORES_VIA_VIEW,
       (SELECT COUNT(*) FROM QCOMMERCE.SERVE.SLA_BY_STORE_HOUR)                   AS AGG_ROWS_SEEN;

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 6 — checks, and into OPS so they surface on the app's health tab.
-- Placed last: DETAIL is VARIANT and OBSERVED is NUMBER, and an insert that
-- argues with either costs nothing already printed.
-- =============================================================================
SELECT 'aggregate_carries_a_policy' AS CHECK_NAME,
       COUNT(*) = 1                 AS PASSED,
       COUNT(*)                     AS OBSERVED
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG',
           REF_ENTITY_DOMAIN => 'TABLE'));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'aggregate_carries_a_policy',
       'SERVE.SLA_STORE_HOUR_AGG',
       COUNT(*) = 1,
       COUNT(*),
       'exactly one row access policy on the materialised aggregate',
       TO_VARIANT('GOV.RAP_STORE_CODE on STORE_CODE. Without it the filter on '
                  || 'MART.FCT_ORDER does not reach anything computed from it')
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG',
           REF_ENTITY_DOMAIN => 'TABLE'));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'serve_views_are_secure',
       'QCOMMERCE.SERVE',
       COUNT(*) = 0,
       COUNT(*),
       'zero non-secure views in SERVE',
       TO_VARIANT('a non-secure view leaks its definition and can leak rows '
                  || 'through the optimizer filter order')
FROM   QCOMMERCE.INFORMATION_SCHEMA.VIEWS
WHERE  TABLE_SCHEMA = 'SERVE'
  AND  IS_SECURE = 'NO';

SELECT CHECK_NAME, TARGET, PASSED, OBSERVED, CHECK_TS
FROM   OPS.DQ_RESULTS
WHERE  CHECK_NAME IN ('aggregate_carries_a_policy', 'serve_views_are_secure')
ORDER  BY CHECK_TS DESC
LIMIT  4;

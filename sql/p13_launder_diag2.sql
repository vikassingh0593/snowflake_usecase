-- =============================================================================
-- PART 13 / STEP 1b — the four questions, minus the reserved word.
--
-- The last run aborted at
--
--   SELECT "name" AS STORED_OBJECT, "rows" AS ROWS, "kind" AS KIND
--   001003: syntax error line 1 at position 42 unexpected 'ROWS'
--
-- ROWS is reserved, and docs/PROGRESS.md already records it: "snow sql
-- reserved-word aliases hit twice: rows and check." A documented lesson,
-- repeated. scripts/sqllint.sh now catches it, along with a literal dollar pair
-- inside a dollar-quoted body, an unqualified DROP in a file that creates an
-- application package, and a double-escaped newline in a procedure body --
-- which is the other three things that have cost round trips in Part 13 alone.
-- Run it before running SQL.
--
-- WHAT THE PARTIAL RUN ALREADY SETTLED, AND IT WAS NOT ON THE LIST.
--
--   SELECT  TABLE   QCOMMERCE.MART.FCT_ORDER
--   SELECT  TABLE   QCOMMERCE.MART.DIM_CUSTOMER
--   USAGE   SCHEMA  QCOMMERCE.MART
--
-- QC_ANALYST HAS DIRECT SELECT ON MART BASE TABLES. docs/OVERVIEW.md §11 says
-- that role has "SERVE and SEMANTIC views only. No base-table access
-- anywhere." False since Part 8. The policies do protect those tables -- that
-- is why Part 12's role verification passed -- but the access statement is
-- wrong and a reader would draw the wrong conclusion about the blast radius.
--
-- Also settled: SERVE holds exactly two stored objects, ACTION_LOG at 1 row and
-- SLA_STORE_HOUR_AGG at 7,626 with is_dynamic = Y. Everything else is a view,
-- and QC_ANALYST has no grant on the dynamic table itself -- only on the view
-- above it. That narrows the fix: protecting SERVE.SLA_BY_STORE_HOUR is enough
-- for this role, and the question is whether it is enough in principle.
--
-- STILL OPEN, AND THIS FILE ANSWERS THEM.
--
--   1. What RAP_STORE's signature is. The aggregate is keyed on STORE_CODE and
--      the policy sits on FCT_ORDER.STORE_SK. If the signature takes a
--      surrogate key, reusing it on STORE_CODE is not possible and a second
--      policy has to exist -- which is its own finding about how policies scale.
--   2. Everywhere it is attached now.
--   3. The SERVE inventory split by stored versus derived, printed this time.
--   4. Whether a row access policy can attach to a DYNAMIC TABLE at all.
--
-- ON COST. Read-only apart from one throwaway dynamic table created and dropped
-- in LAB, TARGET_LAG = DOWNSTREAM so it never schedules itself. ~0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p13:launder_diag2';
USE DATABASE QCOMMERCE;

-- STEP 1 — the policy's signature and body.
DESCRIBE ROW ACCESS POLICY QCOMMERCE.GOV.RAP_STORE;

SELECT "name"        AS POLICY_NAME,
       "signature"   AS POLICY_SIGNATURE,
       "return_type" AS RETURNS,
       "body"        AS POLICY_BODY
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- STEP 2 — everywhere it is attached, and to which column.
SELECT POLICY_NAME,
       REF_ENTITY_NAME   AS ATTACHED_TO,
       REF_ENTITY_DOMAIN AS OBJECT_KIND,
       REF_ARG_COLUMN_NAMES AS ON_COLUMNS
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           POLICY_NAME => 'QCOMMERCE.GOV.RAP_STORE'))
ORDER  BY 2;

-- STEP 3 — SERVE, split by whether the rows are stored or recomputed.
-- A view inherits whatever protects its sources because it reads them at query
-- time. A stored object holds rows computed once, under whoever built them, and
-- no later reader's role can change what is already written.
SHOW DYNAMIC TABLES IN SCHEMA QCOMMERCE.SERVE;

SELECT "name"         AS DT_NAME,
       "rows"         AS N_ROWS,
       "refresh_mode" AS REFRESH,
       "warehouse"    AS BUILT_ON,
       "owner"        AS BUILT_BY
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW VIEWS IN SCHEMA QCOMMERCE.SERVE;

SELECT "name"      AS VIEW_NAME,
       "is_secure" AS IS_SECURE
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER  BY 1;

-- STEP 4 — can a row access policy attach to a dynamic table?
-- Decisive: it is the difference between protecting the object and protecting
-- the view over it. Attempted on a throwaway rather than on the aggregate the
-- application reads, because a failed ALTER on that object is not a test.
-- Placed last so a refusal costs nothing already printed.
CREATE OR REPLACE DYNAMIC TABLE QCOMMERCE.LAB.TMP_RAP_TARGET
  TARGET_LAG   = 'DOWNSTREAM'
  WAREHOUSE    = WH_TRANSFORM_XS
  REFRESH_MODE = FULL
AS SELECT s.STORE_CODE, o.STORE_SK, COUNT(*) AS N_ORDERS
   FROM   QCOMMERCE.MART.FCT_ORDER o
   JOIN   QCOMMERCE.MART.DIM_STORE s ON s.STORE_SK = o.STORE_SK
   GROUP  BY s.STORE_CODE, o.STORE_SK;

-- STORE_SK, not STORE_CODE: the policy is attached to FCT_ORDER.STORE_SK, so
-- its signature almost certainly takes that type. The column is carried in the
-- throwaway for exactly this reason. If STEP 1 shows a VARCHAR signature this
-- statement is the wrong one and the file says so rather than the reverse.
ALTER DYNAMIC TABLE QCOMMERCE.LAB.TMP_RAP_TARGET
  ADD ROW ACCESS POLICY QCOMMERCE.GOV.RAP_STORE ON (STORE_SK);

SELECT 'rap_attaches_to_dynamic_table'     AS CHECK_NAME,
       COUNT(*) > 0                        AS PASSED,
       COUNT(*)::STRING || ' reference(s)' AS DETAIL
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.LAB.TMP_RAP_TARGET',
           REF_ENTITY_DOMAIN => 'TABLE'));

DROP DYNAMIC TABLE IF EXISTS QCOMMERCE.LAB.TMP_RAP_TARGET;

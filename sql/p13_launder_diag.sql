-- =============================================================================
-- PART 13 / STEP 1 — measure the laundering before fixing it.
--
-- CONFIRMED 2026-09-14, by assuming the role rather than reading a grant:
--
--   role           STORES_VIA_AGGREGATE   STORES_VIA_VIEW   ROWS_VIA_VIEW
--   ACCOUNTADMIN            8                   8               4,777
--   QC_ANALYST              8                   3               1,977
--
-- The view path filters exactly as Part 12 certified. The materialised path
-- does not filter at all. QC_ANALYST has seen every store's SLA performance
-- through SERVE.SLA_BY_STORE_HOUR since Part 11, and the application's
-- Operations tab reads that view.
--
-- §12 states the principle as "a policy attached at the base travels every
-- path". That is measurably false. The true statement is narrower:
--
--   A POLICY TRAVELS EVERY PATH THAT READS THE BASE AT QUERY TIME.
--
-- Materialisation computes under the builder's visibility, writes the result
-- down, and the filter never runs again. SERVE.SLA_STORE_HOUR_AGG is a dynamic
-- table refreshed by ACCOUNTADMIN; its stored rows cover all eight stores, and
-- no later reader's role can change what is already written.
--
-- WHY THIS FILE DIAGNOSES RATHER THAN FIXES.
--
-- Four things about the current state are unknown, and every one of them
-- changes which fix is correct. This project has lost several rounds to
-- inventing an object name, a method name and a column name, so none of them
-- is going to be guessed here.
--
--   1. What GOV.RAP_STORE's body actually is. The aggregate is keyed on
--      STORE_CODE; the policy is attached to FCT_ORDER.STORE_SK. Whether the
--      same policy can be reused depends on its signature and on how it maps
--      roles to stores.
--   2. What QC_ANALYST is actually granted. If it holds SELECT on the dynamic
--      table itself, protecting only the view above it fixes nothing.
--   3. Whether a row access policy can be attached to a DYNAMIC TABLE at all.
--      UNVERIFIED, and it is the difference between fixing the object and
--      fixing the view over it.
--   4. Which other objects are materialised from policy-protected sources and
--      have the same hole. LAB is full of tables built from MART. LAB is
--      ungoverned by design and nothing downstream reads it, but SERVE is the
--      contract and anything materialised there is suspect by the same
--      argument.
--
-- ON COST. Read-only. Metadata plus a handful of counts. ~0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p13:launder_diag';
USE DATABASE QCOMMERCE;

-- STEP 1 — what the policy actually says, and where it is attached.
SHOW ROW ACCESS POLICIES IN SCHEMA QCOMMERCE.GOV;

SELECT "name" AS POLICY, "owner" AS OWNER, "options" AS OPTIONS
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

DESCRIBE ROW ACCESS POLICY QCOMMERCE.GOV.RAP_STORE;

-- Everywhere it is attached, and to which column.
SELECT POLICY_NAME,
       REF_ENTITY_NAME,
       REF_ENTITY_DOMAIN,
       REF_ARG_COLUMN_NAMES,
       REF_DATABASE_NAME || '.' || REF_SCHEMA_NAME AS REF_SCHEMA
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           POLICY_NAME => 'QCOMMERCE.GOV.RAP_STORE'))
ORDER  BY REF_ENTITY_NAME;

-- STEP 2 — what QC_ANALYST can actually reach.
-- If it holds SELECT on the dynamic table itself then protecting only the view
-- above it fixes nothing, because the table is reachable directly.
SHOW GRANTS TO ROLE QC_ANALYST;

SELECT "privilege"    AS PRIV,
       "granted_on"   AS ON_TYPE,
       "name"         AS OBJECT
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE  "granted_on" IN ('TABLE', 'VIEW', 'MATERIALIZED_VIEW', 'DYNAMIC_TABLE', 'SCHEMA')
ORDER  BY 2, 3;

-- STEP 3 — everything in SERVE, and which of it is stored rather than derived.
-- A view recomputes on read and inherits whatever protects its sources. A table
-- or a dynamic table holds rows computed once, under whoever built them. The
-- second kind is the exposed kind, and this is the inventory of it.
SHOW TABLES IN SCHEMA QCOMMERCE.SERVE;

SELECT "name" AS STORED_OBJECT, "rows" AS N_ROWS, "kind" AS OBJ_KIND
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER  BY 1;

SHOW DYNAMIC TABLES IN SCHEMA QCOMMERCE.SERVE;

SELECT "name" AS DYNAMIC_TABLE, "rows" AS N_ROWS, "refresh_mode" AS REFRESH
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER  BY 1;

SHOW VIEWS IN SCHEMA QCOMMERCE.SERVE;

SELECT "name" AS VIEW_NAME, "is_secure" AS IS_SECURE
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER  BY 1;

-- STEP 4 — can a row access policy be attached to a dynamic table at all?
-- UNVERIFIED and decisive: it is the difference between protecting the object
-- and protecting the view over it. Attempted on a throwaway rather than on
-- SERVE, because a failed ALTER on the real aggregate during business hours is
-- not a test, it is an incident. Placed last: if the CREATE is refused the file
-- has already printed everything above.
CREATE OR REPLACE DYNAMIC TABLE QCOMMERCE.LAB.TMP_RAP_TARGET
  TARGET_LAG = 'DOWNSTREAM'
  WAREHOUSE = WH_TRANSFORM_XS
  REFRESH_MODE = FULL
AS SELECT s.STORE_CODE, COUNT(*) AS N
   FROM   QCOMMERCE.MART.FCT_ORDER o
   JOIN   QCOMMERCE.MART.DIM_STORE s ON s.STORE_SK = o.STORE_SK
   GROUP  BY s.STORE_CODE;

ALTER DYNAMIC TABLE QCOMMERCE.LAB.TMP_RAP_TARGET
  ADD ROW ACCESS POLICY QCOMMERCE.GOV.RAP_STORE ON (STORE_CODE);

SELECT 'rap_attached_to_dynamic_table' AS CHECK_NAME,
       COUNT(*) > 0                    AS PASSED,
       COUNT(*)::STRING || ' reference(s)' AS DETAIL
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.LAB.TMP_RAP_TARGET',
           REF_ENTITY_DOMAIN => 'TABLE'));

DROP DYNAMIC TABLE IF EXISTS QCOMMERCE.LAB.TMP_RAP_TARGET;

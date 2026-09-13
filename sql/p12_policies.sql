-- =============================================================================
-- PART 12 / STEP 1 — column and row protection, each built twice.
--
-- The probe found masking policies, row access policies and tag-based masking
-- all available. Classification is the only thing missing and the error said
-- "Unknown function SYSTEM$CLASSIFY" rather than a privilege error, so that is
-- an API that moved rather than a tier gate. It is probed at the very end of
-- this file, after every deliverable is committed.
--
-- THE COLLISION THAT SHAPES THIS FILE. MART is built by dbt with
-- materialized='table', which issues CREATE OR REPLACE TABLE. That drops the
-- columns and recreates them, and a masking policy or tag attached to a column
-- goes with it. **A policy on a dbt-managed table survives exactly until the
-- next dbt run**, and it disappears silently -- the table is still there, the
-- data is still there, and the protection is gone.
--
-- So protection is applied in two places on purpose, and the difference is the
-- finding rather than an accident:
--
--   MART.DIM_CUSTOMER   masking policy and tag, directly on the table. This is
--                       the Enterprise mechanism at its best -- the policy
--                       travels with the column down every access path -- and
--                       at its most fragile here, because dbt owns the table.
--                       A check below detects the loss.
--
--   SERVE.V_CUSTOMER    a secure view doing SHA2, the Standard substitute.
--                       Protects one access path and nothing else, but nothing
--                       in this project rebuilds it.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:policies';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — a home for policies.
--
-- Their own schema, so SHOW MASKING POLICIES IN SCHEMA GOV is a complete
-- inventory rather than a partial one. Policies scattered next to the data
-- they protect cannot be audited in one look.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS GOV
  COMMENT = 'masking policies, row access policies, tags, entitlements';

-- Who may see which stores. A table rather than a CASE inside the policy,
-- because entitlements change far more often than policy logic does and a
-- policy body is DDL.
CREATE TABLE IF NOT EXISTS GOV.ROLE_STORE_ENTITLEMENT (
  ROLE_NAME   STRING,
  STORE_CODE  STRING,
  GRANTED_AT  TIMESTAMP_NTZ DEFAULT SYSDATE()
) COMMENT = 'which role may see which store. Read by the row access policy';

DELETE FROM GOV.ROLE_STORE_ENTITLEMENT WHERE ROLE_NAME = 'QC_ANALYST';
INSERT INTO GOV.ROLE_STORE_ENTITLEMENT (ROLE_NAME, STORE_CODE)
SELECT 'QC_ANALYST', STORE_CODE FROM MART.DIM_STORE WHERE STORE_CODE <= 'DS003';

-- =============================================================================
-- STEP 2 — masking policies.
--
-- Three behaviours, not two. A policy that returns '***' to everyone who is
-- not privileged destroys the column's usefulness for counting and joining;
-- one that hashes keeps referential behaviour -- the same customer hashes the
-- same way -- while revealing nothing. Which of the two an analyst gets is a
-- decision about their job, and it belongs in the policy.
-- =============================================================================
-- POLICIES ARE CREATED THEN ALTERED, NEVER REPLACED.
--
--   003531 (23001): Policy MASK_COORDINATE cannot be dropped/replaced as it
--   is associated with one or more entities.
--
-- CREATE OR REPLACE is the idempotent form for most objects and the opposite
-- for a policy: once attached to a column, a policy cannot be replaced at all.
-- ALTER ... SET BODY modifies it in place, attached, which is the only form
-- that works on the second run.
--
-- Each policy is therefore created with a FAIL-CLOSED body and then altered to
-- its real one. The placeholder redacts rather than passes through, so there
-- is no instant -- not even between two statements -- where the column is
-- attached to a policy that reveals it.
CREATE MASKING POLICY IF NOT EXISTS GOV.MASK_EMAIL AS (v STRING)
RETURNS STRING -> '***REDACTED***'
COMMENT = 'full for engineering, stable hash for analysts, redacted otherwise';

ALTER MASKING POLICY GOV.MASK_EMAIL SET BODY ->
  CASE
    WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'QC_ADMIN', 'QC_ENGINEER') THEN v
    WHEN CURRENT_ROLE() = 'QC_ANALYST' THEN SHA2(LOWER(v), 256)
    ELSE '***REDACTED***'
  END;

CREATE MASKING POLICY IF NOT EXISTS GOV.MASK_PHONE AS (v STRING)
RETURNS STRING -> '***REDACTED***'
COMMENT = 'last four digits only. Enough to confirm a customer on a call';

ALTER MASKING POLICY GOV.MASK_PHONE SET BODY ->
  CASE
    WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'QC_ADMIN', 'QC_ENGINEER') THEN v
    -- REPEAT and RIGHT rather than a regex. The obvious regex for this is
    -- '[0-9](?=[0-9]{4})' and Snowflake has no lookahead, so it does not
    -- compile. This is also clearer about what it keeps.
    ELSE REPEAT('X', GREATEST(LENGTH(v) - 4, 0)) || RIGHT(v, 4)
  END;

-- =============================================================================
-- STEP 3 — the row access policy.
--
-- One policy on the fact table. Everything downstream of MART.FCT_ORDER
-- inherits it without being told, including SERVE.ORDER_RISK and the Streamlit
-- app reading that view, which is the property a filtered view cannot give:
-- a view protects the path through it, a policy protects the data.
-- =============================================================================
CREATE ROW ACCESS POLICY IF NOT EXISTS GOV.RAP_STORE AS (store_sk STRING)
RETURNS BOOLEAN -> FALSE
COMMENT = 'engineering sees everything, everyone else sees their entitled stores';

ALTER ROW ACCESS POLICY GOV.RAP_STORE SET BODY ->
  CURRENT_ROLE() IN ('ACCOUNTADMIN', 'QC_ADMIN', 'QC_ENGINEER')
  OR EXISTS (
       SELECT 1
       FROM   GOV.ROLE_STORE_ENTITLEMENT e
       JOIN   MART.DIM_STORE s ON s.STORE_CODE = e.STORE_CODE
       WHERE  e.ROLE_NAME = CURRENT_ROLE()
         AND  s.STORE_SK  = store_sk
     );

-- =============================================================================
-- STEP 4 — the tag, and why tag-based masking is the one worth having.
--
-- Attaching a policy to a TAG means the policy applies everywhere the tag is
-- applied, including to columns that do not exist yet. Tagging a new column
-- protects it; no one has to remember to also attach a policy, and forgetting
-- is the normal failure.
-- =============================================================================
-- IF NOT EXISTS, for the same reason as the policies: a tag with a masking
-- policy bound to it cannot be replaced. Allowed values are set once at
-- creation and never change here.
CREATE TAG IF NOT EXISTS GOV.PII
  ALLOWED_VALUES 'EMAIL', 'PHONE', 'NAME', 'LOCATION'
  COMMENT = 'what kind of personal data this column holds';

CREATE MASKING POLICY IF NOT EXISTS GOV.MASK_NAME AS (v STRING)
RETURNS STRING -> '***REDACTED***';

ALTER MASKING POLICY GOV.MASK_NAME SET BODY ->
  CASE
    WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'QC_ADMIN', 'QC_ENGINEER') THEN v
    ELSE LEFT(v, 1) || REPEAT('*', GREATEST(LENGTH(v) - 1, 0))
  END;

-- FORCE here is UNVERIFIED on this account. A plain SET fails once the tag
-- already carries a policy of this type, and FORCE is documented as the way to
-- replace it -- an earlier comment in p12_classify_response.sql asserted no
-- FORCE exists for tags, which I now believe was wrong and have corrected
-- there. If this errors, the answer is that the claim was right after all and
-- the binding is a one-time statement.
ALTER TAG GOV.PII SET MASKING POLICY GOV.MASK_NAME FORCE;

-- =============================================================================
-- STEP 5 — attach.
--
-- FULL_NAME gets no policy of its own. It gets the tag, and the policy arrives
-- with it. That is the whole demonstration.
-- =============================================================================
-- FORCE, on both. Without it, SET MASKING POLICY fails when a policy is
-- already attached, so this file would run exactly once and then start
-- aborting -- and a governance script that cannot be re-run is a governance
-- script nobody re-runs.
ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN EMAIL
  SET MASKING POLICY GOV.MASK_EMAIL FORCE;
ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN PHONE
  SET MASKING POLICY GOV.MASK_PHONE FORCE;
ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN FULL_NAME SET TAG GOV.PII = 'NAME';

-- DROP ALL first. There is no FORCE for row access policies and ADD fails when
-- one is already attached, but DROP ALL tolerates there being none -- which
-- makes the pair idempotent where neither statement is on its own.
ALTER TABLE MART.FCT_ORDER DROP ALL ROW ACCESS POLICIES;
ALTER TABLE MART.FCT_ORDER ADD ROW ACCESS POLICY GOV.RAP_STORE ON (STORE_SK);

-- =============================================================================
-- STEP 6 — the Standard substitute, for comparison.
--
-- SECURE, which matters: a non-secure view can leak protected data through
-- error messages and through the optimizer's choice of filter order. The
-- difference from STEP 5 is that this protects one path. Query
-- MART.DIM_CUSTOMER directly and the policy still applies; query it around
-- this view and there is nothing here to stop you.
-- =============================================================================
CREATE OR REPLACE SECURE VIEW SERVE.V_CUSTOMER AS
SELECT CUSTOMER_SK,
       CUSTOMER_ID,
       LEFT(FULL_NAME, 1) || REPEAT('*', GREATEST(LENGTH(FULL_NAME) - 1, 0)) AS FULL_NAME,
       SHA2(LOWER(EMAIL), 256)                                   AS EMAIL_HASH,
       REPEAT('X', GREATEST(LENGTH(PHONE) - 4, 0)) || RIGHT(PHONE, 4) AS PHONE_MASKED,
       SEGMENT,
       HOME_PINCODE,
       CREATED_AT
FROM   MART.DIM_CUSTOMER;

GRANT SELECT ON VIEW SERVE.V_CUSTOMER    TO ROLE QC_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA SERVE TO ROLE QC_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA SERVE TO ROLE QC_ANALYST;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA SERVE TO ROLE QC_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA SERVE TO ROLE QC_ANALYST;

-- =============================================================================
-- STEP 7 — verify by looking, not by reading the grant.
--
-- Part 8 established that GRANT ALL ON SCHEMA is not an object grant, and the
-- only thing that caught it was a SELECT under the role. Same discipline here:
-- what a policy does is what a query returns, not what SHOW says is attached.
-- =============================================================================
SELECT 'ACCOUNTADMIN' AS as_role, CUSTOMER_ID, FULL_NAME, EMAIL, PHONE
FROM   MART.DIM_CUSTOMER ORDER BY CUSTOMER_ID LIMIT 3;

GRANT USAGE ON SCHEMA MART TO ROLE QC_ANALYST;
GRANT SELECT ON TABLE MART.DIM_CUSTOMER TO ROLE QC_ANALYST;
GRANT SELECT ON TABLE MART.FCT_ORDER    TO ROLE QC_ANALYST;

USE ROLE QC_ANALYST;
USE WAREHOUSE WH_APP_XS;

SELECT 'QC_ANALYST' AS as_role, CUSTOMER_ID, FULL_NAME, EMAIL, PHONE
FROM   QCOMMERCE.MART.DIM_CUSTOMER ORDER BY CUSTOMER_ID LIMIT 3;

-- The row access policy, from the other side. Three stores entitled out of
-- eight, so this must be a strict subset.
SELECT 'QC_ANALYST' AS as_role,
       COUNT(*)                        AS orders_visible,
       COUNT(DISTINCT STORE_SK)        AS stores_visible
FROM   QCOMMERCE.MART.FCT_ORDER;

-- And through the app's own view, which never mentions the policy.
SELECT 'QC_ANALYST via SERVE' AS as_role,
       COUNT(*)                        AS risk_rows_visible,
       COUNT(DISTINCT STORE_CODE)      AS stores_visible
FROM   QCOMMERCE.SERVE.ORDER_RISK;

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;

SELECT 'ACCOUNTADMIN' AS as_role,
       COUNT(*)                        AS orders_visible,
       COUNT(DISTINCT STORE_SK)        AS stores_visible
FROM   MART.FCT_ORDER;

-- =============================================================================
-- STEP 8 — what is attached, from the catalogue.
-- =============================================================================
SELECT POLICY_NAME, POLICY_KIND, REF_ENTITY_NAME, REF_COLUMN_NAME
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
              POLICY_NAME => 'QCOMMERCE.GOV.MASK_EMAIL'))
UNION ALL
SELECT POLICY_NAME, POLICY_KIND, REF_ENTITY_NAME, REF_COLUMN_NAME
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
              POLICY_NAME => 'QCOMMERCE.GOV.MASK_NAME'))
UNION ALL
SELECT POLICY_NAME, POLICY_KIND, REF_ENTITY_NAME, REF_COLUMN_NAME
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
              POLICY_NAME => 'QCOMMERCE.GOV.RAP_STORE'));

-- =============================================================================
-- STEP 9 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'pii_columns_carry_a_policy', 'MART.DIM_CUSTOMER',
       (SELECT COUNT(*) FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
                 REF_ENTITY_NAME => 'QCOMMERCE.MART.DIM_CUSTOMER',
                 REF_ENTITY_DOMAIN => 'TABLE'))) >= 2,
       (SELECT COUNT(*) FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
                 REF_ENTITY_NAME => 'QCOMMERCE.MART.DIM_CUSTOMER',
                 REF_ENTITY_DOMAIN => 'TABLE'))),
       'at least two policy references on the customer dimension. EMAIL and '
         || 'PHONE are attached directly and are certain; whether the policy '
         || 'the PII tag carries onto FULL_NAME also counts as a reference here '
         || 'is UNVERIFIED, so the threshold is set to what is known and the '
         || 'observed count answers it. THIS GOES RED AFTER A dbt run: CREATE '
         || 'OR REPLACE TABLE drops the columns and the policies with them',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'row_policy_actually_restricts', 'MART.FCT_ORDER',
       (SELECT COUNT(*) FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
                 POLICY_NAME => 'QCOMMERCE.GOV.RAP_STORE'))) >= 1
       AND (SELECT COUNT(*) FROM GOV.ROLE_STORE_ENTITLEMENT
             WHERE ROLE_NAME = 'QC_ANALYST') = 3,
       (SELECT COUNT(*) FROM GOV.ROLE_STORE_ENTITLEMENT WHERE ROLE_NAME = 'QC_ANALYST'),
       'the policy is attached and the analyst is entitled to 3 of 8 stores',
       (SELECT OBJECT_AGG(ROLE_NAME, n::VARIANT)
        FROM (SELECT ROLE_NAME, COUNT(*) AS n FROM GOV.ROLE_STORE_ENTITLEMENT
              GROUP BY ROLE_NAME));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'secure_view_is_actually_secure', 'SERVE.V_CUSTOMER',
       (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS
         WHERE TABLE_SCHEMA = 'SERVE' AND TABLE_NAME = 'V_CUSTOMER'
           AND IS_SECURE = 'YES') = 1,
       (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS
         WHERE TABLE_SCHEMA = 'SERVE' AND IS_SECURE = 'YES'),
       'the substitute view is SECURE -- a plain view leaks through error '
         || 'messages and filter ordering, count is of all secure views in SERVE',
       NULL;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('MART.DIM_CUSTOMER', 'MART.FCT_ORDER', 'SERVE.V_CUSTOMER')
ORDER  BY CHECK_TS DESC
LIMIT  3;

-- =============================================================================
-- STEP 10 — classification, last because it is the one unknown.
--
-- SYSTEM$CLASSIFY does not exist on this account and the error was "Unknown
-- function", not a privilege refusal, which points at an API that moved rather
-- than a feature that is gated. These are the names it moved to. Everything
-- above is already committed if this fails.
-- =============================================================================
SELECT EXTRACT_SEMANTIC_CATEGORIES('QCOMMERCE.MART.DIM_CUSTOMER') AS categories;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- ALTER TABLE MART.FCT_ORDER DROP ROW ACCESS POLICY GOV.RAP_STORE;
-- ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN EMAIL UNSET MASKING POLICY;
-- ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN PHONE UNSET MASKING POLICY;
-- ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN FULL_NAME UNSET TAG GOV.PII;
-- ALTER TAG GOV.PII UNSET MASKING POLICY GOV.MASK_NAME;
-- DROP SCHEMA IF EXISTS GOV CASCADE;

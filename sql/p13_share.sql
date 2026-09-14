-- =============================================================================
-- PART 13 / STEP 3 — the outbound share, and the pattern that makes it work.
--
-- THE PROBLEM THE HARDENING CREATED. GOV.RAP_STORE and GOV.RAP_STORE_CODE both
-- filter on CURRENT_ROLE() against GOV.ROLE_STORE_ENTITLEMENT. In a CONSUMER
-- account there is no QC_ANALYST and no entitlement row, so every path from
-- MART.FCT_ORDER now returns zero rows to a consumer. Before this morning the
-- same paths returned all eight stores. The fix moved the sharing failure from
-- silently too much to silently nothing, and neither end raises an error.
--
-- A POLICY WRITTEN IN TERMS OF ROLES CANNOT CROSS AN ACCOUNT BOUNDARY. The
-- consumer's identity is not a role, it is an account, so the filter has to be
-- expressed as CURRENT_ACCOUNT().
--
-- AND THE OBJECT HAS TO BE MATERIALISED, WHICH IS THE PART WORTH NOTICING.
--
-- A view over the aggregate inherits RAP_STORE_CODE and dies in the consumer's
-- account regardless of what else is attached. Two row access policies cannot
-- sit on the same column of the same object. So the shared object must be a
-- TABLE, built by a role the role-policy exempts, carrying only the
-- account-keyed policy.
--
-- That is exactly the laundering this project spent the morning calling a bug:
-- materialisation computes under the builder's visibility and strips the row
-- filter. Here it is the correct tool, because stripping a filter keyed on
-- something meaningless outside the account is the point, and a filter keyed
-- on the consumer replaces it.
--
--   THE SAME MECHANISM IS A DEFECT INTERNALLY AND THE MECHANISM EXTERNALLY.
--   What changes is whether anything re-applies protection afterwards.
--
-- WHAT IS DELIBERATELY NOT HERE. No reader account. CREATE MANAGED ACCOUNT
-- spawns a billable child account and is very likely gated on a trial anyway;
-- the capability is recorded as skipped by choice rather than blocked. What
-- that leaves unverified is narrow and written down in STEP 5 as a prediction.
--
-- ON COST. One table of roughly 480 rows built from the 7,626-row aggregate,
-- plus metadata. ~0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p13:share';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — who may see what, keyed on the account rather than the role.
-- =============================================================================
CREATE TABLE IF NOT EXISTS GOV.ACCOUNT_STORE_ENTITLEMENT (
  ACCOUNT_LOCATOR STRING,
  STORE_CODE      STRING,
  GRANTED_AT      TIMESTAMP_NTZ DEFAULT SYSDATE()
) COMMENT = 'consumer account to store. The share-side twin of ROLE_STORE_ENTITLEMENT';

CREATE ROW ACCESS POLICY IF NOT EXISTS GOV.RAP_SHARE_ACCOUNT AS (store_code STRING)
RETURNS BOOLEAN -> FALSE
COMMENT = 'fail closed. An account not listed sees nothing, including this one';

ALTER ROW ACCESS POLICY GOV.RAP_SHARE_ACCOUNT SET BODY ->
  EXISTS (
    SELECT 1
    FROM   GOV.ACCOUNT_STORE_ENTITLEMENT e
    WHERE  e.ACCOUNT_LOCATOR = CURRENT_ACCOUNT()
      AND  e.STORE_CODE      = store_code
  );

-- =============================================================================
-- STEP 2 — the shared object. Day grain, no PII, no role-keyed policy.
--
-- Built as ACCOUNTADMIN, which RAP_STORE_CODE exempts, so all eight stores land
-- in the table. RAP_SHARE_ACCOUNT then decides who sees which of them.
-- =============================================================================
CREATE OR REPLACE TABLE SERVE.SHR_SLA_DAILY
COMMENT = 'outbound. Rebuilt from SERVE.SLA_STORE_HOUR_AGG. Protected by GOV.RAP_SHARE_ACCOUNT'
AS
SELECT STORE_CODE,
       CITY,
       PLACED_DATE,
       SUM(ORDERS)                                              AS ORDERS,
       SUM(BREACHED)                                            AS BREACHED,
       ROUND(100.0 * SUM(BREACHED) / NULLIF(SUM(ORDERS), 0), 2) AS BREACH_PCT,
       ROUND(SUM(DELIVERED_SEC) / NULLIF(SUM(DELIVERED_N), 0) / 60.0, 1) AS AVG_ACTUAL_MIN
FROM   SERVE.SLA_STORE_HOUR_AGG
GROUP  BY STORE_CODE, CITY, PLACED_DATE;

ALTER TABLE SERVE.SHR_SLA_DAILY DROP ALL ROW ACCESS POLICIES;

ALTER TABLE SERVE.SHR_SLA_DAILY
  ADD ROW ACCESS POLICY GOV.RAP_SHARE_ACCOUNT ON (STORE_CODE);

-- A secure view is what actually goes into the share. The table stays private:
-- a share carrying the table would expose its column list and, with
-- SECURE_OBJECTS_ONLY off, more than that.
CREATE OR REPLACE SECURE VIEW SERVE.SHR_V_SLA_DAILY
COMMENT = 'the only object in SHR_QC_ANALYTICS'
AS SELECT STORE_CODE, CITY, PLACED_DATE, ORDERS, BREACHED, BREACH_PCT, AVG_ACTUAL_MIN
   FROM   SERVE.SHR_SLA_DAILY;

-- =============================================================================
-- STEP 3 — the share.
-- =============================================================================
CREATE SHARE IF NOT EXISTS SHR_QC_ANALYTICS
  COMMENT = 'daily SLA by store. Rows filtered by consumer account';

GRANT USAGE  ON DATABASE QCOMMERCE                TO SHARE SHR_QC_ANALYTICS;
GRANT USAGE  ON SCHEMA   QCOMMERCE.SERVE          TO SHARE SHR_QC_ANALYTICS;
GRANT SELECT ON VIEW     SERVE.SHR_V_SLA_DAILY    TO SHARE SHR_QC_ANALYTICS;

SHOW GRANTS TO SHARE SHR_QC_ANALYTICS;

-- =============================================================================
-- STEP 4 — verify the filter discriminates by account, locally.
--
-- No consumer is needed to prove the logic. This account's own locator goes in
-- and out of the entitlement table, and the row count follows it. Three states,
-- measured rather than argued.
-- =============================================================================
-- Idempotent: a re-run starts from no entitlement for this account.
DELETE FROM GOV.ACCOUNT_STORE_ENTITLEMENT WHERE ACCOUNT_LOCATOR = CURRENT_ACCOUNT();

SELECT 'A. no entitlement rows at all' AS STATE,
       (SELECT COUNT(*) FROM SERVE.SHR_V_SLA_DAILY)                   AS ROWS_VISIBLE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.SHR_V_SLA_DAILY) AS STORES_VISIBLE,
       CURRENT_ACCOUNT()                                              AS THIS_ACCOUNT;

-- MART.DIM_STORE, not SERVE.SHR_SLA_DAILY.
--
-- THE FIRST RUN INSERTED ZERO ROWS AND THE REASON IS WORTH KEEPING. The
-- original statement read the store codes from SHR_SLA_DAILY, which already
-- carries RAP_SHARE_ACCOUNT. With the entitlement table empty the policy
-- returned FALSE for every row, the subquery saw nothing, and nothing was
-- inserted -- so states B and C measured the same thing as state A and proved
-- nothing.
--
--   A FAIL-CLOSED POLICY MAKES ITS OWN TABLE USELESS AS A SOURCE FOR THE
--   ENTITLEMENT DATA THAT WOULD OPEN IT.
--
-- The deadlock is not specific to sharing. Any fail-closed control whose
-- configuration is derived from the thing it controls has it, and the fix is
-- always the same: seed the entitlement from an object outside the policy's
-- reach. MART.DIM_STORE carries no policy at all.
INSERT INTO GOV.ACCOUNT_STORE_ENTITLEMENT (ACCOUNT_LOCATOR, STORE_CODE)
SELECT CURRENT_ACCOUNT(), STORE_CODE
FROM  (SELECT STORE_CODE FROM MART.DIM_STORE ORDER BY STORE_CODE LIMIT 2);

SELECT 'B. this account entitled to 2 stores' AS STATE,
       (SELECT COUNT(*) FROM SERVE.SHR_V_SLA_DAILY)                   AS ROWS_VISIBLE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.SHR_V_SLA_DAILY) AS STORES_VISIBLE,
       CURRENT_ACCOUNT()                                              AS THIS_ACCOUNT;

DELETE FROM GOV.ACCOUNT_STORE_ENTITLEMENT WHERE ACCOUNT_LOCATOR = CURRENT_ACCOUNT();

SELECT 'C. entitlement withdrawn' AS STATE,
       (SELECT COUNT(*) FROM SERVE.SHR_V_SLA_DAILY)                   AS ROWS_VISIBLE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.SHR_V_SLA_DAILY) AS STORES_VISIBLE,
       CURRENT_ACCOUNT()                                              AS THIS_ACCOUNT;

-- =============================================================================
-- STEP 5 — what a consumer would see, written down rather than measured.
--
-- UNVERIFIED, and it stays that way because no reader account was created:
--
--   a consumer whose locator is absent from GOV.ACCOUNT_STORE_ENTITLEMENT
--   receives the share, sees the view, and reads zero rows with no error
--   raised on either side -- state A above, from the other end.
--
-- State A is that behaviour measured in this account, which is the closest
-- evidence available without a second one. What remains untested is the share
-- pipe itself: whether the view arrives, and whether an empty result surfaces
-- as an empty table or as something a consumer would misread.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'share_carries_only_secure_objects',
       'SHR_QC_ANALYTICS',
       COUNT(*) = 0,
       COUNT(*),
       'zero non-secure views reachable through the share',
       TO_VARIANT('SERVE.SHR_V_SLA_DAILY is secure and the table beneath it is not shared')
FROM   QCOMMERCE.INFORMATION_SCHEMA.VIEWS
WHERE  TABLE_SCHEMA = 'SERVE' AND TABLE_NAME = 'SHR_V_SLA_DAILY' AND IS_SECURE = 'NO';

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'shared_table_fails_closed',
       'SERVE.SHR_SLA_DAILY',
       COUNT(*) = 1,
       COUNT(*),
       'one account-keyed row access policy on the shared table',
       TO_VARIANT('GOV.RAP_SHARE_ACCOUNT on STORE_CODE. An account not listed reads nothing')
FROM   TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
           REF_ENTITY_NAME   => 'QCOMMERCE.SERVE.SHR_SLA_DAILY',
           REF_ENTITY_DOMAIN => 'TABLE'));

SELECT CHECK_NAME, TARGET, PASSED, OBSERVED
FROM   OPS.DQ_RESULTS
WHERE  CHECK_NAME IN ('share_carries_only_secure_objects', 'shared_table_fails_closed')
QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_NAME ORDER BY CHECK_TS DESC) = 1;

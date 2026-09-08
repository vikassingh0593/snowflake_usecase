-- sql/p0_probe2.sql — PART 0 FOLLOW-UP. Two open questions from probe 1.
-- READ-ONLY. Creates nothing, alters nothing, drops nothing.
-- Cost: negligible, no Cortex calls. Reuses whatever warehouse is already up.
--
-- Q1  What edition is this account, and how long does the trial actually last?
-- Q2  Are AI_AGG / AI_SUMMARIZE_AGG genuinely working, or returning NULL quietly?

ALTER SESSION SET QUERY_TAG = 'p00:probe2';

-- =============================================================================
-- Q1a — EDITION. This is the single most important cell in the whole probe.
-- Needs ORGADMIN; CURRENT_ROLE() already showed ORGADMIN, so this should run.
-- Also reconciles the account NAME (in the Snowsight URL) with the
-- LOCATOR (what CURRENT_ACCOUNT() returns) — they do not match right now.
-- =============================================================================
USE ROLE ORGADMIN;
SHOW ORGANIZATION ACCOUNTS;
SELECT "account_name",
       "account_locator",
       "edition",
       "snowflake_region",
       "created_on",
       "account_url",
       "is_org_admin"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- =============================================================================
-- Q1b — remaining free balance and expiry. Wrapped: these views are not
-- guaranteed to exist on a trial.
-- =============================================================================
EXECUTE IMMEDIATE $$
DECLARE
  r STRING DEFAULT '';
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SNOWFLAKE.ORGANIZATION_USAGE.REMAINING_BALANCE_DAILY';
    r := r || 'remaining_balance_daily=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'remaining_balance_daily=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SNOWFLAKE.ORGANIZATION_USAGE.CONTRACT_ITEMS';
    r := r || 'contract_items=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'contract_items=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  -- Enterprise-only surfaces. Probe 1 could not tell edition apart because
  -- SHOW succeeds and returns zero rows either way. These are the sharper tests.
  BEGIN
    EXECUTE IMMEDIATE 'SHOW MASKING POLICIES IN ACCOUNT';
    r := r || 'masking_policies=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'masking_policies=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  BEGIN
    EXECUTE IMMEDIATE 'SHOW ROW ACCESS POLICIES IN ACCOUNT';
    r := r || 'row_access_policies=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'row_access_policies=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  BEGIN
    EXECUTE IMMEDIATE 'SHOW MATERIALIZED VIEWS IN ACCOUNT';
    r := r || 'materialized_views=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'materialized_views=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY WHERE query_start_time > CURRENT_DATE-1';
    r := r || 'access_history_rows_readable=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'access_history_rows_readable=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  RETURN r;
END;
$$;

-- Retention ceiling is edition-dependent: Standard caps at 1 day, Enterprise 90.
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN ACCOUNT;

-- =============================================================================
-- Q2 — do the two Cortex functions that passed actually RETURN something?
-- Probe 1 only proved they did not raise. A NULL return would look identical.
-- If these come back NULL or error, the AISQL surface on this account is zero.
-- =============================================================================
SELECT AI_AGG(c, 'summarise these complaints in five words') AS ai_agg_out
FROM  (SELECT 'parcel arrived late and cold' c
       UNION ALL SELECT 'rider could not find the address');

SELECT AI_SUMMARIZE_AGG(c) AS ai_summarize_agg_out
FROM  (SELECT 'parcel arrived late and cold' c
       UNION ALL SELECT 'rider could not find the address');

-- Cortex Search and Cortex Analyst both need embeddings, which are blocked.
-- Confirm the block is categorical rather than per-function.
EXECUTE IMMEDIATE $$
DECLARE
  r STRING DEFAULT '';
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'SELECT SNOWFLAKE.CORTEX.TRANSLATE(''late parcel'', ''en'', ''de'')';
    r := r || 'cortex.translate=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'cortex.translate=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT SNOWFLAKE.CORTEX.SUMMARIZE(''the parcel arrived very late and the food was cold'')';
    r := r || 'cortex.summarize=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'cortex.summarize=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT AI_TRANSCRIBE(''x'')';
    r := r || 'cortex.ai_transcribe=OK\n';
  EXCEPTION WHEN OTHER THEN
    r := r || 'cortex.ai_transcribe=FAIL|' || REPLACE(LEFT(SQLERRM,140),'\n',' ') || '\n';
  END;
  RETURN r;
END;
$$;

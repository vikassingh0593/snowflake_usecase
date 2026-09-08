-- sql/p0_probe4_ddl.sql — PART 0 CLOSER. **THIS ONE WRITES.** Needs your yes.
-- =============================================================================
-- Everything is created inside a throwaway database QC_PROBE_TMP and the last
-- statement drops it. Nothing touches QCOMMERCE or any existing object.
--
-- WHY DDL: SHOW returning rows does not prove a feature is usable -- it returned
-- rows for DATA METRIC FUNCTIONS in probe 1 too, on an account where that may
-- not be true. CREATE either works or it does not. This is the unambiguous test.
--
-- COST: XS warehouse, well under a minute. ~0.02 credits. No Cortex.
-- =============================================================================

ALTER SESSION SET QUERY_TAG = 'p00:probe4_ddl';
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS QC_PROBE_TMP;
USE SCHEMA QC_PROBE_TMP.PUBLIC;

CREATE OR REPLACE TABLE T_PROBE AS
SELECT SEQ4()                            AS id,
       UNIFORM(1, 8, RANDOM())           AS store_id,
       'user' || SEQ4() || '@example.com' AS email,
       UNIFORM(100, 90000, RANDOM())     AS amount_paise
FROM   TABLE(GENERATOR(ROWCOUNT => 5000));

-- Each feature in its own block: one failure must not hide the others.
EXECUTE IMMEDIATE $$
DECLARE
  r STRING DEFAULT '';
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'CREATE OR REPLACE MASKING POLICY MP_PROBE AS (v STRING) RETURNS STRING -> CASE WHEN CURRENT_ROLE() = ''ACCOUNTADMIN'' THEN v ELSE ''***'' END';
    EXECUTE IMMEDIATE 'ALTER TABLE T_PROBE MODIFY COLUMN email SET MASKING POLICY MP_PROBE';
    r := r || 'CREATE masking_policy=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'CREATE masking_policy=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  BEGIN
    EXECUTE IMMEDIATE 'CREATE OR REPLACE ROW ACCESS POLICY RAP_PROBE AS (sid NUMBER) RETURNS BOOLEAN -> CURRENT_ROLE() = ''ACCOUNTADMIN''';
    EXECUTE IMMEDIATE 'ALTER TABLE T_PROBE ADD ROW ACCESS POLICY RAP_PROBE ON (store_id)';
    r := r || 'CREATE row_access_policy=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'CREATE row_access_policy=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  BEGIN
    EXECUTE IMMEDIATE 'CREATE OR REPLACE MATERIALIZED VIEW MV_PROBE AS SELECT store_id, COUNT(*) c FROM T_PROBE GROUP BY store_id';
    r := r || 'CREATE materialized_view=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'CREATE materialized_view=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE T_PROBE ADD SEARCH OPTIMIZATION ON EQUALITY(id)';
    r := r || 'ADD search_optimization=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'ADD search_optimization=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  BEGIN
    EXECUTE IMMEDIATE 'SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS(''T_PROBE'')';
    r := r || 'so_cost_estimator=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'so_cost_estimator=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  BEGIN
    EXECUTE IMMEDIATE 'CREATE OR REPLACE DATA METRIC FUNCTION DMF_PROBE(t TABLE(c NUMBER)) RETURNS NUMBER AS ''SELECT COUNT(*) FROM t WHERE c IS NULL''';
    r := r || 'CREATE data_metric_function=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'CREATE data_metric_function=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE T_PROBE SET DATA_RETENTION_TIME_IN_DAYS = 30';
    r := r || 'time_travel_30d=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'time_travel_30d=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES';
    r := r || 'account_usage.masking_policies=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'account_usage.masking_policies=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  -- Automatic classification: this is what replaces the Cortex-assisted PII
  -- classification that the trial AI gate killed. Worth knowing now.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT SYSTEM$CLASSIFY(''QC_PROBE_TMP.PUBLIC.T_PROBE'', {''auto_tag'': false})';
    r := r || 'system_classify=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'system_classify=FAIL|' || REPLACE(LEFT(SQLERRM,130),'\n',' ') || '\n'; END;

  RETURN r;
END;
$$;

-- Does the masking policy actually mask? Run as a role that is not ACCOUNTADMIN
-- to see '***'. As ACCOUNTADMIN this returns the real value -- that is correct.
SELECT id, email, store_id FROM T_PROBE LIMIT 3;

-- =============================================================================
-- CLEANUP. Run this. It removes everything the file created.
-- =============================================================================
DROP DATABASE IF EXISTS QC_PROBE_TMP;
SHOW DATABASES LIKE 'QC_PROBE_TMP';   -- expect zero rows

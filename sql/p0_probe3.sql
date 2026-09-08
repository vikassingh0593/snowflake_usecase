-- sql/p0_probe3.sql — PART 0, third pass. The edition LABEL is not the point.
-- What matters is whether the Enterprise features actually work. This tests that
-- directly and does not depend on ORGADMIN, RESULT_SCAN, or column names.
--
-- READ-ONLY. Creates nothing. Negligible cost. No Cortex calls.

ALTER SESSION SET QUERY_TAG = 'p00:probe3';
USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- THE DECISIVE ONE. Run this single statement, paste the one text cell.
-- On Standard these are rejected outright. On Enterprise they return empty.
-- "OK" here means the feature EXISTS, not that anything is defined.
-- =============================================================================
EXECUTE IMMEDIATE $$
DECLARE
  r STRING DEFAULT '';
BEGIN
  BEGIN EXECUTE IMMEDIATE 'SHOW MASKING POLICIES IN ACCOUNT';
    r := r || 'masking_policies=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'masking_policies=FAIL|' || REPLACE(LEFT(SQLERRM,120),'\n',' ') || '\n'; END;

  BEGIN EXECUTE IMMEDIATE 'SHOW ROW ACCESS POLICIES IN ACCOUNT';
    r := r || 'row_access_policies=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'row_access_policies=FAIL|' || REPLACE(LEFT(SQLERRM,120),'\n',' ') || '\n'; END;

  BEGIN EXECUTE IMMEDIATE 'SHOW AGGREGATION POLICIES IN ACCOUNT';
    r := r || 'aggregation_policies=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'aggregation_policies=FAIL|' || REPLACE(LEFT(SQLERRM,120),'\n',' ') || '\n'; END;

  BEGIN EXECUTE IMMEDIATE 'SHOW MATERIALIZED VIEWS IN ACCOUNT';
    r := r || 'materialized_views=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'materialized_views=FAIL|' || REPLACE(LEFT(SQLERRM,120),'\n',' ') || '\n'; END;

  -- Retention ceiling: Standard caps at 1 day, Enterprise at 90. This SETS a
  -- parameter, so it is the one non-read-only line in the file. It is reverted
  -- on the next line either way. If you would rather not, delete this block --
  -- the four above are already enough to decide.
  BEGIN EXECUTE IMMEDIATE 'ALTER SESSION SET DATA_RETENTION_TIME_IN_DAYS = 30';
    r := r || 'retention_30d=OK (Enterprise-shaped)\n';
    EXECUTE IMMEDIATE 'ALTER SESSION UNSET DATA_RETENTION_TIME_IN_DAYS';
  EXCEPTION WHEN OTHER THEN r := r || 'retention_30d=FAIL|' || REPLACE(LEFT(SQLERRM,120),'\n',' ') || '\n'; END;

  -- Identity, for the Part 1 connection string.
  BEGIN EXECUTE IMMEDIATE 'SELECT CURRENT_ACCOUNT_NAME()';
    r := r || 'current_account_name_fn=OK\n';
  EXCEPTION WHEN OTHER THEN r := r || 'current_account_name_fn=FAIL|' || REPLACE(LEFT(SQLERRM,120),'\n',' ') || '\n'; END;

  RETURN r;
END;
$$;

-- =============================================================================
-- Identity + edition, three independent sources. Run each ON ITS OWN and paste
-- whatever comes back, including "0 rows" or the error text -- an empty grid is
-- itself an answer.
-- =============================================================================

-- (a) account name, if the function exists on this version
SELECT CURRENT_ACCOUNT() AS locator, CURRENT_ACCOUNT_NAME() AS account_name;

-- (b) ORGADMIN view. Read the GRID directly. Do not RESULT_SCAN it -- that is
--     what returned nothing last time. Screenshot is fine.
USE ROLE ORGADMIN;
SHOW ORGANIZATION ACCOUNTS;

-- (c) older spelling of the same thing, if (b) is empty
SHOW ACCOUNTS;

-- (d) edition appears as SERVICE_LEVEL in the org rate sheet
USE ROLE ACCOUNTADMIN;
SELECT DISTINCT account_name, account_locator, service_level, region
FROM   SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY
ORDER  BY 1;

-- =============================================================================
-- sql/p1_fix.sql — three corrections found in the p1_bootstrap SHOW output.
-- Cost: metadata only, no warehouse resumed. Effectively free.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p01:fix';

-- -----------------------------------------------------------------------------
-- 1. Query acceleration is ON by default and bills as separate serverless
--    credits, invisible to RM_POC. The architecture excludes it: no workload
--    here is large enough to benefit, and it is a cost trap on a fixed balance.
-- -----------------------------------------------------------------------------
ALTER WAREHOUSE WH_INGEST_XS    SET ENABLE_QUERY_ACCELERATION = FALSE;
ALTER WAREHOUSE WH_TRANSFORM_XS SET ENABLE_QUERY_ACCELERATION = FALSE;
ALTER WAREHOUSE WH_APP_XS       SET ENABLE_QUERY_ACCELERATION = FALSE;

-- -----------------------------------------------------------------------------
-- 2. RM_POC has notify triggers at 50/75/90 percent and NOTIFY_USERS is empty,
--    so all three fire into nothing. Only the 100% suspend would be noticed,
--    by which point the warehouses have stopped.
--    The user must have a verified email on the account for this to deliver.
-- -----------------------------------------------------------------------------
ALTER RESOURCE MONITOR RM_POC SET NOTIFY_USERS = ('VIKASSINGH0593');

SHOW RESOURCE MONITORS LIKE 'RM_POC';   -- notify_users should now be populated

-- -----------------------------------------------------------------------------
-- 3. The warehouses are STANDARD_GEN_2. Gen2 became the DEFAULT generation in
--    behaviour-change bundle 2026_03, so this happened without being asked for.
--
--    Gen2 is faster on large scans, deletes, updates and merges. At 200k rows
--    the biggest table in this project, none of that is the bottleneck --
--    warehouse resume and cloud services are. So we would pay the Gen2 rate and
--    collect none of the benefit.
--
--    The exact multiplier is UNVERIFIED: commonly quoted as ~1.35x, not
--    confirmed in the docs I could reach. Against a ~112 credit budget that is
--    roughly 39 credits of exposure, which is worth five minutes to avoid.
--
--    Confirmed working: ALTER ... SET GENERATION = '1'.
-- -----------------------------------------------------------------------------
-- RESOURCE_CONSTRAINT is rejected: "Use the GENERATION property to set
-- warehouse hardware generation." Altering in place works, so the recreate
-- fallback below is not needed and the grants survive.
ALTER WAREHOUSE WH_INGEST_XS    SET GENERATION = '1';
ALTER WAREHOUSE WH_TRANSFORM_XS SET GENERATION = '1';
ALTER WAREHOUSE WH_APP_XS       SET GENERATION = '1';

SHOW WAREHOUSES LIKE 'WH_%';   -- check the generation column

-- Fallback if the ALTER above is not supported on this account:
-- CREATE OR REPLACE WAREHOUSE WH_INGEST_XS WITH
--   WAREHOUSE_SIZE = 'XSMALL' GENERATION = '1'
--   AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
--   RESOURCE_MONITOR = RM_POC ENABLE_QUERY_ACCELERATION = FALSE
--   COMMENT = 'pipes, COPY, streaming ingest';
-- CREATE OR REPLACE WAREHOUSE WH_TRANSFORM_XS WITH
--   WAREHOUSE_SIZE = 'XSMALL' GENERATION = '1'
--   AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
--   RESOURCE_MONITOR = RM_POC ENABLE_QUERY_ACCELERATION = FALSE
--   COMMENT = 'dbt outer session AND dbt target';
-- CREATE OR REPLACE WAREHOUSE WH_APP_XS WITH
--   WAREHOUSE_SIZE = 'XSMALL' GENERATION = '1'
--   AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
--   RESOURCE_MONITOR = RM_POC ENABLE_QUERY_ACCELERATION = FALSE
--   COMMENT = 'Streamlit, ad-hoc analyst queries';
-- Re-grant after recreating -- CREATE OR REPLACE drops the grants:
-- GRANT USAGE ON WAREHOUSE WH_INGEST_XS    TO ROLE QC_LOADER;
-- GRANT USAGE ON WAREHOUSE WH_TRANSFORM_XS TO ROLE QC_ENGINEER;
-- GRANT USAGE ON WAREHOUSE WH_APP_XS       TO ROLE QC_ANALYST;
-- GRANT USAGE ON WAREHOUSE WH_APP_XS       TO ROLE QC_ENGINEER;

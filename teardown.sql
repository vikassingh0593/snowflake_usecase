-- teardown.sql — Snowflake side. STUB: fill in as objects are created (from Part 1).
-- Run as ACCOUNTADMIN. Order matters: dependents first, integrations last.
-- Goal: zero remaining spend. Verify with the queries at the bottom.

USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p17:teardown';

-- ---------------------------------------------------------------------------
-- 1. Stop anything that can still consume credits
-- ---------------------------------------------------------------------------
-- Tasks (suspend the ROOT task of each DAG first, then drop)
-- ALTER TASK QCOMMERCE.OPS.T_ROOT SUSPEND;
-- SHOW TASKS IN ACCOUNT;                     -- confirm none STARTED

-- Pipes
-- ALTER PIPE QCOMMERCE.LAND.PIPE_CLICKSTREAM_AUTO SET PIPE_EXECUTION_PAUSED = TRUE;
-- SHOW PIPES IN ACCOUNT;

-- Dynamic tables (max 2 in this build)
-- ALTER DYNAMIC TABLE QCOMMERCE.SERVE.SLA_BY_STORE_HOUR SUSPEND;
-- SHOW DYNAMIC TABLES IN ACCOUNT;

-- Alerts
-- ALTER ALERT QCOMMERCE.OPS.AL_DQ_FAIL SUSPEND;

-- Cortex Search services (serverless, bills while it exists)
-- DROP CORTEX SEARCH SERVICE IF EXISTS QCOMMERCE.MART.CSS_COMPLAINT;

-- Always-on bursts from Part 14 — these MUST already be gone
-- DROP TABLE IF EXISTS QCOMMERCE.SERVE.ACTION_LOG_HYBRID;
-- (Snowflake Postgres instance: drop from Snowsight, confirm no instance remains)

-- Streamlit apps
-- DROP STREAMLIT IF EXISTS QCOMMERCE.APP.QC_CONSOLE;

-- ---------------------------------------------------------------------------
-- 2. Serving artefacts (Part 13)
-- ---------------------------------------------------------------------------
-- DROP APPLICATION IF EXISTS QC_NATIVE_APP CASCADE;
-- DROP APPLICATION PACKAGE IF EXISTS QC_NATIVE_APP_PKG;
-- DROP SHARE IF EXISTS QC_MART_SHARE;
-- Private listing: unpublish + delete in Snowsight → Data Products → Provider Studio
-- DROP MANAGED ACCOUNT <reader_account_name>;   -- reader account bills to this account

-- ---------------------------------------------------------------------------
-- 3. ML artefacts (Part 9)
-- ---------------------------------------------------------------------------
-- Model Registry models and Feature Store entities live in LAB; dropping LAB removes
-- them, but drop explicitly if the registry was created elsewhere.
-- DROP SCHEMA IF EXISTS QCOMMERCE.LAB CASCADE;   -- transient, no Fail-safe

-- ---------------------------------------------------------------------------
-- 4. Database
-- ---------------------------------------------------------------------------
-- DROP DATABASE IF EXISTS QCOMMERCE CASCADE;
-- DROP DATABASE IF EXISTS MART_DEV;              -- CI clone (Part 15)
-- DROP DATABASE IF EXISTS <marketplace_share_db>;  -- imported share (mechanism 12)

-- ---------------------------------------------------------------------------
-- 5. Account-level objects
-- ---------------------------------------------------------------------------
-- DROP EXTERNAL VOLUME IF EXISTS EXVOL_QC;
-- DROP INTEGRATION IF EXISTS SI_QC_AZURE;         -- storage
-- DROP INTEGRATION IF EXISTS NI_QC_SNOWPIPE;      -- queue notification
-- DROP INTEGRATION IF EXISTS EAI_OPEN_METEO;      -- external access
-- DROP INTEGRATION IF EXISTS NI_QC_EMAIL;         -- email notification
-- DROP INTEGRATION IF EXISTS GIT_QC;              -- git (Part 15)
-- DROP NETWORK RULE IF EXISTS NR_OPEN_METEO;
-- DROP SECRET IF EXISTS SEC_OPEN_METEO;
-- DROP GIT REPOSITORY IF EXISTS QC_REPO;
-- DROP DBT PROJECT IF EXISTS QC_DBT;

-- DROP WAREHOUSE IF EXISTS WH_INGEST_XS;
-- DROP WAREHOUSE IF EXISTS WH_TRANSFORM_XS;
-- DROP WAREHOUSE IF EXISTS WH_APP_XS;

-- DROP USER IF EXISTS SVC_KAFKA;
-- DROP USER IF EXISTS SVC_CI;
-- DROP ROLE IF EXISTS QC_ANALYST;
-- DROP ROLE IF EXISTS QC_ENGINEER;
-- DROP ROLE IF EXISTS QC_LOADER;
-- DROP ROLE IF EXISTS QC_ADMIN;

-- DROP RESOURCE MONITOR IF EXISTS RM_POC;
-- Budget: delete in Snowsight → Admin → Cost Management → Budgets

-- ---------------------------------------------------------------------------
-- 6. Verify zero remaining spend
-- ---------------------------------------------------------------------------
SHOW WAREHOUSES;                    -- expect none, or all SUSPENDED and dropped
SHOW TASKS IN ACCOUNT;              -- expect none
SHOW PIPES IN ACCOUNT;              -- expect none
SHOW DYNAMIC TABLES IN ACCOUNT;     -- expect none
SHOW CORTEX SEARCH SERVICES IN ACCOUNT;
SHOW MANAGED ACCOUNTS;              -- expect none
SHOW DATABASES;                     -- expect only SNOWFLAKE / SNOWFLAKE_SAMPLE_DATA

-- Final credit reading for docs/CREDITS.md (ACCOUNT_USAGE lags up to ~3h)
SELECT service_type, SUM(credits_used) AS credits
FROM   SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE  start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP  BY 1 ORDER BY 2 DESC;

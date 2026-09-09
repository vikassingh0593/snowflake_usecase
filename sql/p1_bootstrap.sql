-- =============================================================================
-- sql/p1_bootstrap.sql — Snowflake foundation. THIS WRITES.
--
-- Account : AWTTGVH-OLB61128 (locator OOB49311), AWS_US_WEST_2
-- Creates : 1 resource monitor, 3 XS warehouses, 1 database, 9 schemas,
--           4 roles, 2 service users, grants
-- Drops   : QCOMMERCE.PUBLIC only (the schema Snowflake auto-creates)
--
-- COST: DDL is metadata, effectively free. Warehouses are created
--       INITIALLY_SUSPENDED and bill nothing until a query runs on them.
--       Expect < 0.01 credits for this whole file.
--
-- ORDER MATTERS: the resource monitor is created before the warehouses so
-- they can be attached to it at birth rather than left uncapped for a while.
--
-- Run as ACCOUNTADMIN:  snow sql -c my_example_connection -f sql/p1_bootstrap.sql
-- Teardown is at the bottom, commented out.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p01:bootstrap';

-- -----------------------------------------------------------------------------
-- 1. Account-level guardrails
-- -----------------------------------------------------------------------------
-- A runaway query dies at 10 minutes rather than burning the balance overnight.
ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 600;

-- 1 day of Time Travel. The account may support 90; storage is cheap at this
-- scale but there is no reason to pay for history we will never read.
-- MART is raised to 7 days later, where recovery demos actually happen.
ALTER ACCOUNT SET DATA_RETENTION_TIME_IN_DAYS = 1;

-- -----------------------------------------------------------------------------
-- 2. Resource monitor — warehouse credits only
--
-- This does NOT cover serverless spend: Snowpipe, Snowpipe Streaming, dynamic
-- table refresh, serverless tasks and search optimization are all invisible to
-- it. The account budget in section 7 is what covers those. Both are required;
-- neither is sufficient alone.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE RESOURCE MONITOR RM_POC
  WITH CREDIT_QUOTA = 60
       FREQUENCY = NEVER
       START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON  50 PERCENT DO NOTIFY
    ON  75 PERCENT DO NOTIFY
    ON  90 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND
    ON 110 PERCENT DO SUSPEND_IMMEDIATE;

-- -----------------------------------------------------------------------------
-- 3. Warehouses — all XSMALL, all suspended at birth, never resized
--
-- Three rather than one so QUERY_ATTRIBUTION_HISTORY can separate ingestion,
-- transformation and application spend without any extra work later.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS WH_INGEST_XS WITH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE RESOURCE_MONITOR = RM_POC
  COMMENT = 'pipes, COPY, streaming ingest';

CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM_XS WITH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE RESOURCE_MONITOR = RM_POC
  COMMENT = 'dbt outer session AND dbt target - both, or EXECUTE DBT PROJECT bills twice';

CREATE WAREHOUSE IF NOT EXISTS WH_APP_XS WITH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE RESOURCE_MONITOR = RM_POC
  COMMENT = 'Streamlit, ad-hoc analyst queries';

-- -----------------------------------------------------------------------------
-- 4. Database and schemas
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS QCOMMERCE
  COMMENT = 'Quick-commerce PoC. Disposable.';
USE DATABASE QCOMMERCE;

-- Snowflake creates PUBLIC automatically. An ungoverned catch-all schema is
-- where undocumented objects accumulate, so it goes.
DROP SCHEMA IF EXISTS QCOMMERCE.PUBLIC;

CREATE SCHEMA IF NOT EXISTS LAND     COMMENT = 'stages, pipes, file formats, external volume, network rules. NO TABLES';
CREATE SCHEMA IF NOT EXISTS RAW      COMMENT = '1:1 with source, append-only, VARIANT payload, never updated. Dedupe happens in CORE';
CREATE SCHEMA IF NOT EXISTS CORE     COMMENT = 'conformed, deduped, typed, SCD2 history';
CREATE SCHEMA IF NOT EXISTS MART     COMMENT = 'star schema, published and governed';
CREATE SCHEMA IF NOT EXISTS SERVE    COMMENT = 'scored output, aggregates, app write-back. A CONTRACT: everything here is tested';
CREATE SCHEMA IF NOT EXISTS SEMANTIC COMMENT = 'semantic views';
CREATE SCHEMA IF NOT EXISTS APP      COMMENT = 'Streamlit artefacts';
CREATE SCHEMA IF NOT EXISTS OPS      COMMENT = 'PIPELINE_LOG, DQ_RESULTS, credit snapshots, alert history';

-- LAB is TRANSIENT: no Fail-safe, cheaper storage, and its disposability is
-- the point. Nothing downstream may reference a LAB object.
CREATE TRANSIENT SCHEMA IF NOT EXISTS LAB
  COMMENT = 'SANDBOX. features, training sets, model output. Nothing downstream reads this';

-- -----------------------------------------------------------------------------
-- 5. Roles
-- -----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS QC_ADMIN    COMMENT = 'owns QCOMMERCE';
CREATE ROLE IF NOT EXISTS QC_LOADER   COMMENT = 'writes RAW. Kafka connector, pipes';
CREATE ROLE IF NOT EXISTS QC_ENGINEER COMMENT = 'dbt, Snowpark, CI';
CREATE ROLE IF NOT EXISTS QC_ANALYST  COMMENT = 'reads SERVE through secure views only';

GRANT ROLE QC_LOADER   TO ROLE QC_ADMIN;
GRANT ROLE QC_ENGINEER TO ROLE QC_ADMIN;
GRANT ROLE QC_ANALYST  TO ROLE QC_ADMIN;
GRANT ROLE QC_ADMIN    TO ROLE SYSADMIN;   -- keeps SYSADMIN the top of the tree

-- Ownership. Doing this now means later DDL does not need ACCOUNTADMIN.
GRANT OWNERSHIP ON DATABASE QCOMMERCE TO ROLE QC_ADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE QCOMMERCE TO ROLE QC_ADMIN COPY CURRENT GRANTS;

-- -----------------------------------------------------------------------------
-- 6. Grants
-- -----------------------------------------------------------------------------
GRANT USAGE ON WAREHOUSE WH_INGEST_XS    TO ROLE QC_LOADER;
GRANT USAGE ON WAREHOUSE WH_TRANSFORM_XS TO ROLE QC_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_APP_XS       TO ROLE QC_ANALYST;
GRANT USAGE ON WAREHOUSE WH_APP_XS       TO ROLE QC_ENGINEER;

GRANT USAGE ON DATABASE QCOMMERCE TO ROLE QC_LOADER;
GRANT USAGE ON DATABASE QCOMMERCE TO ROLE QC_ENGINEER;
GRANT USAGE ON DATABASE QCOMMERCE TO ROLE QC_ANALYST;

-- Loader: writes LAND and RAW, sees nothing else.
GRANT USAGE, CREATE STAGE, CREATE FILE FORMAT, CREATE PIPE, CREATE TABLE
  ON SCHEMA QCOMMERCE.LAND TO ROLE QC_LOADER;
GRANT USAGE, CREATE TABLE, CREATE STREAM ON SCHEMA QCOMMERCE.RAW TO ROLE QC_LOADER;
GRANT INSERT, SELECT ON FUTURE TABLES IN SCHEMA QCOMMERCE.RAW TO ROLE QC_LOADER;

-- Engineer: everything except SERVE ownership.
GRANT ALL ON SCHEMA QCOMMERCE.RAW      TO ROLE QC_ENGINEER;
GRANT ALL ON SCHEMA QCOMMERCE.CORE     TO ROLE QC_ENGINEER;
GRANT ALL ON SCHEMA QCOMMERCE.MART     TO ROLE QC_ENGINEER;
GRANT ALL ON SCHEMA QCOMMERCE.LAB      TO ROLE QC_ENGINEER;
GRANT ALL ON SCHEMA QCOMMERCE.SERVE    TO ROLE QC_ENGINEER;
GRANT ALL ON SCHEMA QCOMMERCE.SEMANTIC TO ROLE QC_ENGINEER;
GRANT ALL ON SCHEMA QCOMMERCE.OPS      TO ROLE QC_ENGINEER;
GRANT ALL ON SCHEMA QCOMMERCE.APP      TO ROLE QC_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA QCOMMERCE.RAW TO ROLE QC_ENGINEER;

-- Analyst: SERVE only, and only through views. No base-table access anywhere.
-- Streamlit never reads RAW, CORE or LAB, and neither does the analyst.
GRANT USAGE ON SCHEMA QCOMMERCE.SERVE    TO ROLE QC_ANALYST;
GRANT USAGE ON SCHEMA QCOMMERCE.SEMANTIC TO ROLE QC_ANALYST;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA QCOMMERCE.SERVE    TO ROLE QC_ANALYST;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA QCOMMERCE.SEMANTIC TO ROLE QC_ANALYST;

-- -----------------------------------------------------------------------------
-- 7. Service users
--
-- TYPE = SERVICE cannot log in interactively and cannot use a password. Your
-- own user stays on externalbrowser; these two must be key-pair, because the
-- Kafka connector and GitHub Actions have no browser to open.
--
-- Generate the keys BEFORE running this section:
--   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_kafka.p8 -nocrypt
--   openssl rsa -in rsa_kafka.p8 -pubout -out rsa_kafka.pub
--   grep -v "^-----" rsa_kafka.pub | tr -d '\n'
-- Paste that single line below. Never commit the .p8 files.
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS SVC_KAFKA
  TYPE = SERVICE
  DEFAULT_ROLE = QC_LOADER
  DEFAULT_WAREHOUSE = WH_INGEST_XS
  COMMENT = 'Snowflake Kafka Connector v4 + Snowpipe Streaming SDK';

CREATE USER IF NOT EXISTS SVC_CI
  TYPE = SERVICE
  DEFAULT_ROLE = QC_ENGINEER
  DEFAULT_WAREHOUSE = WH_TRANSFORM_XS
  COMMENT = 'GitHub Actions, dbt build against a clone';

GRANT ROLE QC_LOADER   TO USER SVC_KAFKA;
GRANT ROLE QC_ENGINEER TO USER SVC_CI;

-- Fill in and run separately, once the keys exist:
-- ALTER USER SVC_KAFKA SET RSA_PUBLIC_KEY = '<single line, no header/footer>';
-- ALTER USER SVC_CI    SET RSA_PUBLIC_KEY = '<single line, no header/footer>';
-- DESC USER SVC_KAFKA;   -- RSA_PUBLIC_KEY_FP populated = registered

-- -----------------------------------------------------------------------------
-- 8. Verify
-- -----------------------------------------------------------------------------
SHOW WAREHOUSES LIKE 'WH_%';
SHOW SCHEMAS IN DATABASE QCOMMERCE;
SHOW ROLES LIKE 'QC_%';
SHOW USERS LIKE 'SVC_%';
SHOW RESOURCE MONITORS LIKE 'RM_POC';
SHOW GRANTS TO ROLE QC_ANALYST;

-- =============================================================================
-- 9. ACCOUNT BUDGET — the only control that covers serverless spend
--
-- The resource monitor above sees virtual-warehouse credits only. Snowpipe,
-- Snowpipe Streaming, dynamic table refresh, serverless tasks, search
-- optimization and materialized-view maintenance are all invisible to it.
--
-- EASIEST PATH, and the one to use: Snowsight -> Admin -> Cost Management ->
-- Budgets -> Account Budget -> Activate, set limit 80 credits, add your email.
--
-- SQL equivalent (syntax UNVERIFIED on this account - if it errors, use the UI
-- above rather than debugging it):
--   CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!ACTIVATE();
--   CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_SPENDING_LIMIT(80);
--   CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_NOTIFICATION_USERS(
--          ARRAY_CONSTRUCT('VIKASSINGH0593'));
-- =============================================================================

-- =============================================================================
-- 10. TEARDOWN — uncomment and run to remove everything this file created.
--     Keep this current as later parts add objects.
-- =============================================================================
-- USE ROLE ACCOUNTADMIN;
-- DROP DATABASE IF EXISTS QCOMMERCE;
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
-- SHOW WAREHOUSES; SHOW DATABASES; SHOW RESOURCE MONITORS;

-- =============================================================================
-- sql/teardown.sql — remove every object this project created, account-wide.
--
-- The version that used to live commented-out at the foot of p1_bootstrap.sql
-- covered the database, three warehouses, two users, four roles and one resource
-- monitor. By Part 15 the project had also created a share, five integrations, an
-- external volume, an Iceberg table on external storage, a git repository, a
-- second resource monitor and an account-level monitor assignment. A teardown
-- that misses those leaves an account that looks clean in SHOW DATABASES and
-- still refuses to let you rebuild.
--
-- ORDER IS NOT COSMETIC. Four dependencies force it:
--
--   1. RM_ACCOUNT cannot be dropped while it is assigned to the account, and the
--      assignment is cleared by ALTER ACCOUNT UNSET, not by DROP.
--   2. EXVOL_QC cannot be dropped while an Iceberg table references it, and a
--      table dropped into Time Travel still counts as referencing it. The
--      Iceberg table is therefore dropped and purged before the database.
--   3. SI_QC_AZURE cannot be dropped while a stage uses it, NI_QC_SNOWPIPE not
--      while a pipe uses it. Dropping the database removes both.
--   4. A share holding grants on a database that no longer exists is a dangling
--      share. The share goes first.
--
-- Everything is IF EXISTS. Running it twice is safe; running it on a partly
-- built account is safe; running it after a probe aborted halfway is the point.
--
--   snow sql -c qcpoc -f sql/teardown.sql
--   scripts/rebuild.sh teardown          same thing, behind a confirm gate
--
-- WHAT IT DOES NOT REMOVE, because nothing can:
--   * The account root budget. It is a built-in class instance, not a created
--     object — deactivate it in Snowsight, do not look for a DROP.
--   * ACCOUNT_USAGE history. Credit and query history outlive the objects, which
--     is what makes sql/p15_cost.sql still readable after this file runs.
--   * SNOWFLAKE_LEARNING_WH. Section 9 suspends it and explains why.
--   * The Azure storage account, its containers and the Event Grid queue.
--     Those are Azure resources; scripts/rebuild.sh prints the az commands and
--     will not run them.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 1. Release the account-level monitor assignment
--
-- RM_ACCOUNT is assigned with ALTER ACCOUNT SET RESOURCE_MONITOR. While that
-- assignment stands, DROP RESOURCE MONITOR RM_ACCOUNT fails. UNSET is the only
-- way to clear it, and it is harmless when nothing is assigned.
-- -----------------------------------------------------------------------------
ALTER ACCOUNT UNSET RESOURCE_MONITOR;

-- -----------------------------------------------------------------------------
-- 2. Outbound surfaces
--
-- Shares and listings reference objects rather than containing them, so they
-- must be released before the objects go. The TMP_ names are probe residue from
-- Part 13 — each probe drops its own, but a probe that aborted mid-way does not.
-- -----------------------------------------------------------------------------
DROP SHARE IF EXISTS SHR_QC_ANALYTICS;
DROP SHARE IF EXISTS TMP_P13_OPEN_SHARE;
DROP SHARE IF EXISTS TMP_P13_SECURE_SHARE;
DROP SHARE IF EXISTS TMP_P13_LISTING_SHARE;

DROP LISTING IF EXISTS TMP_P13_PROBE_LISTING;

DROP APPLICATION PACKAGE IF EXISTS TMP_P13_PROBE_APP;

-- -----------------------------------------------------------------------------
-- 3. The Iceberg table, before the database
--
-- Snowflake manages the metadata, the external volume holds the data. Dropping
-- the database would take the table into Time Travel still holding a reference
-- to EXVOL_QC, and the external volume drop in section 5 would then fail with a
-- dependency error naming a table you can no longer see. Dropping it explicitly
-- is the difference between a teardown that finishes and one that needs a
-- retention window to pass first.
-- -----------------------------------------------------------------------------
DROP ICEBERG TABLE IF EXISTS QCOMMERCE.RAW.ORDER_EVENTS_ICEBERG;

-- -----------------------------------------------------------------------------
-- 4. Databases
--
-- QCOMMERCE takes with it: eight schemas, every table and view, both dynamic
-- tables, both pipes, the streams and tasks, the directory table, the row access
-- and masking policies, the Streamlit app, the model registry, the git
-- repository LAND.GIT_QCOMMERCE, and the network rule for external access.
--
-- QC_PROBE_TMP is Part 12 probe residue.
-- -----------------------------------------------------------------------------
DROP DATABASE IF EXISTS QCOMMERCE;
DROP DATABASE IF EXISTS QC_PROBE_TMP;

-- -----------------------------------------------------------------------------
-- 5. Integrations and the external volume
--
-- All account-level, all invisible in SHOW DATABASES, all of which will collide
-- by name on a rebuild if left behind. SI_QC_AZURE and NI_QC_SNOWPIPE could not
-- have been dropped before section 4 — the stages and pipes held them.
--
-- TMP_P14_GIT_API and TMP_EMAIL are probe residue.
-- -----------------------------------------------------------------------------
DROP INTEGRATION IF EXISTS GIT_API_QCOMMERCE;
DROP INTEGRATION IF EXISTS SI_QC_AZURE;
DROP INTEGRATION IF EXISTS NI_QC_SNOWPIPE;
DROP INTEGRATION IF EXISTS NI_EMAIL_OPS;
DROP INTEGRATION IF EXISTS EAI_OPEN_METEO;
DROP INTEGRATION IF EXISTS TMP_P14_GIT_API;
DROP INTEGRATION IF EXISTS TMP_EMAIL;

DROP EXTERNAL VOLUME IF EXISTS EXVOL_QC;

-- -----------------------------------------------------------------------------
-- 6. Warehouses
--
-- Dropping a warehouse releases whatever resource monitor was assigned to it,
-- which is what lets RM_POC go in section 8.
-- -----------------------------------------------------------------------------
DROP WAREHOUSE IF EXISTS WH_INGEST_XS;
DROP WAREHOUSE IF EXISTS WH_TRANSFORM_XS;
DROP WAREHOUSE IF EXISTS WH_APP_XS;

-- -----------------------------------------------------------------------------
-- 7. Service users and roles
--
-- Both users are TYPE = SERVICE and authenticate by key pair. Dropping them
-- invalidates the public keys held in the account; the private keys on disk
-- (rsa_kafka.p8, rsa_ci.p8) become inert rather than dangerous, but they are
-- gitignored and should be deleted with the rest of the local state.
--
-- Roles last, because the users own grants through them.
-- -----------------------------------------------------------------------------
DROP USER IF EXISTS SVC_KAFKA;
DROP USER IF EXISTS SVC_CI;

DROP ROLE IF EXISTS QC_ANALYST;
DROP ROLE IF EXISTS QC_ENGINEER;
DROP ROLE IF EXISTS QC_LOADER;
DROP ROLE IF EXISTS QC_ADMIN;

-- -----------------------------------------------------------------------------
-- 8. Resource monitors
--
-- Last, because sections 1 and 6 are what made them droppable.
-- -----------------------------------------------------------------------------
DROP RESOURCE MONITOR IF EXISTS RM_POC;
DROP RESOURCE MONITOR IF EXISTS RM_ACCOUNT;

-- -----------------------------------------------------------------------------
-- 9. The warehouse this project did not create, and did not drop
--
-- SNOWFLAKE_LEARNING_WH is the trial account's default. Over the eight days of
-- the build it metered 3.1433 credits -- 51.4% of every warehouse credit spent,
-- against 2.9695 for WH_INGEST_XS, WH_TRANSFORM_XS and WH_APP_XS combined. Any
-- Snowsight worksheet that does not name a warehouse resumes it, and 79.3% of
-- all metered compute in this account was idle rather than execution.
--
-- RM_POC is level = WAREHOUSE and covers only the warehouses assigned to it, so
-- it never saw a credit of this. RM_POC read 3.02 against a budget reading 5.87,
-- and 2.9695 vs 3.02 is that gap closed: the missing half was one warehouse
-- nobody had assigned because nobody had created it.
--
-- Not dropped. It belongs to the account, not to this project, and dropping it
-- would leave Snowsight sessions with no default warehouse. Given this project's
-- auto-suspend instead, which is reversible and costs nothing.
--
-- AUTO_SUSPEND rather than an explicit SUSPEND. ALTER WAREHOUSE ... SUSPEND
-- fails with "Invalid state" when the warehouse is already suspended, which
-- would abort this file on its second run and break the only property it
-- promises. Setting the timeout suspends it within a minute of the last query
-- and does the same thing on every subsequent run: nothing.
-- -----------------------------------------------------------------------------
ALTER WAREHOUSE IF EXISTS SNOWFLAKE_LEARNING_WH SET AUTO_SUSPEND = 60;

-- -----------------------------------------------------------------------------
-- 10. Verify
--
-- A bare SHOW that matches nothing prints no result box at all, so on a clean
-- account seven of these produced no output and the run gave no way to tell
-- "empty" from "did not run". Each SHOW is therefore counted through
-- RESULT_SCAN, which returns a row saying 0 rather than returning nothing.
--
-- Every REMAINING should read 0 except the last, which keeps
-- SNOWFLAKE_LEARNING_WH. SHOW INTEGRATIONS has no LIKE that catches all the
-- prefixes at once, so its count excludes the vendor object by name instead.
-- -----------------------------------------------------------------------------
SHOW DATABASES LIKE 'QC%';
SELECT 'database' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW WAREHOUSES LIKE 'WH_%';
SELECT 'warehouse' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW ROLES LIKE 'QC_%';
SELECT 'role' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW USERS LIKE 'SVC_%';
SELECT 'user' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW RESOURCE MONITORS;
SELECT 'resource monitor' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "name" LIKE 'RM_%';

SHOW SHARES LIKE '%QC%';
SELECT 'share' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW EXTERNAL VOLUMES;
SELECT 'external volume' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW INTEGRATIONS;
SELECT 'integration' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "name" NOT LIKE 'SNOWFLAKE$%';

SHOW WAREHOUSES LIKE 'SNOWFLAKE_%';
SELECT 'vendor warehouse, kept' AS OBJECT, COUNT(*) AS REMAINING
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- =============================================================================
-- sql/p8_grants.sql — let QC_ENGINEER read what ACCOUNTADMIN built.
--
-- dbt failed every model that reads CORE with "does not exist or not
-- authorized", which is one message covering two very different situations. The
-- tables exist; SVC_CI could not see them.
--
-- THE CAUSE. p1_bootstrap.sql granted ALL ON SCHEMA QCOMMERCE.CORE to
-- QC_ENGINEER. That is a grant on the SCHEMA -- usage, create table, create
-- view -- and not on the objects inside it. Privileges on a table belong to the
-- table, and a table created later by a different role has none of them until
-- it is granted explicitly or covered by a FUTURE grant.
--
-- The bootstrap did set FUTURE TABLES on RAW, which is why the RAW-reading
-- parts of this project never hit it. CORE got the schema grant and no object
-- grant, and every CORE table was then created by ACCOUNTADMIN rather than by
-- QC_ENGINEER, so nothing QC_ENGINEER did gave it access to its own layer.
--
-- ON ALL covers what exists now. ON FUTURE covers what has not been created
-- yet. Both are needed: neither implies the other, and using only FUTURE is the
-- classic version of this bug -- it fixes tomorrow and leaves today broken.
--
-- COST: metadata only. No warehouse, no credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p08:grants';
USE DATABASE QCOMMERCE;

-- CORE — what dbt reads.
GRANT SELECT ON ALL TABLES    IN SCHEMA CORE TO ROLE QC_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CORE TO ROLE QC_ENGINEER;
GRANT SELECT ON ALL VIEWS     IN SCHEMA CORE TO ROLE QC_ENGINEER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA CORE TO ROLE QC_ENGINEER;

-- RAW — FUTURE was granted at bootstrap, ALL was not. Every table that existed
-- before that grant, and every table QC_LOADER created since, is still
-- unreadable to QC_ENGINEER. Not needed by MART today; needed the moment a
-- model or a quality check reaches back to RAW.
GRANT SELECT ON ALL TABLES    IN SCHEMA RAW TO ROLE QC_ENGINEER;
GRANT SELECT ON ALL VIEWS     IN SCHEMA RAW TO ROLE QC_ENGINEER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA RAW TO ROLE QC_ENGINEER;

-- OPS — dbt writes quality results here in Part 9.
GRANT SELECT, INSERT ON ALL TABLES    IN SCHEMA OPS TO ROLE QC_ENGINEER;
GRANT SELECT, INSERT ON FUTURE TABLES IN SCHEMA OPS TO ROLE QC_ENGINEER;

-- CREATE SCHEMA — for Part 14's pull-request clone, and nothing else here
-- needs it. The warehouse job in .github/workflows/ci.yml clones MART into
-- MART_CI_<run id>, builds against the copy and drops it, so a pull request
-- never touches MART. That has required this grant since Part 14 and did not
-- have it; the job skipped on every run for want of secrets, so the gap cost
-- nothing until the day they were finally set:
--
--   003001 (42501): Insufficient privileges to operate on database
--   'QCOMMERCE'. Your primary role QC_ENGINEER must have CREATE SCHEMA
--   granted on DATABASE QCOMMERCE.
--
-- WHY NOT AVOID THE GRANT. Building pull requests into a fixed schema created
-- once by ACCOUNTADMIN needs no privilege at all, and loses the property the
-- clone exists for: a clone inherits the row access policy of its source --
-- measured in sql/p14_git.sql, where clone_carries_row_access_policy passes --
-- while a fresh build inherits nothing. Pull requests would then be tested
-- against unprotected data, which is the failure Part 13 is about.
--
-- WHAT IT WIDENS, precisely: QC_ENGINEER may create schemas in QCOMMERCE. It
-- gains nothing in SERVE, GOV or the share, so the reason CI is not allowed to
-- deploy sql/deploy/ still holds.
GRANT CREATE SCHEMA ON DATABASE QCOMMERCE TO ROLE QC_ENGINEER;

-- =============================================================================
-- Verify as the role that was failing, not as ACCOUNTADMIN.
--
-- ACCOUNTADMIN can see everything, so checking from here proves nothing at all.
-- USE ROLE switches to the role dbt actually runs as; if these selects work,
-- dbt works.
-- =============================================================================
USE ROLE QC_ENGINEER;
USE WAREHOUSE WH_TRANSFORM_XS;

SELECT 'customer'     AS tbl, COUNT(*) AS n FROM QCOMMERCE.CORE.CUSTOMER
UNION ALL SELECT 'store',           COUNT(*) FROM QCOMMERCE.CORE.STORE
UNION ALL SELECT 'rider',           COUNT(*) FROM QCOMMERCE.CORE.RIDER
UNION ALL SELECT 'dim_product',     COUNT(*) FROM QCOMMERCE.CORE.DIM_PRODUCT
UNION ALL SELECT 'order_header',    COUNT(*) FROM QCOMMERCE.CORE.ORDER_HEADER
UNION ALL SELECT 'order_item',      COUNT(*) FROM QCOMMERCE.CORE.ORDER_ITEM
UNION ALL SELECT 'order_status_event', COUNT(*) FROM QCOMMERCE.CORE.ORDER_STATUS_EVENT
UNION ALL SELECT 'inventory_daily', COUNT(*) FROM QCOMMERCE.CORE.INVENTORY_DAILY
UNION ALL SELECT 'order_funnel',    COUNT(*) FROM QCOMMERCE.CORE.ORDER_FUNNEL
UNION ALL SELECT 'order_cancelled', COUNT(*) FROM QCOMMERCE.CORE.ORDER_CANCELLED
UNION ALL SELECT 'order_lifecycle_anomaly', COUNT(*) FROM QCOMMERCE.CORE.ORDER_LIFECYCLE_ANOMALY
ORDER BY n DESC;

USE ROLE ACCOUNTADMIN;

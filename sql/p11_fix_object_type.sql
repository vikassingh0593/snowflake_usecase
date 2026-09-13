-- =============================================================================
-- PART 11 — one-time migration. Run once, then never again.
--
-- The first version of p11_serve.sql created SLA_BY_STORE_HOUR as a DYNAMIC
-- TABLE. The restructured version wants that name to be a VIEW sitting above
-- SLA_STORE_HOUR_AGG, and CREATE OR REPLACE VIEW cannot replace an object of a
-- different type:
--
--   001998 (42710): Object 'SLA_BY_STORE_HOUR' already exists as DYNAMIC_TABLE
--
-- This drops the leftover. It is kept in its own file rather than at the top of
-- p11_serve.sql because that file has to stay re-runnable, and DROP DYNAMIC
-- TABLE aimed at what will by then be a view is exactly the kind of statement
-- whose behaviour I would be guessing at.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE QCOMMERCE;
ALTER SESSION SET QUERY_TAG = 'p11:fix_object_type';

SHOW DYNAMIC TABLES LIKE 'SLA_BY_STORE_HOUR' IN SCHEMA SERVE;

DROP DYNAMIC TABLE IF EXISTS SERVE.SLA_BY_STORE_HOUR;

SHOW DYNAMIC TABLES IN SCHEMA SERVE;

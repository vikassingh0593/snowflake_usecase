-- =============================================================================
-- sql/p6_marketplace.sql — mechanism 12.
--
--   A Marketplace listing, mounted and queried. Nothing is copied, nothing is
--   loaded, and no storage is billed to this account.
--
-- This is the only one of the fourteen with no pipeline at all. The provider's
-- storage is read directly through a share; there is no COPY, no pipe, no
-- refresh and no staleness, because there is no second copy to go stale. The
-- cost that remains is compute: the provider's bytes, scanned by YOUR
-- warehouse, on YOUR credits.
--
-- STEP 0 IS MANUAL. Marketplace acquisition is a Snowsight action, not DDL:
--
--   Snowsight -> Data Products -> Marketplace
--   Search:    Finance & Economics          (Snowflake Public Data Products,
--                                            formerly Cybersyn. Free, no trial.)
--   Get -> database name FINANCE__ECONOMICS
--       -> grant query access to QC_ENGINEER and QC_ANALYST
--
-- As acquired on 2026-09-10:
--   share    MARKETPLACE_PUBLIC_DATA_FREE
--   provider HFB60520.SNOWFLAKE_MANAGED$PUBLIC_AWS_US_WEST_2
--   schema   PUBLIC_DATA_FREE   -- NOT CYBERSYN. The rebrand moved it.
--
-- Any free listing exercises the same mechanism. This one is the pick because
-- it carries FX rates, and every amount in this platform is whole paise -- so
-- reporting an INR figure in USD is a real join rather than a token one.
-- If the listing has been renamed, STEP 1 discovers what you actually got and
-- only two identifiers below change: the database and the table.
--
-- COST: zero storage, zero ingestion. STEP 3 scans a shared table on
-- WH_TRANSFORM_XS. Estimate under 0.01 credits. Watch this one: a shared table
-- can be enormous and a careless SELECT * is the cheapest way to be surprised.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p06:marketplace';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — what actually arrived.
--
-- kind = INBOUND is the proof of zero-copy. The database is a mount of the
-- provider's share: it has an owner in another account, and dropping it here
-- destroys nothing of theirs.
-- =============================================================================
SHOW SHARES;

SELECT "name" AS share_name, "kind", "database_name", "owner_account"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE  "kind" = 'INBOUND';

SHOW DATABASES;

SELECT "name" AS db, "origin", "created_on"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE  "origin" <> '';       -- non-empty origin = came from a share

-- =============================================================================
-- STEP 2 — what is in it.
--
-- ROW_COUNT and BYTES come back NULL, not as the provider's figures. Shared
-- tables expose no size metadata at all, which is a harder constraint than it
-- first looks: you cannot estimate what a query will scan before running it.
-- "Never SELECT * on a share" stops being advice and becomes the only rule
-- available. A LIMIT with no ORDER BY is the safe probe -- it short-circuits
-- after one micro-partition however large the table is.
-- =============================================================================
SELECT TABLE_SCHEMA, TABLE_NAME, ROW_COUNT, BYTES
FROM   FINANCE__ECONOMICS.INFORMATION_SCHEMA.TABLES
WHERE  TABLE_TYPE IN ('BASE TABLE', 'VIEW')
ORDER  BY ROW_COUNT DESC NULLS LAST
LIMIT  20;

-- =============================================================================
-- STEP 3 — does the pair exist, and how far does the free tier actually go?
--
-- Asked as a coverage question rather than a dated slice. A free listing is a
-- sample of a paid one, and the sample is usually truncated in time -- so a
-- BETWEEN over our order window can return zero rows while the table is
-- perfectly healthy. Zero rows from a filter and zero rows from an empty table
-- look identical; MIN and MAX tell them apart.
-- =============================================================================
SELECT BASE_CURRENCY_ID,
       QUOTE_CURRENCY_ID,
       COUNT(*)   AS n,
       MIN(DATE)  AS from_d,
       MAX(DATE)  AS to_d
FROM   FINANCE__ECONOMICS.PUBLIC_DATA_FREE.FX_RATES_TIMESERIES
WHERE  BASE_CURRENCY_ID = 'INR'
GROUP  BY 1, 2
ORDER  BY n DESC
LIMIT  10;

-- The most recent rows for the pair, whenever they happen to be.
SELECT DATE, BASE_CURRENCY_ID, QUOTE_CURRENCY_ID, VALUE
FROM   FINANCE__ECONOMICS.PUBLIC_DATA_FREE.FX_RATES_TIMESERIES
WHERE  BASE_CURRENCY_ID = 'INR' AND QUOTE_CURRENCY_ID = 'USD'
ORDER  BY DATE DESC
LIMIT  5;

-- =============================================================================
-- STEP 4 — a view, not a table.
--
-- Copying eight weeks of rates into RAW would defeat the entire mechanism:
-- storage this account does not need, a refresh nobody owns, and a number that
-- silently stops matching the provider's. The view stays live by construction.
--
-- The one real trade: this account now depends on a share it does not control.
-- If the provider revokes it, every query through this view fails at once,
-- with no local copy to fall back on. That is the price of zero-copy, and it
-- is the right price here because an FX rate is reference data, not a fact.
-- =============================================================================
CREATE OR REPLACE VIEW RAW.V_FX_INR_USD
  COMMENT = 'mechanism 12 - live view over a Marketplace share. Nothing copied.'
AS
SELECT DATE                          AS RATE_DATE,
       BASE_CURRENCY_ID              AS BASE_CCY,
       QUOTE_CURRENCY_ID             AS QUOTE_CCY,
       VALUE                         AS RATE
FROM   FINANCE__ECONOMICS.PUBLIC_DATA_FREE.FX_RATES_TIMESERIES
WHERE  BASE_CURRENCY_ID = 'INR'
  AND  QUOTE_CURRENCY_ID = 'USD';

GRANT SELECT ON VIEW RAW.V_FX_INR_USD TO ROLE QC_ENGINEER;

-- =============================================================================
-- STEP 5 — verify, and prove it joins to our own data.
--
-- Paise -> rupees -> dollars, on the day the order was placed. This is the
-- whole reason for choosing this listing over a prettier one.
-- =============================================================================
SELECT COUNT(*) AS rate_days, MIN(RATE_DATE) AS from_d, MAX(RATE_DATE) AS to_d
FROM   RAW.V_FX_INR_USD;

-- ASOF JOIN, not an equi-join. Two reasons, and the second only showed up
-- once the share was actually mounted:
--
--   1. FX publishes on business days and orders do not. An equi-join silently
--      drops every weekend -- two days in seven, gone, with no error.
--   2. The free tier's history ends well before our order window. An equi-join
--      returns ZERO rows for that and looks exactly like a broken join.
--
-- ASOF handles both the same way: carry the last published rate forward. The
-- RATE_TAKEN_FROM column is the point -- it shows how stale the rate being
-- applied is, so a year-old rate is visible in the output rather than
-- indistinguishable from a fresh one. Silently dropping the rows would have
-- hidden the staleness; this surfaces it.
WITH daily AS (
  SELECT TO_DATE(PLACED_TS)      AS ORDER_DATE,
         COUNT(*)                AS ORDERS,
         SUM(ORDER_TOTAL_PAISE)  AS TOTAL_PAISE
  FROM   RAW.ORDER_BACKFILL
  GROUP  BY 1
)
SELECT d.ORDER_DATE,
       d.ORDERS,
       d.TOTAL_PAISE / 100.0                        AS INR,
       ROUND(d.TOTAL_PAISE / 100.0 * f.RATE, 2)     AS USD,
       f.RATE,
       f.RATE_DATE                                  AS RATE_TAKEN_FROM
FROM   daily d
ASOF JOIN RAW.V_FX_INR_USD f
  MATCH_CONDITION (d.ORDER_DATE >= f.RATE_DATE)
ORDER  BY d.ORDER_DATE DESC
LIMIT  10;

-- Sanity, not decoration: INR/USD sits near 0.011, so USD should be about a
-- hundredth of INR. If it comes back a hundred times larger the share stores
-- the pair the other way round and the view needs BASE and QUOTE swapped.

-- Storage this account is billed for, on account of the share: none.
SELECT COUNT(*) AS local_tables_created_by_mechanism_12
FROM   QCOMMERCE.INFORMATION_SCHEMA.TABLES
WHERE  TABLE_SCHEMA = 'RAW' AND TABLE_NAME LIKE '%FX%';   -- expect 0

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP VIEW IF EXISTS QCOMMERCE.RAW.V_FX_INR_USD;
-- Dropping the mounted database only unmounts the share:
-- DROP DATABASE IF EXISTS FINANCE__ECONOMICS;

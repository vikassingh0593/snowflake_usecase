-- =============================================================================
-- sql/p7_cdc_verify.sql — what actually landed from the seven CDC topics.
--
-- Run this BEFORE any CORE model is written. Three type bugs in this project so
-- far all had the same root cause: a shape asserted from assumption instead of
-- read off the source. The Debezium envelope is a stable contract, but the
-- column names inside `after` come from the Postgres DDL and the types come
-- from the converter settings, and neither is worth guessing.
--
-- COST: resumes WH_TRANSFORM_XS. Counts over ~171,000 VARIANT rows plus a few
-- single-row samples. Estimate under 0.01 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p07:cdc_verify';
USE DATABASE QCOMMERCE;
USE SCHEMA RAW;

-- =============================================================================
-- 1 — did every topic arrive, and at the expected depth?
--
-- A connector reporting RUNNING against an empty topic has been the wrong
-- answer every time in this project. These counts are the answer.
-- =============================================================================
SELECT 'CDC_DARK_STORES' AS tbl, COUNT(*) AS n FROM CDC_DARK_STORES
UNION ALL SELECT 'CDC_CUSTOMERS',   COUNT(*) FROM CDC_CUSTOMERS
UNION ALL SELECT 'CDC_PRODUCTS',    COUNT(*) FROM CDC_PRODUCTS
UNION ALL SELECT 'CDC_RIDERS',      COUNT(*) FROM CDC_RIDERS
UNION ALL SELECT 'CDC_INVENTORY',   COUNT(*) FROM CDC_INVENTORY
UNION ALL SELECT 'CDC_ORDERS',      COUNT(*) FROM CDC_ORDERS
UNION ALL SELECT 'CDC_ORDER_ITEMS', COUNT(*) FROM CDC_ORDER_ITEMS
ORDER BY n DESC;

-- Expected: 96,000 · 54,635 · 20,000 · 500 · 200 · 60 · 8  = 171,403

-- =============================================================================
-- 2 — the envelope, in full, for one row.
--
-- No ExtractNewRecordState transform is configured, so this should carry
-- before, after, op, source and ts_ms. If it carries only the row's columns,
-- the transform is on somewhere and the before-image SCD2 needs is gone.
-- =============================================================================
SELECT RECORD_CONTENT
FROM   CDC_CUSTOMERS
LIMIT  1;

SELECT OBJECT_KEYS(RECORD_CONTENT) AS envelope_keys
FROM   CDC_CUSTOMERS
LIMIT  1;

-- =============================================================================
-- 3 — the column names inside `after`, per table.
--
-- This is the contract CORE will be written against. Read it; do not assume it
-- matches the Postgres DDL letter for letter.
-- =============================================================================
SELECT 'dark_stores' AS src, OBJECT_KEYS(RECORD_CONTENT:after) AS cols FROM CDC_DARK_STORES LIMIT 1;
SELECT 'customers'   AS src, OBJECT_KEYS(RECORD_CONTENT:after) AS cols FROM CDC_CUSTOMERS   LIMIT 1;
SELECT 'products'    AS src, OBJECT_KEYS(RECORD_CONTENT:after) AS cols FROM CDC_PRODUCTS    LIMIT 1;
SELECT 'riders'      AS src, OBJECT_KEYS(RECORD_CONTENT:after) AS cols FROM CDC_RIDERS      LIMIT 1;
SELECT 'orders'      AS src, OBJECT_KEYS(RECORD_CONTENT:after) AS cols FROM CDC_ORDERS      LIMIT 1;
SELECT 'order_items' AS src, OBJECT_KEYS(RECORD_CONTENT:after) AS cols FROM CDC_ORDER_ITEMS LIMIT 1;
SELECT 'inventory'   AS src, OBJECT_KEYS(RECORD_CONTENT:after) AS cols FROM CDC_INVENTORY   LIMIT 1;

-- =============================================================================
-- 4 — how the values are typed on the way through.
--
-- decimal.handling.mode = string and time.precision.mode = connect in the
-- Debezium config, so money and timestamps do NOT arrive as you might expect.
-- These two rows decide how CORE casts every column of every table.
-- =============================================================================
SELECT RECORD_CONTENT:after:order_id          AS order_id,
       TYPEOF(RECORD_CONTENT:after:order_id)  AS t_order_id,
       RECORD_CONTENT:after:order_total_paise AS total_paise,
       TYPEOF(RECORD_CONTENT:after:order_total_paise) AS t_total,
       RECORD_CONTENT:after:placed_ts         AS placed_ts,
       TYPEOF(RECORD_CONTENT:after:placed_ts) AS t_placed,
       RECORD_CONTENT:after:status            AS status
FROM   CDC_ORDERS
LIMIT  3;

SELECT RECORD_CONTENT:after:lat         AS lat,
       TYPEOF(RECORD_CONTENT:after:lat) AS t_lat,
       RECORD_CONTENT:after:opened_on   AS opened_on,
       TYPEOF(RECORD_CONTENT:after:opened_on) AS t_opened_on
FROM   CDC_DARK_STORES
LIMIT  3;

-- =============================================================================
-- 5 — operation mix.
--
-- snapshot.mode = initial, and nothing has written to Postgres since, so every
-- row should be op = 'r' (snapshot read). Any 'c', 'u' or 'd' means the source
-- changed after the snapshot -- interesting, but it changes what SCD2 sees.
-- =============================================================================
SELECT RECORD_CONTENT:op::STRING AS op, COUNT(*) AS n
FROM   CDC_ORDERS
GROUP  BY 1 ORDER BY 2 DESC;

-- A snapshot read has no before-image by definition. This is the number that
-- says whether SCD2 has anything to compare against yet, or whether a change
-- has to be made in Postgres first to produce one.
SELECT COUNT(*)                                        AS rows_total,
       SUM(IFF(RECORD_CONTENT:before IS NULL, 1, 0))   AS no_before_image,
       SUM(IFF(RECORD_CONTENT:after  IS NULL, 1, 0))   AS no_after_image
FROM   CDC_CUSTOMERS;

-- =============================================================================
-- 6 — what the connector recorded about delivery.
--
-- Topic, partition and offset per row. This is the idempotency key for CDC:
-- (topic, partition, offset) is unique by construction, which is what CORE
-- dedupes on when a redelivery happens.
-- =============================================================================
SELECT RECORD_METADATA
FROM   CDC_ORDERS
LIMIT  1;

SELECT RECORD_METADATA:topic::STRING      AS topic,
       RECORD_METADATA:partition::INT     AS part,
       COUNT(*)                           AS n,
       MIN(RECORD_METADATA:offset::NUMBER) AS min_offset,
       MAX(RECORD_METADATA:offset::NUMBER) AS max_offset,
       COUNT(DISTINCT RECORD_METADATA:offset::NUMBER) AS distinct_offsets
FROM   CDC_ORDERS
GROUP  BY 1, 2
ORDER  BY 2;

-- distinct_offsets < n on any partition means a redelivery already happened,
-- which is the at-least-once guarantee behaving exactly as documented.

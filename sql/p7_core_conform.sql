-- =============================================================================
-- sql/p7_core_conform.sql — Part 7: RAW -> CORE conformance and dedupe.
--
-- The first job CORE has is the one RAW deliberately refused. RAW holds what
-- arrived: VARIANT payloads, at-least-once duplicates, the same 79,663 events
-- stored three times over, timestamps as strings and dates as integers. CORE is
-- where that becomes one typed, deduplicated set of business entities.
--
-- Every cast below was read off sql/p7_cdc_verify.sql, not assumed. Two of them
-- are not what a reader would guess:
--
--   placed_ts, created_at, updated_at   VARCHAR   ISO-8601 string
--   opened_on, joined_on, snapshot_date INTEGER   DAYS SINCE EPOCH
--
-- Both come from the same connector with the same settings. TIMESTAMP arrives
-- as a string and DATE as an integer, so `::DATE` is wrong on either.
--
-- COST: resumes WH_TRANSFORM_XS. Roughly 250,000 VARIANT rows shredded into
-- eight typed tables. Estimate 0.03-0.06 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p07:core_conform';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — are the three ingestion mechanisms actually identical?
--
-- Mechanisms 1, 2 and 3 carried the same topic into three tables so their cost
-- and latency could be compared on constant input. That comparison is only
-- valid if the PAYLOADS are identical, which has been asserted all project and
-- never checked. Checking it is the precondition for picking one as canonical
-- and dropping the other two from the lineage.
-- =============================================================================
WITH ids AS (
  SELECT 'v4_streaming'  AS src, RECORD_CONTENT:event_id::STRING AS event_id FROM RAW.ORDER_STATUS_KAFKA_V4
  UNION ALL
  SELECT 'sdk_direct',          RECORD_CONTENT:event_id::STRING           FROM RAW.ORDER_STATUS_SDK
  UNION ALL
  SELECT 'v3_file_mode',        RECORD_CONTENT:event_id::STRING           FROM RAW.ORDER_STATUS_KAFKA_V3FILE
)
SELECT src,
       COUNT(*)                  AS rows_landed,
       COUNT(DISTINCT event_id)  AS distinct_events,
       COUNT(*) - COUNT(DISTINCT event_id) AS duplicate_rows
FROM   ids
GROUP  BY src
ORDER  BY src;

-- Set difference, both directions. Equal counts with different members would
-- pass a COUNT check and fail here, which is the point.
SELECT
  (SELECT COUNT(DISTINCT RECORD_CONTENT:event_id::STRING) FROM RAW.ORDER_STATUS_KAFKA_V4)     AS v4_ids,
  (SELECT COUNT(*) FROM (
     SELECT DISTINCT RECORD_CONTENT:event_id::STRING AS id FROM RAW.ORDER_STATUS_KAFKA_V4
     MINUS
     SELECT DISTINCT RECORD_CONTENT:event_id::STRING FROM RAW.ORDER_STATUS_SDK))              AS in_v4_not_sdk,
  (SELECT COUNT(*) FROM (
     SELECT DISTINCT RECORD_CONTENT:event_id::STRING AS id FROM RAW.ORDER_STATUS_SDK
     MINUS
     SELECT DISTINCT RECORD_CONTENT:event_id::STRING FROM RAW.ORDER_STATUS_KAFKA_V4))         AS in_sdk_not_v4,
  (SELECT COUNT(*) FROM (
     SELECT DISTINCT RECORD_CONTENT:event_id::STRING AS id FROM RAW.ORDER_STATUS_KAFKA_V3FILE
     MINUS
     SELECT DISTINCT RECORD_CONTENT:event_id::STRING FROM RAW.ORDER_STATUS_KAFKA_V4))         AS in_v3_not_v4;

-- =============================================================================
-- STEP 2 — CORE.ORDER_STATUS_EVENT, deduplicated.
--
-- The generator injected 1% duplicates on purpose, because at-least-once is
-- what a real rider app delivers. Neither offset tokens nor Snowpipe's file
-- registry can remove them: both protect against TRANSPORT duplication, and
-- these were emitted twice by the producer. The consumer is the only layer that
-- can see them, which is why dedupe is CORE's job and not ingestion's.
--
-- QUALIFY rather than a subquery with ROW_NUMBER: one line, and the window
-- function stays where it is evaluated instead of being wrapped in a scan.
--
-- v4 is canonical. Any of the three would do -- STEP 1 proves that -- and the
-- newest mechanism is the one worth carrying forward.
-- =============================================================================
CREATE OR REPLACE TABLE CORE.ORDER_STATUS_EVENT AS
SELECT
  RECORD_CONTENT:event_id::STRING                          AS EVENT_ID,
  RECORD_CONTENT:order_id::NUMBER                          AS ORDER_ID,
  RECORD_CONTENT:store_id::NUMBER                          AS STORE_ID,
  RECORD_CONTENT:rider_id::NUMBER                          AS RIDER_ID,
  RECORD_CONTENT:from_status::STRING                       AS FROM_STATUS,
  RECORD_CONTENT:to_status::STRING                         AS TO_STATUS,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:event_ts::STRING)        AS EVENT_TS,
  RECORD_CONTENT:source::STRING                            AS SOURCE_APP,
  RECORD_CONTENT:meta:app_version::STRING                  AS APP_VERSION,
  RECORD_CONTENT:meta:network::STRING                      AS NETWORK,
  RECORD_CONTENT:meta                                      AS META,
  CURRENT_TIMESTAMP()                                      AS CONFORMED_TS
FROM RAW.ORDER_STATUS_KAFKA_V4
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY RECORD_CONTENT:event_id::STRING
          ORDER BY TO_TIMESTAMP_NTZ(RECORD_CONTENT:event_ts::STRING)
        ) = 1;

-- =============================================================================
-- STEP 3 — the seven CDC tables, typed.
--
-- One pattern, applied seven times:
--
--   key    COALESCE(after:<pk>, before:<pk>) -- a delete carries no `after`, so
--                                              keying off `after` alone silently
--                                              drops the row that records it
--   rank   latest wins, by ts_ms then offset -- offset breaks ties inside a
--                                              millisecond, which ts_ms cannot
--   filter op <> 'd' AFTER ranking          -- so a delete suppresses the row
--                                              rather than resurrecting the
--                                              version before it
--
-- Every row here is op = 'r' today: a snapshot, no updates yet. The pattern is
-- written for the general case anyway, because the first UPDATE in Postgres is
-- what SCD2 needs and it must not require rewriting this file.
-- =============================================================================

CREATE OR REPLACE TABLE CORE.STORE AS
SELECT
  RECORD_CONTENT:after:store_id::NUMBER                                  AS STORE_ID,
  RECORD_CONTENT:after:store_code::STRING                                AS STORE_CODE,
  RECORD_CONTENT:after:city::STRING                                      AS CITY,
  RECORD_CONTENT:after:pincode::STRING                                   AS PINCODE,
  RECORD_CONTENT:after:lat::FLOAT                                        AS LAT,
  RECORD_CONTENT:after:lon::FLOAT                                        AS LON,
  DATEADD(day, RECORD_CONTENT:after:opened_on::INT, '1970-01-01'::DATE)  AS OPENED_ON,
  RECORD_CONTENT:after:is_active::BOOLEAN                                AS IS_ACTIVE,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:ts_ms::NUMBER, 3)                      AS CDC_TS,
  CURRENT_TIMESTAMP()                                                    AS CONFORMED_TS
FROM RAW.CDC_DARK_STORES
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY COALESCE(RECORD_CONTENT:after:store_id, RECORD_CONTENT:before:store_id)::NUMBER
          ORDER BY RECORD_CONTENT:ts_ms::NUMBER DESC, RECORD_METADATA:offset::NUMBER DESC) = 1;
DELETE FROM CORE.STORE WHERE STORE_ID IS NULL;

CREATE OR REPLACE TABLE CORE.CUSTOMER AS
SELECT
  RECORD_CONTENT:after:customer_id::NUMBER                     AS CUSTOMER_ID,
  RECORD_CONTENT:after:full_name::STRING                       AS FULL_NAME,
  RECORD_CONTENT:after:email::STRING                           AS EMAIL,
  RECORD_CONTENT:after:phone::STRING                           AS PHONE,
  RECORD_CONTENT:after:segment::STRING                         AS SEGMENT,
  RECORD_CONTENT:after:home_pincode::STRING                    AS HOME_PINCODE,
  RECORD_CONTENT:after:home_lat::FLOAT                         AS HOME_LAT,
  RECORD_CONTENT:after:home_lon::FLOAT                         AS HOME_LON,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:after:created_at::STRING)    AS CREATED_AT,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:ts_ms::NUMBER, 3)            AS CDC_TS,
  CURRENT_TIMESTAMP()                                          AS CONFORMED_TS
FROM RAW.CDC_CUSTOMERS
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY COALESCE(RECORD_CONTENT:after:customer_id, RECORD_CONTENT:before:customer_id)::NUMBER
          ORDER BY RECORD_CONTENT:ts_ms::NUMBER DESC, RECORD_METADATA:offset::NUMBER DESC) = 1;
DELETE FROM CORE.CUSTOMER WHERE CUSTOMER_ID IS NULL;

CREATE OR REPLACE TABLE CORE.PRODUCT AS
SELECT
  RECORD_CONTENT:after:product_id::NUMBER                      AS PRODUCT_ID,
  RECORD_CONTENT:after:sku::STRING                             AS SKU,
  RECORD_CONTENT:after:name::STRING                            AS PRODUCT_NAME,
  RECORD_CONTENT:after:category_l1::STRING                     AS CATEGORY_L1,
  RECORD_CONTENT:after:category_l2::STRING                     AS CATEGORY_L2,
  RECORD_CONTENT:after:category_l3::STRING                     AS CATEGORY_L3,
  RECORD_CONTENT:after:price_paise::NUMBER                     AS PRICE_PAISE,
  RECORD_CONTENT:after:is_active::BOOLEAN                      AS IS_ACTIVE,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:after:updated_at::STRING)    AS UPDATED_AT,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:ts_ms::NUMBER, 3)            AS CDC_TS,
  CURRENT_TIMESTAMP()                                          AS CONFORMED_TS
FROM RAW.CDC_PRODUCTS
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY COALESCE(RECORD_CONTENT:after:product_id, RECORD_CONTENT:before:product_id)::NUMBER
          ORDER BY RECORD_CONTENT:ts_ms::NUMBER DESC, RECORD_METADATA:offset::NUMBER DESC) = 1;
DELETE FROM CORE.PRODUCT WHERE PRODUCT_ID IS NULL;

CREATE OR REPLACE TABLE CORE.RIDER AS
SELECT
  RECORD_CONTENT:after:rider_id::NUMBER                                  AS RIDER_ID,
  RECORD_CONTENT:after:full_name::STRING                                 AS FULL_NAME,
  RECORD_CONTENT:after:phone::STRING                                     AS PHONE,
  RECORD_CONTENT:after:vehicle_type::STRING                              AS VEHICLE_TYPE,
  RECORD_CONTENT:after:store_id::NUMBER                                  AS STORE_ID,
  RECORD_CONTENT:after:shift::STRING                                     AS SHIFT,
  RECORD_CONTENT:after:is_active::BOOLEAN                                AS IS_ACTIVE,
  DATEADD(day, RECORD_CONTENT:after:joined_on::INT, '1970-01-01'::DATE)  AS JOINED_ON,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:ts_ms::NUMBER, 3)                      AS CDC_TS,
  CURRENT_TIMESTAMP()                                                    AS CONFORMED_TS
FROM RAW.CDC_RIDERS
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY COALESCE(RECORD_CONTENT:after:rider_id, RECORD_CONTENT:before:rider_id)::NUMBER
          ORDER BY RECORD_CONTENT:ts_ms::NUMBER DESC, RECORD_METADATA:offset::NUMBER DESC) = 1;
DELETE FROM CORE.RIDER WHERE RIDER_ID IS NULL;

-- ORDER_HEADER, not ORDER. ORDER is reserved -- the fourth reserved-word
-- collision in this project after rows, check and sample.
CREATE OR REPLACE TABLE CORE.ORDER_HEADER AS
SELECT
  RECORD_CONTENT:after:order_id::NUMBER                         AS ORDER_ID,
  RECORD_CONTENT:after:customer_id::NUMBER                      AS CUSTOMER_ID,
  RECORD_CONTENT:after:store_id::NUMBER                         AS STORE_ID,
  RECORD_CONTENT:after:rider_id::NUMBER                         AS RIDER_ID,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:after:placed_ts::STRING)      AS PLACED_TS,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:after:promised_ts::STRING)    AS PROMISED_TS,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:after:packed_ts::STRING)      AS PACKED_TS,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:after:picked_up_ts::STRING)   AS PICKED_UP_TS,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:after:delivered_ts::STRING)   AS DELIVERED_TS,
  RECORD_CONTENT:after:status::STRING                           AS STATUS,
  RECORD_CONTENT:after:payment_method::STRING                   AS PAYMENT_METHOD,
  RECORD_CONTENT:after:coupon_code::STRING                      AS COUPON_CODE,
  RECORD_CONTENT:after:item_count::NUMBER                       AS ITEM_COUNT,
  RECORD_CONTENT:after:gross_paise::NUMBER                      AS GROSS_PAISE,
  RECORD_CONTENT:after:discount_paise::NUMBER                   AS DISCOUNT_PAISE,
  RECORD_CONTENT:after:delivery_fee_paise::NUMBER               AS DELIVERY_FEE_PAISE,
  RECORD_CONTENT:after:order_total_paise::NUMBER                AS ORDER_TOTAL_PAISE,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:ts_ms::NUMBER, 3)             AS CDC_TS,
  CURRENT_TIMESTAMP()                                           AS CONFORMED_TS
FROM RAW.CDC_ORDERS
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY COALESCE(RECORD_CONTENT:after:order_id, RECORD_CONTENT:before:order_id)::NUMBER
          ORDER BY RECORD_CONTENT:ts_ms::NUMBER DESC, RECORD_METADATA:offset::NUMBER DESC) = 1;
DELETE FROM CORE.ORDER_HEADER WHERE ORDER_ID IS NULL;

CREATE OR REPLACE TABLE CORE.ORDER_ITEM AS
SELECT
  RECORD_CONTENT:after:order_item_id::NUMBER       AS ORDER_ITEM_ID,
  RECORD_CONTENT:after:order_id::NUMBER            AS ORDER_ID,
  RECORD_CONTENT:after:product_id::NUMBER          AS PRODUCT_ID,
  RECORD_CONTENT:after:qty::NUMBER                 AS QTY,
  RECORD_CONTENT:after:unit_price_paise::NUMBER    AS UNIT_PRICE_PAISE,
  RECORD_CONTENT:after:line_total_paise::NUMBER    AS LINE_TOTAL_PAISE,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:ts_ms::NUMBER, 3) AS CDC_TS,
  CURRENT_TIMESTAMP()                              AS CONFORMED_TS
FROM RAW.CDC_ORDER_ITEMS
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY COALESCE(RECORD_CONTENT:after:order_item_id, RECORD_CONTENT:before:order_item_id)::NUMBER
          ORDER BY RECORD_CONTENT:ts_ms::NUMBER DESC, RECORD_METADATA:offset::NUMBER DESC) = 1;
DELETE FROM CORE.ORDER_ITEM WHERE ORDER_ITEM_ID IS NULL;

-- Composite key: inventory is a periodic snapshot at store x product x day.
CREATE OR REPLACE TABLE CORE.INVENTORY_DAILY AS
SELECT
  DATEADD(day, RECORD_CONTENT:after:snapshot_date::INT, '1970-01-01'::DATE) AS SNAPSHOT_DATE,
  RECORD_CONTENT:after:store_id::NUMBER              AS STORE_ID,
  RECORD_CONTENT:after:product_id::NUMBER            AS PRODUCT_ID,
  RECORD_CONTENT:after:on_hand_qty::NUMBER           AS ON_HAND_QTY,
  RECORD_CONTENT:after:reorder_level::NUMBER         AS REORDER_LEVEL,
  TO_TIMESTAMP_NTZ(RECORD_CONTENT:ts_ms::NUMBER, 3)  AS CDC_TS,
  CURRENT_TIMESTAMP()                                AS CONFORMED_TS
FROM RAW.CDC_INVENTORY
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY COALESCE(RECORD_CONTENT:after:snapshot_date, RECORD_CONTENT:before:snapshot_date)::INT,
                       COALESCE(RECORD_CONTENT:after:store_id,      RECORD_CONTENT:before:store_id)::NUMBER,
                       COALESCE(RECORD_CONTENT:after:product_id,    RECORD_CONTENT:before:product_id)::NUMBER
          ORDER BY RECORD_CONTENT:ts_ms::NUMBER DESC, RECORD_METADATA:offset::NUMBER DESC) = 1;
DELETE FROM CORE.INVENTORY_DAILY WHERE STORE_ID IS NULL;

-- =============================================================================
-- STEP 4 — verify. Counts against a known expectation, never a bare zero.
-- =============================================================================
SELECT 'STORE'              AS tbl, COUNT(*) AS n, 8      AS expected FROM CORE.STORE
UNION ALL SELECT 'CUSTOMER',       COUNT(*), 500          FROM CORE.CUSTOMER
UNION ALL SELECT 'PRODUCT',        COUNT(*), 200          FROM CORE.PRODUCT
UNION ALL SELECT 'RIDER',          COUNT(*), 60           FROM CORE.RIDER
UNION ALL SELECT 'ORDER_HEADER',   COUNT(*), 20000        FROM CORE.ORDER_HEADER
UNION ALL SELECT 'ORDER_ITEM',     COUNT(*), 54635        FROM CORE.ORDER_ITEM
UNION ALL SELECT 'INVENTORY_DAILY',COUNT(*), 96000        FROM CORE.INVENTORY_DAILY
ORDER BY n DESC;

-- The dedupe, stated as a number. RAW holds the duplicates by design; if these
-- are equal, QUALIFY removed nothing and the 1% injected duplicates are still
-- in CORE.
SELECT (SELECT COUNT(*) FROM RAW.ORDER_STATUS_KAFKA_V4) AS raw_rows,
       (SELECT COUNT(*) FROM CORE.ORDER_STATUS_EVENT)   AS core_rows,
       (SELECT COUNT(*) FROM RAW.ORDER_STATUS_KAFKA_V4)
         - (SELECT COUNT(*) FROM CORE.ORDER_STATUS_EVENT) AS duplicates_removed,
       ROUND(100.0 * ((SELECT COUNT(*) FROM RAW.ORDER_STATUS_KAFKA_V4)
         - (SELECT COUNT(*) FROM CORE.ORDER_STATUS_EVENT))
         / (SELECT COUNT(*) FROM RAW.ORDER_STATUS_KAFKA_V4), 2) AS pct_removed;

-- Did the date decode land in the right century? 20353 is 2025-09-22, not 1970.
SELECT MIN(OPENED_ON) AS earliest_store, MAX(OPENED_ON) AS latest_store FROM CORE.STORE;
SELECT MIN(SNAPSHOT_DATE) AS from_d, MAX(SNAPSHOT_DATE) AS to_d,
       COUNT(DISTINCT SNAPSHOT_DATE) AS days FROM CORE.INVENTORY_DAILY;

-- Timestamps parsed, not silently nulled. TO_TIMESTAMP_NTZ on a string it
-- cannot read raises; on a JSON null it returns NULL, which is correct for a
-- cancelled order that was never delivered.
SELECT COUNT(*) AS orders,
       COUNT(PLACED_TS)    AS with_placed,
       COUNT(DELIVERED_TS) AS with_delivered,
       SUM(IFF(STATUS = 'CANCELLED', 1, 0)) AS cancelled,
       MIN(PLACED_TS) AS from_ts, MAX(PLACED_TS) AS to_ts
FROM   CORE.ORDER_HEADER;

-- Referential integrity across conformed tables. This is the first moment the
-- pieces have ever been joinable, so it is the first moment this can be asked.
SELECT
  (SELECT COUNT(*) FROM CORE.ORDER_HEADER o
     LEFT JOIN CORE.CUSTOMER c USING (CUSTOMER_ID) WHERE c.CUSTOMER_ID IS NULL) AS orders_without_customer,
  (SELECT COUNT(*) FROM CORE.ORDER_HEADER o
     LEFT JOIN CORE.STORE s USING (STORE_ID) WHERE s.STORE_ID IS NULL)          AS orders_without_store,
  (SELECT COUNT(*) FROM CORE.ORDER_ITEM i
     LEFT JOIN CORE.ORDER_HEADER o USING (ORDER_ID) WHERE o.ORDER_ID IS NULL)   AS items_without_order,
  (SELECT COUNT(*) FROM CORE.ORDER_ITEM i
     LEFT JOIN CORE.PRODUCT p USING (PRODUCT_ID) WHERE p.PRODUCT_ID IS NULL)    AS items_without_product,
  (SELECT COUNT(*) FROM CORE.ORDER_STATUS_EVENT e
     LEFT JOIN CORE.ORDER_HEADER o USING (ORDER_ID) WHERE o.ORDER_ID IS NULL)   AS events_without_order;

-- The money identity. gross - discount + delivery = total, in whole paise, with
-- no rounding argument available because nothing here is a float.
SELECT COUNT(*) AS orders,
       SUM(IFF(GROSS_PAISE - DISCOUNT_PAISE + DELIVERY_FEE_PAISE = ORDER_TOTAL_PAISE, 0, 1)) AS money_mismatches
FROM   CORE.ORDER_HEADER;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.ORDER_STATUS_EVENT;
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.STORE;
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.CUSTOMER;
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.PRODUCT;
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.RIDER;
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.ORDER_HEADER;
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.ORDER_ITEM;
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.INVENTORY_DAILY;

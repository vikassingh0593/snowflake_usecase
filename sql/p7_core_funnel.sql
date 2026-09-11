-- =============================================================================
-- sql/p7_core_funnel.sql — Part 7c: MATCH_RECOGNIZE, the last two stream types,
-- and quality results.
--
-- The generator injected two kinds of lifecycle defect into 2% of orders, and
-- they need different detection:
--
--   skipped       a middle transition is missing entirely
--                 PLACED -> PICKED_UP -> DELIVERED
--   out of order  a middle transition's timestamp is pushed 9 minutes later,
--                 so ordering by event_ts reverses two steps
--                 PLACED -> PICKED_UP -> PACKED -> DELIVERED
--
-- One strict pattern catches both, because both break the sequence. What tells
-- them apart is the SET of statuses present: complete but misordered against
-- genuinely missing. A window-function version of this is about twenty lines
-- and reads like arithmetic; MATCH_RECOGNIZE states the sequence directly.
--
-- COST: resumes WH_TRANSFORM_XS. Pattern matching over 78,874 events, plus two
-- streams and a handful of checks. Estimate 0.02-0.04 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p07:core_funnel';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 0 — the vocabulary, read rather than assumed.
-- =============================================================================
SELECT TO_STATUS, COUNT(*) AS n, COUNT(DISTINCT ORDER_ID) AS orders
FROM   CORE.ORDER_STATUS_EVENT
GROUP  BY TO_STATUS
ORDER  BY n DESC;

-- =============================================================================
-- STEP 1 — the happy path, matched strictly.
--
-- AFTER MATCH SKIP PAST LAST ROW: an order's lifecycle happens once, so there
-- is no reason to look for overlapping matches inside it. The default
-- (SKIP TO NEXT ROW) would re-scan from the second event of every match.
-- =============================================================================
CREATE OR REPLACE TABLE CORE.ORDER_FUNNEL AS
SELECT *
FROM   CORE.ORDER_STATUS_EVENT
MATCH_RECOGNIZE (
  PARTITION BY ORDER_ID
  ORDER BY EVENT_TS
  MEASURES
    FIRST(P.EVENT_TS)                                  AS PLACED_TS,
    FIRST(K.EVENT_TS)                                  AS PACKED_TS,
    FIRST(U.EVENT_TS)                                  AS PICKED_UP_TS,
    FIRST(D.EVENT_TS)                                  AS DELIVERED_TS,
    DATEDIFF(second, FIRST(P.EVENT_TS), FIRST(K.EVENT_TS)) AS PACK_SEC,
    DATEDIFF(second, FIRST(K.EVENT_TS), FIRST(U.EVENT_TS)) AS PICK_SEC,
    DATEDIFF(second, FIRST(U.EVENT_TS), FIRST(D.EVENT_TS)) AS RIDE_SEC,
    DATEDIFF(second, FIRST(P.EVENT_TS), FIRST(D.EVENT_TS)) AS TOTAL_SEC,
    COUNT(*)                                           AS STEPS
  ONE ROW PER MATCH
  AFTER MATCH SKIP PAST LAST ROW
  PATTERN (P K U D)
  DEFINE
    P AS TO_STATUS = 'PLACED',
    K AS TO_STATUS = 'PACKED',
    U AS TO_STATUS = 'PICKED_UP',
    D AS TO_STATUS = 'DELIVERED'
);

SELECT COUNT(*) AS clean_funnels FROM CORE.ORDER_FUNNEL;

-- =============================================================================
-- STEP 2 — the cancellations, as their own pattern.
--
-- PATTERN (P K? C) with K optional: an order can be cancelled before or after
-- packing, and a single pattern covers both rather than a UNION of two.
-- =============================================================================
CREATE OR REPLACE TABLE CORE.ORDER_CANCELLED AS
SELECT *
FROM   CORE.ORDER_STATUS_EVENT
MATCH_RECOGNIZE (
  PARTITION BY ORDER_ID
  ORDER BY EVENT_TS
  MEASURES
    FIRST(P.EVENT_TS)                                      AS PLACED_TS,
    FIRST(C.EVENT_TS)                                      AS CANCELLED_TS,
    COUNT(K.*)                                             AS WAS_PACKED,
    DATEDIFF(second, FIRST(P.EVENT_TS), FIRST(C.EVENT_TS)) AS TO_CANCEL_SEC
  ONE ROW PER MATCH
  AFTER MATCH SKIP PAST LAST ROW
  PATTERN (P K? C)
  DEFINE
    P AS TO_STATUS = 'PLACED',
    K AS TO_STATUS = 'PACKED',
    C AS TO_STATUS = 'CANCELLED'
);

SELECT COUNT(*)                        AS cancelled_orders,
       SUM(IFF(WAS_PACKED > 0, 1, 0))  AS cancelled_after_packing,
       ROUND(AVG(TO_CANCEL_SEC) / 60.0, 1) AS avg_minutes_to_cancel
FROM   CORE.ORDER_CANCELLED;

-- =============================================================================
-- STEP 3 — the anomalies: everything the patterns did not claim.
--
-- An order with events but no clean funnel and no cancellation is defective.
-- Classifying by the SET of statuses present separates the two injected kinds:
-- all four present means the sequence was misordered, fewer means a transition
-- never arrived.
-- =============================================================================
CREATE OR REPLACE TABLE CORE.ORDER_LIFECYCLE_ANOMALY AS
WITH per_order AS (
  SELECT ORDER_ID,
         COUNT(*)                                                     AS EVENTS,
         ARRAY_AGG(TO_STATUS) WITHIN GROUP (ORDER BY EVENT_TS)        AS SEQUENCE_BY_TS,
         BOOLOR_AGG(TO_STATUS = 'PLACED')                             AS HAS_PLACED,
         BOOLOR_AGG(TO_STATUS = 'PACKED')                             AS HAS_PACKED,
         BOOLOR_AGG(TO_STATUS = 'PICKED_UP')                          AS HAS_PICKED,
         BOOLOR_AGG(TO_STATUS = 'DELIVERED')                          AS HAS_DELIVERED,
         BOOLOR_AGG(TO_STATUS = 'CANCELLED')                          AS HAS_CANCELLED,
         MIN(EVENT_TS)                                                AS FIRST_TS,
         MAX(EVENT_TS)                                                AS LAST_TS
  FROM   CORE.ORDER_STATUS_EVENT
  GROUP  BY ORDER_ID
)
SELECT o.*,
       CASE
         WHEN o.HAS_PLACED AND o.HAS_PACKED AND o.HAS_PICKED AND o.HAS_DELIVERED
           THEN 'OUT_OF_ORDER'
         WHEN o.HAS_DELIVERED THEN 'SKIPPED_TRANSITION'
         ELSE 'INCOMPLETE'
       END AS ANOMALY_TYPE,
       CURRENT_TIMESTAMP() AS DETECTED_TS
FROM   per_order o
WHERE  o.ORDER_ID NOT IN (SELECT ORDER_ID FROM CORE.ORDER_FUNNEL)
  AND  o.ORDER_ID NOT IN (SELECT ORDER_ID FROM CORE.ORDER_CANCELLED);

SELECT ANOMALY_TYPE, COUNT(*) AS orders FROM CORE.ORDER_LIFECYCLE_ANOMALY
GROUP BY 1 ORDER BY 2 DESC;

-- Every order accounted for exactly once. This is the check that matters:
-- three tables partitioning 20,000 orders with nothing double-counted and
-- nothing lost.
SELECT (SELECT COUNT(DISTINCT ORDER_ID) FROM CORE.ORDER_STATUS_EVENT)    AS orders_with_events,
       (SELECT COUNT(*) FROM CORE.ORDER_FUNNEL)                          AS clean,
       (SELECT COUNT(*) FROM CORE.ORDER_CANCELLED)                       AS cancelled,
       (SELECT COUNT(*) FROM CORE.ORDER_LIFECYCLE_ANOMALY)               AS anomalous,
       (SELECT COUNT(*) FROM CORE.ORDER_FUNNEL)
         + (SELECT COUNT(*) FROM CORE.ORDER_CANCELLED)
         + (SELECT COUNT(*) FROM CORE.ORDER_LIFECYCLE_ANOMALY)           AS total_classified;

-- A misordered order, shown as the sequence the timestamps actually give.
SELECT ORDER_ID, SEQUENCE_BY_TS, ANOMALY_TYPE
FROM   CORE.ORDER_LIFECYCLE_ANOMALY
ORDER  BY ANOMALY_TYPE, ORDER_ID
LIMIT  6;

-- =============================================================================
-- STEP 4 — SLA, computed from the funnel rather than from the order header.
--
-- The header carries a delivered_ts written by the application. The funnel
-- carries one derived from the event stream. They should agree, and where they
-- do not, the event stream is the record of what happened.
-- =============================================================================
SELECT COUNT(*)                                                  AS matched_orders,
       SUM(IFF(f.DELIVERED_TS > o.PROMISED_TS, 1, 0))            AS breached,
       ROUND(100.0 * SUM(IFF(f.DELIVERED_TS > o.PROMISED_TS, 1, 0)) / COUNT(*), 2) AS breach_pct,
       SUM(IFF(ABS(DATEDIFF(second, f.DELIVERED_TS, o.DELIVERED_TS)) > 1, 1, 0))   AS header_vs_events_disagree
FROM   CORE.ORDER_FUNNEL f
JOIN   CORE.ORDER_HEADER o USING (ORDER_ID);

-- Median and 95th percentile of each leg, in seconds.
SELECT ROUND(MEDIAN(PACK_SEC))  AS p50_pack,
       ROUND(MEDIAN(PICK_SEC))  AS p50_pick,
       ROUND(MEDIAN(RIDE_SEC))  AS p50_ride,
       ROUND(MEDIAN(TOTAL_SEC)) AS p50_total,
       ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TOTAL_SEC)) AS p95_total
FROM   CORE.ORDER_FUNNEL;

-- =============================================================================
-- STEP 5 — the last two stream types.
--
-- Append-only on the event table: events are never updated, so there is no
-- reason to pay for before-images. That is the entire difference from the
-- standard stream in p7_core_scd2.sql, and on a high-volume table it is the
-- difference that matters.
-- =============================================================================
CREATE STREAM IF NOT EXISTS CORE.STR_EVENTS_APPEND
  ON TABLE CORE.ORDER_STATUS_EVENT
  APPEND_ONLY = TRUE;

-- A stream on a VIEW tracks changes flowing THROUGH the view without
-- materialising it. Change tracking has to be on for every underlying table --
-- a stream on a table enables it implicitly, a stream on a view does not.
ALTER TABLE CORE.ORDER_HEADER SET CHANGE_TRACKING = TRUE;
ALTER TABLE CORE.CUSTOMER     SET CHANGE_TRACKING = TRUE;
ALTER TABLE CORE.STORE        SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE VIEW CORE.V_ORDER_ENRICHED AS
SELECT o.ORDER_ID, o.PLACED_TS, o.PROMISED_TS, o.DELIVERED_TS, o.STATUS,
       o.ORDER_TOTAL_PAISE, o.ITEM_COUNT,
       c.SEGMENT      AS CUSTOMER_SEGMENT,
       c.HOME_PINCODE AS CUSTOMER_PINCODE,
       s.STORE_CODE, s.CITY, s.LAT AS STORE_LAT, s.LON AS STORE_LON
FROM   CORE.ORDER_HEADER o
JOIN   CORE.CUSTOMER c USING (CUSTOMER_ID)
JOIN   CORE.STORE    s USING (STORE_ID);

CREATE STREAM IF NOT EXISTS CORE.STR_ORDER_ENRICHED ON VIEW CORE.V_ORDER_ENRICHED;

SHOW STREAMS IN SCHEMA CORE;

SELECT "name", "table_name", "type", "mode", "stale"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER  BY "name";

-- =============================================================================
-- STEP 6 — record the quality results where the rest of the project can see them.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'orders_fully_classified', 'CORE.ORDER_STATUS_EVENT',
       (SELECT COUNT(*) FROM CORE.ORDER_FUNNEL)
         + (SELECT COUNT(*) FROM CORE.ORDER_CANCELLED)
         + (SELECT COUNT(*) FROM CORE.ORDER_LIFECYCLE_ANOMALY)
       = (SELECT COUNT(DISTINCT ORDER_ID) FROM CORE.ORDER_STATUS_EVENT),
       (SELECT COUNT(DISTINCT ORDER_ID) FROM CORE.ORDER_STATUS_EVENT),
       'every order in exactly one of funnel, cancelled, anomaly',
       OBJECT_CONSTRUCT('clean',     (SELECT COUNT(*) FROM CORE.ORDER_FUNNEL),
                        'cancelled', (SELECT COUNT(*) FROM CORE.ORDER_CANCELLED),
                        'anomalous', (SELECT COUNT(*) FROM CORE.ORDER_LIFECYCLE_ANOMALY));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'scd2_one_current_per_key', 'CORE.DIM_PRODUCT',
       (SELECT COUNT(*) FROM (SELECT PRODUCT_ID FROM CORE.DIM_PRODUCT
                              WHERE IS_CURRENT GROUP BY PRODUCT_ID HAVING COUNT(*) > 1)) = 0,
       (SELECT COUNT(*) FROM CORE.DIM_PRODUCT WHERE IS_CURRENT),
       'exactly one current version per product',
       OBJECT_CONSTRUCT('versions', (SELECT COUNT(*) FROM CORE.DIM_PRODUCT),
                        'closed',   (SELECT COUNT(*) FROM CORE.DIM_PRODUCT WHERE NOT IS_CURRENT));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'money_identity_holds', 'CORE.ORDER_HEADER',
       (SELECT SUM(IFF(GROSS_PAISE - DISCOUNT_PAISE + DELIVERY_FEE_PAISE
                       = ORDER_TOTAL_PAISE, 0, 1)) FROM CORE.ORDER_HEADER) = 0,
       (SELECT COUNT(*) FROM CORE.ORDER_HEADER),
       'gross - discount + delivery = total, in whole paise',
       NULL;

SELECT CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
ORDER  BY CHECK_TS DESC
LIMIT  10;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE  IF EXISTS QCOMMERCE.CORE.ORDER_FUNNEL;
-- DROP TABLE  IF EXISTS QCOMMERCE.CORE.ORDER_CANCELLED;
-- DROP TABLE  IF EXISTS QCOMMERCE.CORE.ORDER_LIFECYCLE_ANOMALY;
-- DROP STREAM IF EXISTS QCOMMERCE.CORE.STR_EVENTS_APPEND;
-- DROP STREAM IF EXISTS QCOMMERCE.CORE.STR_ORDER_ENRICHED;
-- DROP VIEW   IF EXISTS QCOMMERCE.CORE.V_ORDER_ENRICHED;

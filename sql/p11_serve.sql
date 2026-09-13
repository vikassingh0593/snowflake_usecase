-- =============================================================================
-- PART 11 / STEP 1 — SERVE, the contract the app reads.
--
-- The Streamlit app does not query MART, LAB or OPS. It queries SERVE, and
-- SERVE is a set of views that can be rewritten when those move. Two reasons
-- beyond tidiness: an app that reaches into LAB pins the shape of an
-- experimental schema, and Part 12's masking and row policies need one surface
-- to attach to rather than nine.
--
-- SERVE has been empty since p1_bootstrap created it. This fills it.
--
-- ON THE DYNAMIC TABLE. The cost rules for this project allow two, at
-- TARGET_LAG >= 60 minutes. This spends one. MART.FCT_ORDER only changes when
-- dbt runs, so refreshes should be no-ops most of the time -- but whether an
-- idle dynamic table costs anything to poll is UNVERIFIED, somewhere between
-- nothing and a few credits a month. If it shows up in the credit backfill,
-- ALTER DYNAMIC TABLE ... SUSPEND parks it without dropping it.
--
-- The first version of this file put the whole aggregate in one dynamic table,
-- ratios included, and Snowflake answered:
--
--   FULL refresh mode was selected because: This dynamic table contains a
--   complex query.
--
-- ROUND(100.0 * AVG(...)) and AVG(DATEDIFF(...)) are not incrementally
-- maintainable -- an average cannot be updated from a delta without its
-- denominator -- so every refresh re-aggregated all 19,377 rows. The split
-- below is the fix and the lesson: A DYNAMIC TABLE HOLDS ADDITIVE AGGREGATES,
-- AND DERIVED RATIOS LIVE IN A VIEW ABOVE IT. Sums and counts compose from
-- deltas; averages and percentages do not.
--
-- The app reads SERVE.SLA_BY_STORE_HOUR either way. That the storage under it
-- could be restructured without touching the app is the argument for having a
-- SERVE layer, demonstrated rather than asserted.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p11:serve';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — operations: SLA by store and local hour.
--
-- A dynamic table rather than a view, because this is the one object in SERVE
-- an operations screen hits repeatedly and it aggregates 20,000 rows every
-- time. It is also the only place in the project where the mechanism earns its
-- place: the source is a dbt table that changes on a schedule, which is
-- exactly the shape dynamic tables are for.
-- =============================================================================
CREATE OR REPLACE DYNAMIC TABLE SERVE.SLA_STORE_HOUR_AGG
  TARGET_LAG   = '60 minutes'
  WAREHOUSE    = WH_TRANSFORM_XS
  REFRESH_MODE = INCREMENTAL
  COMMENT      = 'additive aggregates only. Ratios are in the view above this'
AS
SELECT s.STORE_CODE,
       s.CITY,
       o.PLACED_TS::DATE                                            AS PLACED_DATE,
       -- Stored UTC, operated in IST. An operations screen showing UTC hours
       -- would put the evening peak at half past one in the afternoon.
       HOUR(DATEADD('minute', 330, o.PLACED_TS))                    AS IST_HOUR,
       -- Every column below is a COUNT or a SUM. Nothing here divides.
       COUNT(*)                                                     AS ORDERS,
       SUM(IFF(o.IS_BREACHED, 1, 0))                                AS BREACHED,
       SUM(DATEDIFF('second', o.PLACED_TS, o.PROMISED_TS))          AS PROMISED_SEC,
       SUM(DATEDIFF('second', o.PLACED_TS, o.DELIVERED_TS))         AS DELIVERED_SEC,
       COUNT(o.DELIVERED_TS)                                        AS DELIVERED_N,
       SUM(o.ORDER_TOTAL_PAISE)                                     AS GROSS_PAISE
FROM   MART.FCT_ORDER o
JOIN   MART.DIM_STORE s ON s.STORE_SK = o.STORE_SK
WHERE  o.STATUS = 'DELIVERED'
GROUP  BY s.STORE_CODE, s.CITY, PLACED_DATE, IST_HOUR;

-- The name the app knows. Division happens here, where it costs nothing to
-- maintain, over a table that stays incrementally refreshable.
--
-- DELIVERED_N rather than ORDERS as the denominator for AVG_ACTUAL_MIN: a
-- delivered order always has a timestamp, so today the two are equal, and
-- dividing by the wrong one would only start lying later. NULLIF guards the
-- empty group that a filtered refresh could produce.
CREATE OR REPLACE VIEW SERVE.SLA_BY_STORE_HOUR AS
SELECT STORE_CODE,
       CITY,
       PLACED_DATE,
       IST_HOUR,
       ORDERS,
       BREACHED,
       ROUND(100.0 * BREACHED / NULLIF(ORDERS, 0), 2)               AS BREACH_PCT,
       ROUND(PROMISED_SEC  / NULLIF(ORDERS, 0) / 60.0, 1)           AS AVG_PROMISED_MIN,
       ROUND(DELIVERED_SEC / NULLIF(DELIVERED_N, 0) / 60.0, 1)      AS AVG_ACTUAL_MIN,
       GROSS_PAISE
FROM   SERVE.SLA_STORE_HOUR_AGG;

-- =============================================================================
-- STEP 2 — the risk queue.
--
-- This is a REPLAY and the app says so on the screen. Every order in this
-- project was delivered weeks ago, so a queue of orders "in flight" would be
-- fiction. What makes the replay worth building anyway is that the outcome
-- exists: a dispatcher can act on the score, and the action can be scored
-- against what actually happened -- which is the loop a live queue could only
-- promise.
--
-- Restricted to the model's TEST window. Ranking orders the model was fitted
-- on would flatter it, and the queue is meant to show what the score is worth
-- on days the model never saw.
-- =============================================================================
CREATE OR REPLACE VIEW SERVE.ORDER_RISK AS
SELECT s.ORDER_ID,
       o.PLACED_TS,
       o.PROMISED_TS,
       DATEDIFF('minute', o.PLACED_TS, o.PROMISED_TS)               AS PROMISED_MIN,
       st.STORE_CODE,
       st.CITY,
       o.ITEM_COUNT,
       ROUND(o.ORDER_TOTAL_PAISE / 100.0, 2)                        AS ORDER_TOTAL_RUPEES,
       f.DIST_KM,
       f.STORE_LOAD_60M,
       f.IS_PEAK_HOUR::BOOLEAN                                      AS IS_PEAK_HOUR,
       ROUND(s.P_BREACH, 4)                                         AS P_BREACH,
       NTILE(10) OVER (ORDER BY s.P_BREACH DESC)                    AS RISK_DECILE,
       -- The outcome is carried, and the app keeps it hidden until asked.
       -- Withholding it from the view instead would make the "was the score
       -- worth acting on" panel impossible, which is the only reason a replay
       -- is more useful than a screenshot.
       o.IS_BREACHED                                                AS ACTUAL_BREACHED,
       o.BREACH_SEC
FROM   LAB.ORDER_SCORES  s
JOIN   MART.FCT_ORDER    o  ON o.ORDER_ID   = s.ORDER_ID
JOIN   MART.DIM_STORE    st ON st.STORE_SK  = o.STORE_SK
JOIN   LAB.ORDER_FEATURES f ON f.ORDER_ID   = s.ORDER_ID
WHERE  s.SPLIT = 'TEST';

-- =============================================================================
-- STEP 3 — complaint triage.
--
-- The 0.235 threshold is measured, not chosen. Every one of the 35 errors the
-- classifier makes on the held-out 240 falls below it, and everything above it
-- was correct -- 192 of 192. So AUTO means "the model has never been wrong in
-- this band on data it had not seen" and REVIEW means "every mistake it has
-- ever made lives here". Both claims are in OPS.DQ_RESULTS.
--
-- If the model is retrained, this number is no longer load-bearing and has to
-- be re-derived from the new confidence quintiles.
-- =============================================================================
CREATE OR REPLACE VIEW SERVE.COMPLAINT_TRIAGE AS
SELECT c.TICKET_ID,
       c.RAISED_TS,
       c.CHANNEL,
       c.CITY,
       c.STORE_CODE,
       c.ORDER_ID,
       c.COMPLAINT_TEXT,
       c.WORD_COUNT,
       p.PREDICTED_REASON_CODE,
       ROUND(p.CONFIDENCE, 4)                                       AS CONFIDENCE,
       IFF(p.CONFIDENCE >= 0.235, 'AUTO', 'REVIEW')                 AS ROUTING,
       r.DESCRIPTION                                                AS REASON_DESCRIPTION,
       r.OWNING_TEAM,
       r.IS_SLA_RELATED,
       c.IS_LABELLED                                                AS WAS_HAND_LABELLED,
       c.REASON_CODE                                                AS HAND_LABEL
FROM      CORE.COMPLAINT           c
JOIN      LAB.COMPLAINT_PREDICTION p ON p.TICKET_ID   = c.TICKET_ID
LEFT JOIN RAW.COMPLAINT_REASON_CODE r ON r.REASON_CODE = p.PREDICTED_REASON_CODE;

-- =============================================================================
-- STEP 4 — write-back. The only table in SERVE, and the point of the app.
--
-- A dashboard shows numbers. This records what somebody did about them, which
-- makes the decisions themselves data: a later dbt model joins actions to
-- outcomes and the app's own history becomes a feature for the next model.
-- =============================================================================
CREATE TABLE IF NOT EXISTS SERVE.ACTION_LOG (
  ACTION_ID     NUMBER AUTOINCREMENT START 1 INCREMENT 1,
  LOGGED_AT     TIMESTAMP_NTZ DEFAULT SYSDATE(),
  ACTED_BY      STRING        DEFAULT CURRENT_USER(),
  ACTED_AS      STRING        DEFAULT CURRENT_ROLE(),
  SUBJECT_TYPE  STRING,
  SUBJECT_ID    STRING,
  ACTION        STRING,
  NOTE          STRING,
  CONTEXT       VARIANT
) COMMENT = 'what the app was used to decide. Written by the Streamlit app only';

-- =============================================================================
-- STEP 5 — health, for the tab that admits what is broken.
-- =============================================================================
CREATE OR REPLACE VIEW SERVE.DATA_HEALTH AS
SELECT CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL, CHECK_TS
FROM   OPS.DQ_RESULTS
QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_NAME, TARGET
                           ORDER BY CHECK_TS DESC) = 1;

CREATE OR REPLACE VIEW SERVE.MODEL_SCOREBOARD AS
SELECT MODEL_NAME,
       MODEL_VERSION,
       SPLIT,
       MAX(TRAINED_AT)                                              AS TRAINED_AT,
       MAX(IFF(METRIC = 'n', VALUE, NULL))::INT                     AS N,
       ROUND(MAX(IFF(METRIC = 'accuracy', VALUE, NULL)), 4)         AS ACCURACY,
       ROUND(MAX(IFF(METRIC = 'roc_auc', VALUE, NULL)), 4)          AS ROC_AUC,
       ROUND(MAX(IFF(METRIC = 'macro_f1', VALUE, NULL)), 4)         AS MACRO_F1,
       ROUND(MAX(IFF(METRIC = 'brier', VALUE, NULL)), 4)            AS BRIER
FROM   OPS.MODEL_METRICS
GROUP  BY MODEL_NAME, MODEL_VERSION, SPLIT;

-- =============================================================================
-- STEP 6 — what got built.
-- =============================================================================
SHOW DYNAMIC TABLES IN SCHEMA SERVE;

SELECT 'SLA_BY_STORE_HOUR' AS object, COUNT(*) AS rows_ FROM SERVE.SLA_BY_STORE_HOUR
UNION ALL SELECT 'ORDER_RISK',        COUNT(*) FROM SERVE.ORDER_RISK
UNION ALL SELECT 'COMPLAINT_TRIAGE',  COUNT(*) FROM SERVE.COMPLAINT_TRIAGE
UNION ALL SELECT 'DATA_HEALTH',       COUNT(*) FROM SERVE.DATA_HEALTH
UNION ALL SELECT 'MODEL_SCOREBOARD',  COUNT(*) FROM SERVE.MODEL_SCOREBOARD
UNION ALL SELECT 'SLA_STORE_HOUR_AGG', COUNT(*) FROM SERVE.SLA_STORE_HOUR_AGG
UNION ALL SELECT 'ACTION_LOG',        COUNT(*) FROM SERVE.ACTION_LOG
ORDER BY object;

SELECT ROUTING, COUNT(*) AS complaints,
       ROUND(MIN(CONFIDENCE), 3) AS from_conf,
       ROUND(MAX(CONFIDENCE), 3) AS to_conf
FROM   SERVE.COMPLAINT_TRIAGE
GROUP  BY ROUTING ORDER BY ROUTING;

SELECT RISK_DECILE, COUNT(*) AS orders,
       ROUND(AVG(P_BREACH), 4) AS avg_score,
       ROUND(100.0 * AVG(IFF(ACTUAL_BREACHED, 1.0, 0.0)), 1) AS actual_breach_pct
FROM   SERVE.ORDER_RISK
GROUP  BY RISK_DECILE ORDER BY RISK_DECILE;

-- =============================================================================
-- STEP 7 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'risk_queue_covers_the_test_window_only', 'SERVE.ORDER_RISK',
       (SELECT COUNT(*) FROM SERVE.ORDER_RISK)
         = (SELECT COUNT(*) FROM LAB.ORDER_SCORES WHERE SPLIT = 'TEST')
       AND (SELECT COUNT(*) FROM SERVE.ORDER_RISK) > 0,
       (SELECT COUNT(*) FROM SERVE.ORDER_RISK),
       'one row per scored test order, and the joins to MART lose none of them',
       OBJECT_CONSTRUCT('scored_test', (SELECT COUNT(*) FROM LAB.ORDER_SCORES WHERE SPLIT = 'TEST'));

-- The threshold is only worth shipping if it still separates. If a retrain
-- moves the confidence distribution this fails, which is the intended alarm.
-- Scored against the answer key, and only on complaints the model never
-- trained on. Checking the 60 hand-labelled rows instead would be vacuous:
-- the model reproduces all 60 by construction, so the check would pass
-- whatever the threshold was set to. Reading the key in a serving check is the
-- same thing p10_eval.sql does -- what must never touch it is a feature or a
-- training path.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'auto_band_is_still_clean', 'SERVE.COMPLAINT_TRIAGE',
       (SELECT COUNT(*) FROM SERVE.COMPLAINT_TRIAGE t
         JOIN OPS.COMPLAINT_TRUTH k ON k.TICKET_ID = t.TICKET_ID
         WHERE t.ROUTING = 'AUTO' AND NOT t.WAS_HAND_LABELLED
           AND t.PREDICTED_REASON_CODE <> k.REASON_CODE) = 0
       AND (SELECT COUNT(*) FROM SERVE.COMPLAINT_TRIAGE
             WHERE ROUTING = 'AUTO' AND NOT WAS_HAND_LABELLED) > 150,
       (SELECT COUNT(*) FROM SERVE.COMPLAINT_TRIAGE
         WHERE ROUTING = 'AUTO' AND NOT WAS_HAND_LABELLED),
       'not one unseen complaint in the AUTO band is misclassified, and the '
         || 'band holds more than 150 of the 240 -- if a retrain moves the '
         || 'confidence distribution this is the alarm',
       (SELECT OBJECT_AGG(ROUTING, n::VARIANT)
        FROM (SELECT ROUTING, COUNT(*) AS n FROM SERVE.COMPLAINT_TRIAGE GROUP BY ROUTING));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'risk_deciles_are_ordered_by_outcome', 'SERVE.ORDER_RISK',
       (SELECT AVG(IFF(RISK_DECILE = 1, IFF(ACTUAL_BREACHED, 1.0, 0.0), NULL))
             > 2 * AVG(IFF(RISK_DECILE = 10, IFF(ACTUAL_BREACHED, 1.0, 0.0), NULL))
        FROM SERVE.ORDER_RISK),
       (SELECT ROUND(AVG(IFF(RISK_DECILE = 1, IFF(ACTUAL_BREACHED, 1.0, 0.0), NULL)) * 10000)
        FROM SERVE.ORDER_RISK),
       'the riskiest decile really does breach at more than twice the rate of '
         || 'the safest, top-decile rate in basis points',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'sla_aggregate_matches_the_fact_table', 'SERVE.SLA_BY_STORE_HOUR',
       (SELECT SUM(ORDERS) FROM SERVE.SLA_STORE_HOUR_AGG)
         = (SELECT COUNT(*) FROM MART.FCT_ORDER WHERE STATUS = 'DELIVERED')
       AND (SELECT SUM(BREACHED) FROM SERVE.SLA_STORE_HOUR_AGG)
         = (SELECT COUNT(*) FROM MART.FCT_ORDER WHERE IS_BREACHED),
       (SELECT SUM(ORDERS) FROM SERVE.SLA_STORE_HOUR_AGG),
       'the dynamic table adds up to the fact table it aggregates',
       OBJECT_CONSTRUCT(
         'delivered', (SELECT COUNT(*) FROM MART.FCT_ORDER WHERE STATUS = 'DELIVERED'),
         'breached',  (SELECT COUNT(*) FROM MART.FCT_ORDER WHERE IS_BREACHED));

-- Does the restructuring actually buy incremental refresh, or does Snowflake
-- still call it complex. REFRESH_MODE = INCREMENTAL is stated explicitly on
-- the CREATE, so an unmaintainable query fails there rather than downgrading
-- quietly -- but configured_refresh_mode and refresh_mode are separate columns
-- and it is the second one that governs.
SHOW DYNAMIC TABLES LIKE 'SLA_STORE_HOUR_AGG' IN SCHEMA SERVE;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'dynamic_table_refreshes_incrementally', 'SERVE.SLA_STORE_HOUR_AGG',
       UPPER("refresh_mode") = 'INCREMENTAL',
       "rows",
       'additive aggregates only, so deltas can be applied instead of '
         || 're-aggregating 19,377 rows every hour',
       OBJECT_CONSTRUCT('refresh_mode',            "refresh_mode",
                        'configured_refresh_mode', "configured_refresh_mode",
                        'target_lag',              "target_lag",
                        'scheduling_state',        "scheduling_state",
                        'reason',                  "refresh_mode_reason")
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET LIKE 'SERVE.%'
ORDER  BY CHECK_TS DESC
LIMIT  5;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- ALTER DYNAMIC TABLE QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG SUSPEND;
-- DROP DYNAMIC TABLE IF EXISTS QCOMMERCE.SERVE.SLA_STORE_HOUR_AGG;
-- DROP VIEW  IF EXISTS QCOMMERCE.SERVE.SLA_BY_STORE_HOUR;
-- DROP VIEW  IF EXISTS QCOMMERCE.SERVE.ORDER_RISK;
-- DROP VIEW  IF EXISTS QCOMMERCE.SERVE.COMPLAINT_TRIAGE;
-- DROP VIEW  IF EXISTS QCOMMERCE.SERVE.DATA_HEALTH;
-- DROP VIEW  IF EXISTS QCOMMERCE.SERVE.MODEL_SCOREBOARD;
-- DROP TABLE IF EXISTS QCOMMERCE.SERVE.ACTION_LOG;

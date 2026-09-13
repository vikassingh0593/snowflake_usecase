-- =============================================================================
-- PART 9 / STEP 1 — the feature table.
--
-- Target: will this order be delivered after its promised_ts.
--
-- Every feature here must be knowable at PLACED_TS. packed_ts, picked_up_ts,
-- delivered_ts, pack_sec, ride_sec and lifecycle_outcome are all recorded after
-- the fact and every one of them would leak the answer, so none appears below.
-- rider_sk is excluded for the same reason -- a rider is attached to the order,
-- but which rider was free is a consequence of the same congestion the model is
-- trying to predict, and the assignment is not observable at the moment of
-- placement.
--
-- CANCELLED orders are excluded rather than labelled false. A cancelled order
-- has no delivery outcome; calling it "not breached" would teach the model that
-- cancellation prevents lateness, which is a fact about the label definition
-- and not a fact about the world.
--
-- The four real drivers are carried twice: once in natural units, for reading,
-- and once in the scaling used to fit, so the fitted coefficients are directly
-- comparable to something. F_WEEKEND and F_COD are placebos -- nothing in the
-- delivery process depends on either -- and they are in the model on purpose.
-- A fit that assigns them weight is a fit that is finding structure in noise.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p09:features';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — build it.
-- =============================================================================
CREATE OR REPLACE TABLE LAB.ORDER_FEATURES AS
WITH cutoff AS (
    -- A time split, not a random one. A random split lets the model see orders
    -- from the same store-hour on both sides and scores itself on congestion it
    -- has already been shown. Forty-five days train, fifteen test.
    SELECT DATEADD('day', 45, MIN(PLACED_TS)::DATE) AS SPLIT_TS
    FROM   MART.FCT_ORDER
),
base AS (
    SELECT
        o.ORDER_SK,
        o.ORDER_ID,
        o.PLACED_TS,
        o.STORE_SK,
        o.CUSTOMER_SK,

        -- Straight-line store-to-door. HAVERSINE is native and returns km;
        -- ST_DISTANCE on two GEOGRAPHY points returns metres and is computed
        -- here only so the two can be checked against each other below.
        HAVERSINE(s.LAT, s.LON, c.HOME_LAT, c.HOME_LON)                   AS DIST_KM,
        ST_DISTANCE(ST_MAKEPOINT(s.LON, s.LAT),
                    ST_MAKEPOINT(c.HOME_LON, c.HOME_LAT)) / 1000.0        AS DIST_KM_GEO,

        -- Stored UTC, lived IST. The rush hours that matter are local ones.
        HOUR(DATEADD('minute', 330, o.PLACED_TS))                         AS IST_HOUR,
        DATE_PART(EPOCH_MILLISECOND, o.PLACED_TS)                         AS PLACED_MS,

        o.ITEM_COUNT,
        o.GROSS_PAISE,
        o.PAYMENT_METHOD,
        c.SEGMENT,
        s.CITY,
        o.IS_BREACHED
    FROM MART.FCT_ORDER    o
    JOIN MART.DIM_STORE    s ON s.STORE_SK    = o.STORE_SK
    JOIN MART.DIM_CUSTOMER c ON c.CUSTOMER_SK = o.CUSTOMER_SK
    WHERE o.STATUS = 'DELIVERED'
),
feat AS (
    SELECT
        b.*,
        IFF(b.IST_HOUR IN (12, 13, 19, 20, 21), 1, 0)                     AS IS_PEAK_HOUR,
        IFF(DAYOFWEEK(b.PLACED_TS) IN (0, 6), 1, 0)                       AS IS_WEEKEND,
        IFF(b.PAYMENT_METHOD = 'COD', 1, 0)                               AS IS_COD,

        -- How busy was this store in the hour BEFORE this order arrived.
        -- The frame is numeric on epoch milliseconds rather than an INTERVAL on
        -- the timestamp, and it ends at 1 PRECEDING: a frame ending at CURRENT
        -- ROW would include every order sharing this millisecond, which is a
        -- small look-ahead that costs nothing to remove.
        -- UNVERIFIED on this account: numeric offsets in a RANGE frame are
        -- documented, but Snowflake historically allowed only UNBOUNDED and
        -- CURRENT ROW here. If this errors with "unsupported window frame",
        -- delete this expression and use the self-join in the block below --
        -- same number, no window frame, a few seconds slower.
        COUNT(*) OVER (
            PARTITION BY b.STORE_SK
            ORDER BY     b.PLACED_MS
            RANGE BETWEEN 3600000 PRECEDING AND 1 PRECEDING)              AS STORE_LOAD_60M
    FROM base b
)
SELECT
    f.ORDER_SK,
    f.ORDER_ID,
    f.PLACED_TS,
    f.STORE_SK,
    f.CUSTOMER_SK,
    f.CITY,
    f.SEGMENT,
    f.PAYMENT_METHOD,

    f.DIST_KM,
    f.DIST_KM_GEO,
    f.IST_HOUR,
    f.ITEM_COUNT,
    f.GROSS_PAISE,
    f.STORE_LOAD_60M,
    f.IS_PEAK_HOUR,
    f.IS_WEEKEND,
    f.IS_COD,

    -- The fitting columns. GROSS_PAISE is deliberately NOT among them: basket
    -- value is a near-linear function of item count, and two collinear copies
    -- of one signal split the weight between them and make the fitted
    -- coefficients unreadable. It stays in the table for Parts 10 and 11.
    (f.DIST_KM / 5.0)::FLOAT                                              AS F_DIST_5,
    f.IS_PEAK_HOUR::FLOAT                                                 AS F_PEAK,
    (LEAST(f.STORE_LOAD_60M, 15) / 15.0)::FLOAT                           AS F_LOAD_15,
    (f.ITEM_COUNT / 5.0)::FLOAT                                           AS F_ITEMS_5,
    f.IS_WEEKEND::FLOAT                                                   AS F_WEEKEND,
    f.IS_COD::FLOAT                                                       AS F_COD,

    f.IS_BREACHED::BOOLEAN                                              AS LABEL_BREACHED,
    IFF(f.IS_BREACHED, 1, 0)::FLOAT                                       AS LABEL,
    IFF(f.PLACED_TS < k.SPLIT_TS, 'TRAIN', 'TEST')                        AS SPLIT
FROM feat f
CROSS JOIN cutoff k;

-- If the RANGE frame above is rejected, this is the replacement: drop the
-- COUNT(*) OVER expression from `feat`, add `load.STORE_LOAD_60M` to the final
-- SELECT, and add this LEFT JOIN beside `CROSS JOIN cutoff k`.
--
--   LEFT JOIN (
--       SELECT a.ORDER_SK, COUNT(b.ORDER_SK) AS STORE_LOAD_60M
--       FROM   base a
--       LEFT JOIN base b
--              ON b.STORE_SK  = a.STORE_SK
--             AND b.PLACED_MS <  a.PLACED_MS
--             AND b.PLACED_MS >= a.PLACED_MS - 3600000
--       GROUP BY a.ORDER_SK
--   ) load ON load.ORDER_SK = f.ORDER_SK

-- =============================================================================
-- STEP 2 — what got built.
-- =============================================================================
SELECT SPLIT,
       COUNT(*)                                        AS orders,
       MIN(PLACED_TS)::DATE                            AS from_date,
       MAX(PLACED_TS)::DATE                            AS to_date,
       ROUND(AVG(LABEL) * 100, 2)                      AS breach_pct,
       ROUND(AVG(DIST_KM), 2)                          AS avg_dist_km,
       ROUND(AVG(STORE_LOAD_60M), 1)                   AS avg_load_60m,
       ROUND(AVG(IS_PEAK_HOUR) * 100, 1)               AS peak_pct,
       ROUND(AVG(ITEM_COUNT), 2)                       AS avg_items
FROM   LAB.ORDER_FEATURES
GROUP  BY SPLIT
ORDER  BY SPLIT DESC;

-- Does the label actually move with each driver, before any model is fitted.
-- If a driver shows a flat breach rate across its own quartiles there is
-- nothing for the model to find and the fit will say so later; better to know
-- now than to read it out of a coefficient.
SELECT driver, quartile, COUNT(*) AS orders, ROUND(AVG(LABEL) * 100, 2) AS breach_pct
FROM (
    SELECT 'dist_km'        AS driver, NTILE(4) OVER (ORDER BY DIST_KM)        AS quartile, LABEL FROM LAB.ORDER_FEATURES
    UNION ALL
    SELECT 'store_load_60m',        NTILE(4) OVER (ORDER BY STORE_LOAD_60M),          LABEL FROM LAB.ORDER_FEATURES
    UNION ALL
    SELECT 'item_count',            NTILE(4) OVER (ORDER BY ITEM_COUNT),              LABEL FROM LAB.ORDER_FEATURES
    UNION ALL
    SELECT 'is_peak_hour',          IS_PEAK_HOUR + 1,                                 LABEL FROM LAB.ORDER_FEATURES
    UNION ALL
    SELECT 'is_weekend  [placebo]', IS_WEEKEND + 1,                                   LABEL FROM LAB.ORDER_FEATURES
    UNION ALL
    SELECT 'is_cod      [placebo]', IS_COD + 1,                                       LABEL FROM LAB.ORDER_FEATURES
)
GROUP BY driver, quartile
ORDER BY driver, quartile;

-- =============================================================================
-- STEP 3 — checks.
--
-- Each of these has a way of passing on an empty or broken table, so each one
-- asserts a positive count as well as the condition. A zero that scores
-- perfectly has been the failure mode at every previous step of this build.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'features_cover_delivered_orders', 'LAB.ORDER_FEATURES',
       (SELECT COUNT(*) FROM LAB.ORDER_FEATURES)
         = (SELECT COUNT(*) FROM MART.FCT_ORDER WHERE STATUS = 'DELIVERED')
       AND (SELECT COUNT(*) FROM LAB.ORDER_FEATURES) > 0,
       (SELECT COUNT(*) FROM LAB.ORDER_FEATURES),
       'one feature row per delivered order, and not zero of them',
       OBJECT_CONSTRUCT(
         'delivered', (SELECT COUNT(*) FROM MART.FCT_ORDER WHERE STATUS = 'DELIVERED'),
         'cancelled', (SELECT COUNT(*) FROM MART.FCT_ORDER WHERE STATUS <> 'DELIVERED'));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'features_have_no_nulls', 'LAB.ORDER_FEATURES',
       (SELECT COUNT(*) FROM LAB.ORDER_FEATURES
         WHERE F_DIST_5 IS NULL OR F_PEAK IS NULL OR F_LOAD_15 IS NULL
            OR F_ITEMS_5 IS NULL OR F_WEEKEND IS NULL OR F_COD IS NULL
            OR LABEL IS NULL) = 0
       AND (SELECT COUNT(*) FROM LAB.ORDER_FEATURES) > 0,
       (SELECT COUNT(*) FROM LAB.ORDER_FEATURES
         WHERE F_DIST_5 IS NULL OR F_PEAK IS NULL OR F_LOAD_15 IS NULL
            OR F_ITEMS_5 IS NULL OR F_WEEKEND IS NULL OR F_COD IS NULL
            OR LABEL IS NULL),
       'sklearn will not fit around a null, so there must be none',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'haversine_agrees_with_geography', 'LAB.ORDER_FEATURES',
       (SELECT MAX(ABS(DIST_KM - DIST_KM_GEO)) FROM LAB.ORDER_FEATURES) < 0.01
       AND (SELECT COUNT(*) FROM LAB.ORDER_FEATURES) > 0,
       (SELECT ROUND(MAX(ABS(DIST_KM - DIST_KM_GEO)) * 1000) FROM LAB.ORDER_FEATURES),
       'HAVERSINE and ST_DISTANCE within 10 m, in metres',
       OBJECT_CONSTRUCT('max_dist_km', (SELECT ROUND(MAX(DIST_KM), 3) FROM LAB.ORDER_FEATURES),
                        'min_dist_km', (SELECT ROUND(MIN(DIST_KM), 3) FROM LAB.ORDER_FEATURES));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'split_is_strictly_temporal', 'LAB.ORDER_FEATURES',
       (SELECT MAX(PLACED_TS) FROM LAB.ORDER_FEATURES WHERE SPLIT = 'TRAIN')
         < (SELECT MIN(PLACED_TS) FROM LAB.ORDER_FEATURES WHERE SPLIT = 'TEST')
       AND (SELECT COUNT(*) FROM LAB.ORDER_FEATURES WHERE SPLIT = 'TEST') > 0,
       (SELECT COUNT(*) FROM LAB.ORDER_FEATURES WHERE SPLIT = 'TEST'),
       'no test order was placed before any training order',
       OBJECT_CONSTRUCT(
         'train_to', (SELECT MAX(PLACED_TS) FROM LAB.ORDER_FEATURES WHERE SPLIT = 'TRAIN'),
         'test_from', (SELECT MIN(PLACED_TS) FROM LAB.ORDER_FEATURES WHERE SPLIT = 'TEST'));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'both_splits_carry_both_classes', 'LAB.ORDER_FEATURES',
       (SELECT MIN(r) FROM (SELECT AVG(LABEL) AS r FROM LAB.ORDER_FEATURES GROUP BY SPLIT)) > 0.05
       AND (SELECT MAX(r) FROM (SELECT AVG(LABEL) AS r FROM LAB.ORDER_FEATURES GROUP BY SPLIT)) < 0.40
       AND (SELECT COUNT(DISTINCT SPLIT) FROM LAB.ORDER_FEATURES) = 2,
       (SELECT COUNT(DISTINCT SPLIT) FROM LAB.ORDER_FEATURES),
       'each split between 5% and 40% breached, and there are two of them',
       (SELECT OBJECT_AGG(SPLIT, r::VARIANT)
        FROM (SELECT SPLIT, ROUND(AVG(LABEL) * 100, 2) AS r
              FROM LAB.ORDER_FEATURES GROUP BY SPLIT));

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET = 'LAB.ORDER_FEATURES'
ORDER  BY CHECK_TS DESC
LIMIT  5;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE IF EXISTS QCOMMERCE.LAB.ORDER_FEATURES;

-- =============================================================================
-- PART 9 — read-only reprint of the training results.
--
-- Nothing here trains, writes or drops anything. It re-reads what
-- p9_train.sql already committed, for when the run scrolled past or a later
-- session needs the numbers without paying for a refit.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p09:report';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- 1 — the confound. Store congestion has a true weight of +0.70 and its
-- marginal breach rate FALLS. The claim is that distance explains it.
-- =============================================================================
SELECT ROUND(CORR(DIST_KM, STORE_LOAD_60M), 4)                    AS corr_dist_load,
       ROUND(CORR(DIST_KM, LABEL), 4)                             AS corr_dist_breach,
       ROUND(CORR(STORE_LOAD_60M, LABEL), 4)                      AS corr_load_breach,
       ROUND(AVG(STORE_LOAD_60M), 2)                              AS avg_load,
       MAX(STORE_LOAD_60M)                                        AS max_load,
       ROUND(AVG(LEAST(STORE_LOAD_60M, 15) / 15.0), 4)            AS avg_f_load_15
FROM   LAB.ORDER_FEATURES;

-- Breach rate by load quartile, with distance held still. If q4_minus_q1 is
-- positive in most rows, congestion does raise breach risk and the marginal
-- table was reading distance the whole time.
SELECT dist_q,
       MAX(IFF(load_q = 1, breach_pct, NULL))                     AS load_q1_pct,
       MAX(IFF(load_q = 2, breach_pct, NULL))                     AS load_q2_pct,
       MAX(IFF(load_q = 3, breach_pct, NULL))                     AS load_q3_pct,
       MAX(IFF(load_q = 4, breach_pct, NULL))                     AS load_q4_pct,
       MAX(IFF(load_q = 4, breach_pct, NULL))
         - MAX(IFF(load_q = 1, breach_pct, NULL))                 AS q4_minus_q1,
       SUM(orders)                                                AS orders
FROM (
    SELECT dist_q, load_q, COUNT(*) AS orders,
           ROUND(AVG(LABEL) * 100, 2) AS breach_pct
    FROM (
        SELECT NTILE(4) OVER (ORDER BY DIST_KM)        AS dist_q,
               NTILE(4) OVER (ORDER BY STORE_LOAD_60M) AS load_q,
               LABEL
        FROM LAB.ORDER_FEATURES
    )
    GROUP BY dist_q, load_q
)
GROUP BY dist_q
ORDER BY dist_q;

-- =============================================================================
-- 2 — fitted weight beside the weight that produced the data.
-- =============================================================================
SELECT FEATURE,
       ROUND(GENERATOR_WEIGHT, 3)                                   AS generator_weight,
       ROUND(COEFFICIENT, 3)                                        AS fitted,
       IFF(GENERATOR_WEIGHT = 0, NULL,
           ROUND(COEFFICIENT / GENERATOR_WEIGHT, 2))                AS ratio,
       CASE WHEN GENERATOR_WEIGHT = 0 AND ABS(COEFFICIENT) < 0.10 THEN 'placebo, near zero'
            WHEN GENERATOR_WEIGHT = 0                              THEN 'PLACEBO PICKED UP WEIGHT'
            WHEN SIGN(COEFFICIENT) <> SIGN(GENERATOR_WEIGHT)       THEN 'WRONG SIGN'
            WHEN COEFFICIENT / GENERATOR_WEIGHT BETWEEN 0.3 AND 1.3 THEN 'recovered, attenuated'
            ELSE 'off'
       END                                                          AS verdict
FROM   OPS.MODEL_COEFFICIENTS
WHERE  TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_COEFFICIENTS)
ORDER  BY GENERATOR_WEIGHT DESC;

-- =============================================================================
-- 3 — metrics, every version ever trained.
-- =============================================================================
SELECT MODEL_VERSION, SPLIT,
       MAX(IFF(METRIC = 'n', VALUE, NULL))::INT                     AS n,
       ROUND(MAX(IFF(METRIC = 'base_rate', VALUE, NULL)) * 100, 2)  AS actual_breach_pct,
       ROUND(MAX(IFF(METRIC = 'mean_predicted', VALUE, NULL)) * 100, 2) AS predicted_breach_pct,
       ROUND(MAX(IFF(METRIC = 'roc_auc', VALUE, NULL)), 4)          AS roc_auc,
       ROUND(MAX(IFF(METRIC = 'pr_auc', VALUE, NULL)), 4)           AS pr_auc,
       ROUND(MAX(IFF(METRIC = 'brier', VALUE, NULL)), 4)            AS brier,
       ROUND(MAX(IFF(METRIC = 'log_loss', VALUE, NULL)), 4)         AS log_loss
FROM   OPS.MODEL_METRICS
GROUP  BY MODEL_VERSION, SPLIT
ORDER  BY MODEL_VERSION, SPLIT DESC;

-- =============================================================================
-- 4 — the model as an account object.
-- =============================================================================
SHOW MODELS IN SCHEMA LAB;
SHOW VERSIONS IN MODEL LAB.SLA_BREACH;

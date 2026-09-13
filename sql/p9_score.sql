-- =============================================================================
-- PART 9 / STEP 3 — score with the registered model.
--
-- The point of this step is not the numbers, it is WHERE the inference runs.
-- ModelVersion.run() against a Snowpark DataFrame compiles the model into the
-- function the registry generated at log time and evaluates it in the
-- warehouse. Nothing is pulled to a client and re-scored there. That generated
-- function is the exact object whose creation failed until the library was
-- embedded, so a successful score here is the proof that the fix held rather
-- than merely quietened the error.
--
-- Scores are written for both splits. The lift table reports TEST only --
-- ranking orders the model was fitted on would flatter it.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p09:score';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — batch score.
-- =============================================================================
CREATE OR REPLACE PROCEDURE LAB.SP_SCORE_SLA(MODEL_VERSION STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'snowflake-ml-python')
HANDLER = 'run'
AS
$$
from snowflake.ml.registry import Registry
from snowflake.snowpark.functions import col, current_timestamp, lit
from snowflake.snowpark.types import FloatType

FEATURES = ["F_DIST_5", "F_PEAK", "F_LOAD_15", "F_ITEMS_5", "F_WEEKEND", "F_COD"]
PASSTHROUGH = ["ORDER_ID", "SPLIT", "LABEL"]


def run(session, model_version):
    reg = Registry(session=session, database_name="QCOMMERCE", schema_name="LAB")
    m = reg.get_model("SLA_BREACH")
    mv = m.version(model_version) if model_version else m.default
    version = mv.version_name

    src = session.table("QCOMMERCE.LAB.ORDER_FEATURES").select(
        *[col(c) for c in PASSTHROUGH + FEATURES])
    before = list(src.columns)

    scored = mv.run(src, function_name="predict_proba")

    # The registry decides what to call the probability columns and the naming
    # has changed between releases, so it is discovered rather than assumed.
    # Binary predict_proba adds exactly two columns, in class order, so the
    # second one is P(breach). Anything other than two means the signature is
    # not what this procedure was written for, and guessing would be worse than
    # stopping.
    added = [c for c in scored.columns if c not in before]
    if len(added) != 2:
        return ("ABORT: expected 2 probability columns, got %d: %s"
                % (len(added), added))
    p_breach = added[-1]

    scored.select(
        current_timestamp().alias("SCORED_AT"),
        lit(version).alias("MODEL_VERSION"),
        col("ORDER_ID"),
        col("SPLIT"),
        col("LABEL"),
        col(p_breach).cast(FloatType()).alias("P_BREACH"),
    ).write.save_as_table("QCOMMERCE.LAB.ORDER_SCORES", mode="overwrite")

    n = session.table("QCOMMERCE.LAB.ORDER_SCORES").count()
    return ("scored %d orders with %s | probability columns as returned by the "
            "registry: %s | P(breach) taken from %s" % (n, version, added, p_breach))
$$;

CALL LAB.SP_SCORE_SLA(NULL);

-- =============================================================================
-- STEP 2 — the operational read.
--
-- A breach probability per order is not a decision. The decision is how many
-- orders an operator can intervene on before the shift, and the only question
-- that matters is what fraction of the breaches sit in that many orders. The
-- cumulative capture column is that answer.
-- =============================================================================
WITH ranked AS (
    SELECT LABEL, P_BREACH,
           NTILE(10) OVER (ORDER BY P_BREACH DESC) AS decile
    FROM   LAB.ORDER_SCORES
    WHERE  SPLIT = 'TEST'
),
per_decile AS (
    SELECT decile,
           COUNT(*)                                    AS orders,
           SUM(LABEL)                                  AS breaches,
           AVG(LABEL)                                  AS breach_rate,
           MIN(P_BREACH)                               AS min_score,
           MAX(P_BREACH)                               AS max_score
    FROM   ranked GROUP BY decile
)
SELECT decile,
       orders,
       breaches::INT                                                   AS breaches,
       ROUND(breach_rate * 100, 2)                                     AS breach_pct,
       ROUND(breach_rate / (SUM(breaches) OVER () / SUM(orders) OVER ()), 2)
                                                                       AS lift,
       ROUND(100.0 * SUM(breaches) OVER (ORDER BY decile
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(breaches) OVER (), 1)                               AS cumulative_capture_pct,
       ROUND(min_score, 4)                                             AS min_score,
       ROUND(max_score, 4)                                             AS max_score
FROM   per_decile
ORDER  BY decile;

-- Calibration, as buckets rather than as a single mean. A model can have the
-- right average and still be wrong everywhere, high on the safe orders and low
-- on the dangerous ones, and the average will not show it.
SELECT WIDTH_BUCKET(P_BREACH, 0, 0.60, 6)                              AS bucket,
       COUNT(*)                                                        AS orders,
       ROUND(MIN(P_BREACH), 4)                                         AS from_score,
       ROUND(MAX(P_BREACH), 4)                                         AS to_score,
       ROUND(AVG(P_BREACH) * 100, 2)                                   AS predicted_pct,
       ROUND(AVG(LABEL) * 100, 2)                                      AS actual_pct,
       ROUND((AVG(LABEL) - AVG(P_BREACH)) * 100, 2)                    AS gap_pts
FROM   LAB.ORDER_SCORES
WHERE  SPLIT = 'TEST'
GROUP  BY bucket
ORDER  BY bucket;

-- =============================================================================
-- STEP 3 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'every_order_scored_exactly_once', 'LAB.ORDER_SCORES',
       (SELECT COUNT(*) FROM LAB.ORDER_SCORES)
         = (SELECT COUNT(*) FROM LAB.ORDER_FEATURES)
       AND (SELECT COUNT(DISTINCT ORDER_ID) FROM LAB.ORDER_SCORES)
         = (SELECT COUNT(*) FROM LAB.ORDER_SCORES)
       AND (SELECT COUNT(*) FROM LAB.ORDER_SCORES) > 0,
       (SELECT COUNT(*) FROM LAB.ORDER_SCORES),
       'one score per feature row, no duplicates, not zero rows',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'scores_are_probabilities', 'LAB.ORDER_SCORES',
       (SELECT COUNT(*) FROM LAB.ORDER_SCORES
         WHERE P_BREACH IS NULL OR P_BREACH < 0 OR P_BREACH > 1) = 0
       AND (SELECT COUNT(DISTINCT ROUND(P_BREACH, 4)) FROM LAB.ORDER_SCORES) > 100,
       (SELECT COUNT(DISTINCT ROUND(P_BREACH, 4)) FROM LAB.ORDER_SCORES),
       'all in [0,1], and more than 100 distinct values -- a constant column '
       'would satisfy the range test perfectly',
       OBJECT_CONSTRUCT('min', (SELECT ROUND(MIN(P_BREACH), 4) FROM LAB.ORDER_SCORES),
                        'max', (SELECT ROUND(MAX(P_BREACH), 4) FROM LAB.ORDER_SCORES));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
WITH d AS (
    SELECT NTILE(10) OVER (ORDER BY P_BREACH DESC) AS decile, LABEL
    FROM   LAB.ORDER_SCORES WHERE SPLIT = 'TEST'
),
r AS (
    SELECT AVG(IFF(decile = 1,  LABEL, NULL)) AS top_rate,
           AVG(IFF(decile = 10, LABEL, NULL)) AS bottom_rate
    FROM   d
)
SELECT 'top_decile_beats_bottom_decile', 'LAB.ORDER_SCORES',
       top_rate > 2 * bottom_rate AND bottom_rate > 0,
       ROUND(top_rate / NULLIF(bottom_rate, 0) * 100),
       'riskiest tenth breaches at more than twice the rate of the safest '
       'tenth, ratio in percent',
       OBJECT_CONSTRUCT('top_decile_pct',    ROUND(top_rate * 100, 2),
                        'bottom_decile_pct', ROUND(bottom_rate * 100, 2))
FROM r;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET = 'LAB.ORDER_SCORES'
ORDER  BY CHECK_TS DESC
LIMIT  3;

-- =============================================================================
-- STEP 4 — the SQL surface, and it is last on purpose.
--
-- A registered model can also be called straight from SQL, with no Python
-- anywhere in the statement. UNVERIFIED on this account: the syntax below is
-- the documented form, but this account has already refused external access
-- integrations and shipped a registry that needed an undocumented option, so
-- it is placed after every deliverable in this file. If it fails, the script
-- stops here with the scores, the lift table and the checks already committed.
-- =============================================================================
WITH sla AS MODEL QCOMMERCE.LAB.SLA_BREACH
SELECT ORDER_ID,
       ROUND(P_BREACH, 4)                                              AS p_from_procedure,
       sla!PREDICT_PROBA(F_DIST_5, F_PEAK, F_LOAD_15,
                         F_ITEMS_5, F_WEEKEND, F_COD)                  AS p_from_sql
FROM   LAB.ORDER_FEATURES
JOIN   LAB.ORDER_SCORES USING (ORDER_ID)
LIMIT  10;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE     IF EXISTS QCOMMERCE.LAB.ORDER_SCORES;
-- DROP PROCEDURE IF EXISTS QCOMMERCE.LAB.SP_SCORE_SLA(STRING);

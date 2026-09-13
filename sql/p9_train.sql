-- =============================================================================
-- PART 9 / STEP 2 — train, evaluate, register.
--
-- Training runs as a Python stored procedure, not from a local Snowpark
-- session. Three reasons, in order of how much they matter:
--
--   1. The data never leaves. 19,000 rows is nothing, but the pattern is the
--      point -- the same procedure works when the table is 19 billion rows and
--      pulling it to a laptop is not an option.
--   2. The model is logged from inside the account, so the registry, the
--      warehouse and the training runtime are all the same environment. The
--      version skew that broke the first registry attempt was a mismatch
--      between a client and the server; running in one place removes the
--      class of problem.
--   3. It sidesteps the native arm64 interpreter that has been outstanding
--      since Part 3.
--
-- embed_local_ml_library is not decoration. Without it, log_model builds the
-- model's inference function with snowflake-ml-python >=2.0,<3 as a runtime
-- dependency and the Anaconda channel carries 1.9.2, so function creation
-- fails with "Packages not found". With it, the library is shipped inside the
-- model artefact and there is nothing left to resolve. Pinning scikit-learn
-- through conda_dependencies does NOT fix this -- measured, not assumed.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p09:train';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — where results go. IF NOT EXISTS, because the interesting question
-- after the second run is what changed between versions.
-- =============================================================================
CREATE TABLE IF NOT EXISTS OPS.MODEL_METRICS (
  TRAINED_AT    TIMESTAMP_NTZ DEFAULT SYSDATE(),
  MODEL_NAME    STRING,
  MODEL_VERSION STRING,
  SPLIT         STRING,
  METRIC        STRING,
  VALUE         FLOAT
) COMMENT = 'one row per model version per split per metric';

CREATE TABLE IF NOT EXISTS OPS.MODEL_COEFFICIENTS (
  TRAINED_AT       TIMESTAMP_NTZ DEFAULT SYSDATE(),
  MODEL_NAME       STRING,
  MODEL_VERSION    STRING,
  FEATURE          STRING,
  COEFFICIENT      FLOAT,
  GENERATOR_WEIGHT FLOAT
) COMMENT = 'fitted weight beside the weight the source system actually used';

-- =============================================================================
-- STEP 2 — the procedure.
-- =============================================================================
CREATE OR REPLACE PROCEDURE LAB.SP_TRAIN_SLA_MODEL()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'snowflake-ml-python',
            'scikit-learn', 'pandas', 'numpy')
HANDLER = 'run'
AS
$$
import datetime

import numpy as np
import pandas as pd
import sklearn
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (average_precision_score, brier_score_loss,
                             log_loss, roc_auc_score)

from snowflake.ml.registry import Registry

MODEL_NAME = "SLA_BREACH"
FEATURES = ["F_DIST_5", "F_PEAK", "F_LOAD_15", "F_ITEMS_5", "F_WEEKEND", "F_COD"]

# What the order generator actually used to decide lateness. These are not a
# guess -- they are the coefficients in source/generate.py. Carrying them into
# the results table turns "the model scored 0.7" into "the model recovered the
# process", which is a claim that can be wrong.
GENERATOR = {
    "F_DIST_5":    0.85,
    "F_PEAK":      0.55,
    "F_LOAD_15":   0.70,
    "F_ITEMS_5":   0.25,
    "F_WEEKEND":   0.00,   # placebo
    "F_COD":       0.00,   # placebo
    "(intercept)": -3.05,
}


def _next_version(reg):
    try:
        taken = {v.version_name.upper() for v in reg.get_model(MODEL_NAME).versions()}
    except Exception:
        taken = set()
    n = 1
    while "V%d" % n in taken:
        n += 1
    return "V%d" % n


def _metrics(y, p):
    return {
        "n":              float(len(y)),
        "base_rate":      float(np.mean(y)),
        "mean_predicted": float(np.mean(p)),
        "roc_auc":        float(roc_auc_score(y, p)),
        "pr_auc":         float(average_precision_score(y, p)),
        "brier":          float(brier_score_loss(y, p)),
        "log_loss":       float(log_loss(y, p)),
    }


def run(session):
    df = session.table("QCOMMERCE.LAB.ORDER_FEATURES").to_pandas()
    tr = df[df["SPLIT"] == "TRAIN"]
    te = df[df["SPLIT"] == "TEST"]
    if len(tr) == 0 or len(te) == 0:
        return "ABORT: one of the splits is empty (train=%d test=%d)" % (len(tr), len(te))

    X_tr, y_tr = tr[FEATURES], tr["LABEL"].astype(int)
    X_te, y_te = te[FEATURES], te["LABEL"].astype(int)

    # penalty=None on purpose. L2 is the sklearn default and it shrinks every
    # coefficient toward zero, which would be indistinguishable from the
    # attenuation the unobserved noise term causes. Since the whole point is to
    # read the coefficients, the regulariser has to be off or the comparison
    # measures the regulariser.
    model = LogisticRegression(penalty=None, solver="lbfgs", max_iter=2000)
    model.fit(X_tr, y_tr)

    p_tr = model.predict_proba(X_tr)[:, 1]
    p_te = model.predict_proba(X_te)[:, 1]
    m_tr, m_te = _metrics(y_tr, p_tr), _metrics(y_te, p_te)

    reg = Registry(session=session, database_name="QCOMMERCE", schema_name="LAB")
    version = _next_version(reg)

    mv = reg.log_model(
        model,
        model_name=MODEL_NAME,
        version_name=version,
        sample_input_data=X_tr.head(100),
        options={"embed_local_ml_library": True},
        comment=("SLA breach at order placement. train=%d test=%d test_auc=%.4f "
                 "sklearn=%s" % (len(tr), len(te), m_te["roc_auc"], sklearn.__version__)),
        metrics={("%s_%s" % (sp, k)): v
                 for sp, mm in (("train", m_tr), ("test", m_te))
                 for k, v in mm.items()},
    )
    try:
        reg.get_model(MODEL_NAME).default = version
    except Exception:
        pass

    now = datetime.datetime.utcnow()

    metric_rows = []
    for split, mm in (("TRAIN", m_tr), ("TEST", m_te)):
        for k, v in mm.items():
            metric_rows.append([now, MODEL_NAME, version, split, k, v])
    session.create_dataframe(
        metric_rows,
        schema=["TRAINED_AT", "MODEL_NAME", "MODEL_VERSION", "SPLIT", "METRIC", "VALUE"],
    ).write.save_as_table("QCOMMERCE.OPS.MODEL_METRICS", mode="append")

    coef_rows = [[now, MODEL_NAME, version, f, float(c), GENERATOR[f]]
                 for f, c in zip(FEATURES, model.coef_[0])]
    coef_rows.append([now, MODEL_NAME, version, "(intercept)",
                      float(model.intercept_[0]), GENERATOR["(intercept)"]])
    session.create_dataframe(
        coef_rows,
        schema=["TRAINED_AT", "MODEL_NAME", "MODEL_VERSION",
                "FEATURE", "COEFFICIENT", "GENERATOR_WEIGHT"],
    ).write.save_as_table("QCOMMERCE.OPS.MODEL_COEFFICIENTS", mode="append")

    return ("%s %s logged | train n=%d auc=%.4f | test n=%d auc=%.4f pr_auc=%.4f "
            "brier=%.4f | calibration test mean_pred=%.4f vs actual=%.4f"
            % (MODEL_NAME, mv.version_name, m_tr["n"], m_tr["roc_auc"],
               m_te["n"], m_te["roc_auc"], m_te["pr_auc"], m_te["brier"],
               m_te["mean_predicted"], m_te["base_rate"]))
$$;

CALL LAB.SP_TRAIN_SLA_MODEL();

-- =============================================================================
-- STEP 3 — the model exists as an account object, not a file somewhere.
-- =============================================================================
SHOW MODELS IN SCHEMA LAB;
SHOW VERSIONS IN MODEL LAB.SLA_BREACH;

-- =============================================================================
-- STEP 4 — did it recover the process.
--
-- Fitted coefficients are expected to come in BELOW the generator weights.
-- The generator adds N(0, 0.50) to the logit and then draws the outcome from a
-- Bernoulli, and neither is observable, so the model is fitting a signal that
-- arrives blurred. Attenuation of that kind is the correct result and its
-- absence would be the suspicious one. What has to hold is the ordering:
-- distance strongest, then store load, then peak hour, then item count, and
-- the two placebos near zero.
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

SELECT MODEL_VERSION, SPLIT,
       MAX(IFF(METRIC = 'n', VALUE, NULL))::INT                     AS n,
       ROUND(MAX(IFF(METRIC = 'base_rate', VALUE, NULL)) * 100, 2)  AS actual_breach_pct,
       ROUND(MAX(IFF(METRIC = 'mean_predicted', VALUE, NULL)) * 100, 2) AS predicted_breach_pct,
       ROUND(MAX(IFF(METRIC = 'roc_auc', VALUE, NULL)), 4)          AS roc_auc,
       ROUND(MAX(IFF(METRIC = 'pr_auc', VALUE, NULL)), 4)           AS pr_auc,
       ROUND(MAX(IFF(METRIC = 'brier', VALUE, NULL)), 4)            AS brier
FROM   OPS.MODEL_METRICS
GROUP  BY MODEL_VERSION, SPLIT
ORDER  BY MODEL_VERSION, SPLIT DESC;

-- =============================================================================
-- STEP 5 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'model_beats_coin_flip_on_unseen_days', 'LAB.SLA_BREACH',
       (SELECT VALUE FROM OPS.MODEL_METRICS
         WHERE SPLIT = 'TEST' AND METRIC = 'roc_auc'
           AND TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS)) > 0.60,
       (SELECT ROUND(VALUE * 10000) FROM OPS.MODEL_METRICS
         WHERE SPLIT = 'TEST' AND METRIC = 'roc_auc'
           AND TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS)),
       'test ROC AUC above 0.60, in basis points',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'model_is_calibrated_on_unseen_days', 'LAB.SLA_BREACH',
       (SELECT ABS(MAX(IFF(METRIC = 'mean_predicted', VALUE, NULL))
                 - MAX(IFF(METRIC = 'base_rate', VALUE, NULL)))
        FROM OPS.MODEL_METRICS WHERE SPLIT = 'TEST'
          AND TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS)) < 0.03,
       (SELECT ROUND(ABS(MAX(IFF(METRIC = 'mean_predicted', VALUE, NULL))
                       - MAX(IFF(METRIC = 'base_rate', VALUE, NULL))) * 10000)
        FROM OPS.MODEL_METRICS WHERE SPLIT = 'TEST'
          AND TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS)),
       'predicted breach rate within 3 points of actual, in basis points',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'placebo_features_stayed_near_zero', 'OPS.MODEL_COEFFICIENTS',
       (SELECT COUNT(*) FROM OPS.MODEL_COEFFICIENTS
         WHERE GENERATOR_WEIGHT = 0 AND FEATURE <> '(intercept)'
           AND ABS(COEFFICIENT) >= 0.10
           AND TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_COEFFICIENTS)) = 0
       AND (SELECT COUNT(*) FROM OPS.MODEL_COEFFICIENTS
             WHERE GENERATOR_WEIGHT = 0 AND FEATURE <> '(intercept)'
           AND TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_COEFFICIENTS)) = 2,
       (SELECT COUNT(*) FROM OPS.MODEL_COEFFICIENTS
         WHERE GENERATOR_WEIGHT = 0 AND FEATURE <> '(intercept)'
           AND TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_COEFFICIENTS)),
       'both placebos present and both under 0.10 in absolute weight',
       (SELECT OBJECT_AGG(FEATURE, ROUND(COEFFICIENT, 4)::VARIANT)
        FROM OPS.MODEL_COEFFICIENTS WHERE GENERATOR_WEIGHT = 0 AND FEATURE <> '(intercept)'
          AND TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_COEFFICIENTS));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'drivers_ranked_as_the_source_ranks_them', 'OPS.MODEL_COEFFICIENTS',
       (SELECT MAX(IFF(FEATURE = 'F_DIST_5',  COEFFICIENT, NULL))
                 > MAX(IFF(FEATURE = 'F_ITEMS_5', COEFFICIENT, NULL))
             AND MAX(IFF(FEATURE = 'F_PEAK',      COEFFICIENT, NULL)) > 0
             AND MAX(IFF(FEATURE = 'F_LOAD_15',   COEFFICIENT, NULL)) > 0
        FROM OPS.MODEL_COEFFICIENTS
        WHERE TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_COEFFICIENTS)),
       (SELECT COUNT(*) FROM OPS.MODEL_COEFFICIENTS
        WHERE TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_COEFFICIENTS)),
       'distance outweighs basket size, and both congestion terms are positive',
       NULL;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('LAB.SLA_BREACH', 'OPS.MODEL_COEFFICIENTS')
ORDER  BY CHECK_TS DESC
LIMIT  4;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP MODEL IF EXISTS QCOMMERCE.LAB.SLA_BREACH;
-- DROP PROCEDURE IF EXISTS QCOMMERCE.LAB.SP_TRAIN_SLA_MODEL();

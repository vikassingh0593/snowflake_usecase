-- =============================================================================
-- sql/p9_ml_probe.sql — what machine learning is actually available here?
--
-- Two capabilities have already been refused by this account tier: Cortex AI
-- functions, and external network access. Both were discovered by attempting the
-- operation rather than by reading a privileges listing or a feature matrix, and
-- both times a SHOW-style check would have been reassuring and wrong.
--
-- Part 9 depends on three things that could each be gated independently:
--
--   SNOWFLAKE.ML functions    classical ML in SQL -- forecast, anomaly detection
--   snowflake-ml-python       the package, inside a Python procedure
--   Model Registry            versioned model storage in a schema
--
-- Knowing which of the three work decides the shape of the whole part, so this
-- runs before any modelling code is written.
--
-- COST: resumes WH_TRANSFORM_XS, creates and drops small objects, trains one
-- trivial model on 24 generated rows. Estimate 0.01-0.03 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p09:ml_probe';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- 1 — are the packages in the channel?
--
-- Necessary and not sufficient, exactly as it was for pypdf: this lists what the
-- channel carries, not what this account may compile against.
-- =============================================================================
SELECT PACKAGE_NAME, RUNTIME_VERSION, MAX(VERSION) AS LATEST
FROM   INFORMATION_SCHEMA.PACKAGES
WHERE  LANGUAGE = 'python'
  AND  PACKAGE_NAME IN ('snowflake-ml-python', 'scikit-learn', 'pandas', 'numpy',
                        'snowflake-snowpark-python', 'xgboost')
GROUP  BY PACKAGE_NAME, RUNTIME_VERSION
ORDER  BY PACKAGE_NAME, RUNTIME_VERSION;

-- =============================================================================
-- 2 — SNOWFLAKE.ML functions, on data small enough to be free.
--
-- These are classical ML rather than LLM inference, so the trial gate that
-- blocks Cortex should not apply. "Should not" is the reason to test it.
--
-- 24 generated rows with an obvious upward trend. The forecast is uninteresting;
-- whether CREATE SNOWFLAKE.ML.FORECAST is permitted is the whole question.
-- =============================================================================
CREATE OR REPLACE TEMPORARY TABLE LAB.TMP_SERIES AS
SELECT DATEADD(day, SEQ4(), '2026-01-01'::DATE)::TIMESTAMP_NTZ AS TS,
       100 + SEQ4() * 3 + UNIFORM(-5, 5, RANDOM())             AS VAL
FROM   TABLE(GENERATOR(ROWCOUNT => 24));

CREATE OR REPLACE SNOWFLAKE.ML.FORECAST LAB.TMP_FORECAST(
  INPUT_DATA => TABLE(LAB.TMP_SERIES),
  TIMESTAMP_COLNAME => 'TS',
  TARGET_COLNAME => 'VAL'
);

CALL LAB.TMP_FORECAST!FORECAST(FORECASTING_PERIODS => 3);

-- Anomaly detection, the second SNOWFLAKE.ML function this project plans to use.
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION LAB.TMP_ANOMALY(
  INPUT_DATA => TABLE(LAB.TMP_SERIES),
  TIMESTAMP_COLNAME => 'TS',
  TARGET_COLNAME => 'VAL',
  LABEL_COLNAME => ''
);

-- =============================================================================
-- 3 — can a Python procedure import snowflake-ml-python at all?
--
-- The package resolving at CREATE is not the same as it importing at run time,
-- so the procedure is called rather than merely created. pypdf taught that: a
-- package can compile into a function and fail on import.
-- =============================================================================
CREATE OR REPLACE PROCEDURE LAB.TMP_PROBE_ML()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'snowflake-ml-python', 'scikit-learn')
HANDLER = 'run'
AS
$$
def run(session):
    import sklearn
    out = ["scikit-learn " + sklearn.__version__]
    try:
        import snowflake.ml
        out.append("snowflake-ml-python " + getattr(snowflake.ml, "__version__", "unknown"))
    except Exception as exc:
        out.append("snowflake.ml IMPORT FAILED: %s: %s" % (type(exc).__name__, exc))
    try:
        from snowflake.ml.registry import Registry
        out.append("Registry importable")
    except Exception as exc:
        out.append("Registry IMPORT FAILED: %s: %s" % (type(exc).__name__, exc))
    return " | ".join(out)
$$;

CALL LAB.TMP_PROBE_ML();

-- =============================================================================
-- 4 — can a model actually be registered?
--
-- The sharpest test of the three. Registry writes objects into a schema, and
-- that is a distinct capability from importing the package -- external access
-- failed at exactly this shape: both building blocks created, and the object
-- that binds them refused.
--
-- A two-feature model on eight rows. Its predictions are meaningless; whether
-- log_model returns is the entire point.
-- =============================================================================
CREATE OR REPLACE PROCEDURE LAB.TMP_PROBE_REGISTRY()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'snowflake-ml-python', 'scikit-learn', 'pandas', 'numpy')
HANDLER = 'run'
AS
$$
def run(session):
    import pandas as pd
    from sklearn.linear_model import LogisticRegression
    from snowflake.ml.registry import Registry

    X = pd.DataFrame({"A": [1, 2, 3, 4, 5, 6, 7, 8],
                      "B": [1, 1, 1, 1, 0, 0, 0, 0]})
    y = [0, 0, 0, 0, 1, 1, 1, 1]
    model = LogisticRegression().fit(X, y)

    try:
        reg = Registry(session=session, database_name="QCOMMERCE", schema_name="LAB")
        mv = reg.log_model(model,
                           model_name="TMP_PROBE_MODEL",
                           version_name="V1",
                           sample_input_data=X)
        names = [m.name for m in reg.models()]
        reg.delete_model("TMP_PROBE_MODEL")
        return "Registry OK. logged %s, models seen: %s" % (mv.version_name, names)
    except Exception as exc:
        return "Registry FAILED: %s: %s" % (type(exc).__name__, exc)
$$;

CALL LAB.TMP_PROBE_REGISTRY();

-- =============================================================================
-- 5 — clean up. LAB is transient, but a probe should not leave litter.
-- =============================================================================
DROP SNOWFLAKE.ML.FORECAST           IF EXISTS LAB.TMP_FORECAST;
DROP SNOWFLAKE.ML.ANOMALY_DETECTION  IF EXISTS LAB.TMP_ANOMALY;
DROP PROCEDURE IF EXISTS LAB.TMP_PROBE_ML();
DROP PROCEDURE IF EXISTS LAB.TMP_PROBE_REGISTRY();
SHOW MODELS IN SCHEMA LAB;

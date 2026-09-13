-- =============================================================================
-- sql/p9_registry_fix.sql — three ways past the Model Registry version wall.
--
-- THE FAILURE, precisely:
--
--   Registry FAILED: 391525 (42601): Cannot create a Python function with the
--   specified packages. 'Packages not found:
--   snowflake-ml-python[version='<3,>=2.0']'
--
-- This is NOT the account tier refusing a capability, which is what Cortex and
-- external access did. Registry imports, the packages are present, and
-- log_model runs far enough to start creating the model's inference function.
-- It then asks the Anaconda channel for snowflake-ml-python >=2.0,<3 as that
-- function's runtime dependency, and the channel carries 1.9.2.
--
-- A version constraint that cannot be satisfied is a solvable problem, and
-- log_model has two documented levers for exactly this. Both are tried here
-- rather than picked, because guessing which one applies is how the last four
-- rounds went.
--
--   A  conda_dependencies pinned to what the channel actually has
--   B  embed_local_ml_library -- ship the library WITH the model instead of
--      resolving it from the channel at inference time
--   C  both together
--
-- Each runs in its own try block and reports its own outcome, so one failure
-- does not hide the other two.
--
-- COST: resumes WH_TRANSFORM_XS. Three eight-row models. Under 0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p09:registry_fix';
USE DATABASE QCOMMERCE;

CREATE OR REPLACE PROCEDURE LAB.TMP_REGISTRY_VARIANTS()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'snowflake-ml-python', 'scikit-learn', 'pandas', 'numpy')
HANDLER = 'run'
AS
$$
def run(session):
    import pandas as pd
    import sklearn
    from sklearn.linear_model import LogisticRegression
    from snowflake.ml.registry import Registry

    X = pd.DataFrame({"A": [1, 2, 3, 4, 5, 6, 7, 8],
                      "B": [1, 1, 1, 1, 0, 0, 0, 0]})
    y = [0, 0, 0, 0, 1, 1, 1, 1]
    model = LogisticRegression().fit(X, y)

    reg = Registry(session=session, database_name="QCOMMERCE", schema_name="LAB")
    sk = sklearn.__version__
    lines = ["scikit-learn in this runtime: " + sk]

    def attempt(label, name, **kw):
        try:
            mv = reg.log_model(model, model_name=name, version_name="V1",
                               sample_input_data=X, **kw)
            got = "OK version=%s" % mv.version_name
            try:
                reg.delete_model(name)
            except Exception:
                pass
            return "%s: %s" % (label, got)
        except Exception as exc:
            msg = str(exc).replace("\n", " ")[:260]
            return "%s: FAILED %s: %s" % (label, type(exc).__name__, msg)

    # A -- pin the dependency to what the channel actually carries. If the
    # >=2.0 constraint is auto-generated, naming the version should replace it.
    lines.append(attempt("A conda_dependencies", "TMP_REG_A",
                         conda_dependencies=["scikit-learn==%s" % sk]))

    # B -- embed the library with the model. This is the documented answer to
    # "snowflake-ml-python cannot be resolved at inference time": the model
    # carries its own copy rather than asking the channel for one.
    lines.append(attempt("B embed_local_ml_library", "TMP_REG_B",
                         options={"embed_local_ml_library": True}))

    # C -- both, in case the constraint comes from two places.
    lines.append(attempt("C both", "TMP_REG_C",
                         conda_dependencies=["scikit-learn==%s" % sk],
                         options={"embed_local_ml_library": True}))

    return " || ".join(lines)
$$;

CALL LAB.TMP_REGISTRY_VARIANTS();

SHOW MODELS IN SCHEMA LAB;

-- =============================================================================
-- The fallback, if all three fail.
--
-- Not a lesser demonstration. A model is a file: train it, serialise it, put it
-- on a stage, and load it in a scoring UDF. That is what a registry does with
-- lineage and version metadata wrapped around it, and doing it by hand makes
-- the mechanics visible rather than hiding them behind an API.
--
-- This probe proves only the round trip -- joblib to a stage and back, inside
-- Snowflake, with the model producing the same prediction after reload.
-- =============================================================================
CREATE STAGE IF NOT EXISTS LAB.STG_MODELS
  COMMENT = 'serialised models, if the registry cannot be used';

CREATE OR REPLACE PROCEDURE LAB.TMP_STAGE_ROUNDTRIP()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'scikit-learn', 'pandas', 'numpy', 'joblib')
HANDLER = 'run'
AS
$$
import os, tempfile
import joblib
import pandas as pd
from sklearn.linear_model import LogisticRegression


def run(session):
    X = pd.DataFrame({"A": [1, 2, 3, 4, 5, 6, 7, 8],
                      "B": [1, 1, 1, 1, 0, 0, 0, 0]})
    y = [0, 0, 0, 0, 1, 1, 1, 1]
    model = LogisticRegression().fit(X, y)
    before = model.predict_proba(X)[:, 1].round(6).tolist()

    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "probe_model.joblib")
    joblib.dump(model, path)
    session.file.put(path, "@QCOMMERCE.LAB.STG_MODELS",
                     overwrite=True, auto_compress=False)

    # Read it back through SnowflakeFile rather than trusting the local copy --
    # the point is that the stage round trip preserves the model, not that the
    # variable still exists in memory.
    from snowflake.snowpark.files import SnowflakeFile
    url = session.sql(
        "SELECT BUILD_SCOPED_FILE_URL(@QCOMMERCE.LAB.STG_MODELS, 'probe_model.joblib')"
    ).collect()[0][0]
    with SnowflakeFile.open(url, "rb") as f:
        reloaded = joblib.load(f)
    after = reloaded.predict_proba(X)[:, 1].round(6).tolist()

    return "stage round trip %s (before=%s after=%s)" % (
        "IDENTICAL" if before == after else "DIFFERENT", before[:2], after[:2])
$$;

CALL LAB.TMP_STAGE_ROUNDTRIP();

-- =============================================================================
-- TEARDOWN
-- =============================================================================
DROP PROCEDURE IF EXISTS LAB.TMP_REGISTRY_VARIANTS();
DROP PROCEDURE IF EXISTS LAB.TMP_STAGE_ROUNDTRIP();

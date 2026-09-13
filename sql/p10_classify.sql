-- =============================================================================
-- PART 10 / STEP 2 — complaint text -> reason code.
--
-- Ten classes, 60 hand labels, 240 documents to classify. This file reads
-- CORE.COMPLAINT and nothing else. The answer key loaded by
-- scripts/p10_truth.sh is not referenced by any statement here, and that is
-- checkable rather than asserted -- comment lines excluded, since this comment
-- would otherwise defeat its own check:
--
--   grep -v '^--' sql/p10_classify.sql | grep -c COMPLAINT_TRUTH    -> 0
--
-- WHAT THIS IS UP AGAINST, stated before the numbers arrive.
--
-- Each reason code is generated from exactly three sentence templates. The 60
-- labels are a random 20% sample and not stratified, so template coverage is
-- uneven: four classes train on all three of their templates, four on two, and
-- APP_ISSUE and PACKAGING on one of three. 203 of the 240 held-out documents
-- share a template with something in the training set, and for a bag-of-words
-- model a template stem is very nearly a fingerprint.
--
-- That sets a floor of about 84.6% accuracy from memorisation alone, against a
-- 29.6% baseline of always guessing LATE_DELIVERY. It also means ACCURACY IS
-- THE WRONG HEADLINE. LATE_DELIVERY is 30% of the held-out set and will carry
-- the average while the tail classes fail. Macro-F1 is reported first
-- everywhere, and the per-class recall in p10_eval.sql is what actually
-- matters.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p10:classify';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — train, cross-validate, predict, register.
--
-- The order matters. Predictions are written before the registry is attempted,
-- so that a registry failure costs a model version and nothing else. Part 9
-- established that the registry works on this account with
-- embed_local_ml_library, but a text pipeline takes a STRING input rather than
-- a frame of floats and whether signature inference handles that is UNVERIFIED.
-- =============================================================================
CREATE OR REPLACE PROCEDURE LAB.SP_TRAIN_COMPLAINT_MODEL()
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
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, f1_score
from sklearn.model_selection import StratifiedKFold, cross_val_predict
from sklearn.pipeline import Pipeline

MODEL_NAME = "COMPLAINT_REASON"
TEXT = "COMPLAINT_TEXT"
LABEL = "REASON_CODE"


def build_pipeline():
    return Pipeline([
        # token_pattern keeps alphabetic tokens only. Every complaint carries
        # item names, pack sizes, store codes, minute counts and rupee amounts
        # drawn at random and shared across all ten classes -- "1L", "500g",
        # "DS003", "17788". None of it separates the classes and all of it
        # would be vocabulary. Filtering in the token pattern rather than in a
        # custom preprocessor keeps the pipeline picklable, which the registry
        # needs.
        ("tfidf", TfidfVectorizer(ngram_range=(1, 2),
                                  sublinear_tf=True,
                                  min_df=1,
                                  token_pattern=r"(?u)\b[a-z]{2,}\b")),
        # class_weight balanced because the labels run 17 down to 2 and the
        # metric that matters is macro-F1. Unweighted, the model buys accuracy
        # by defaulting to LATE_DELIVERY, which is exactly the failure the
        # evaluation is designed to expose.
        #
        # C is left at its default. Tuning it would mean selecting on the same
        # 60 rows the model trains on, with two-example classes and therefore
        # no honest validation split -- the tuned number would be a measure of
        # the tuning, not of the model.
        ("clf", LogisticRegression(class_weight="balanced", max_iter=2000)),
    ])


def run(session):
    df = session.table("QCOMMERCE.CORE.COMPLAINT").to_pandas()
    tr = df[df[LABEL].notna()].copy()
    if len(tr) == 0:
        return "ABORT: no labelled rows in CORE.COMPLAINT"

    classes = sorted(tr[LABEL].unique())
    smallest = int(tr[LABEL].value_counts().min())

    # Honest in-sample estimate, computed without the answer key. Stratified
    # k-fold is capped by the smallest class, which has two members, so this is
    # two folds: each model sees one example of the rarest classes instead of
    # two. It should therefore come in BELOW the real held-out score, and the
    # size of that gap is itself worth knowing.
    cv_acc = cv_f1 = float("nan")
    n_splits = min(2, smallest)
    if n_splits >= 2:
        cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=42)
        cv_pred = cross_val_predict(build_pipeline(), tr[TEXT], tr[LABEL], cv=cv)
        cv_acc = float(accuracy_score(tr[LABEL], cv_pred))
        cv_f1 = float(f1_score(tr[LABEL], cv_pred, average="macro", zero_division=0))

    pipe = build_pipeline()
    pipe.fit(tr[TEXT], tr[LABEL])
    vocab = len(pipe.named_steps["tfidf"].vocabulary_)

    fit_pred = pipe.predict(tr[TEXT])
    fit_acc = float(accuracy_score(tr[LABEL], fit_pred))
    fit_f1 = float(f1_score(tr[LABEL], fit_pred, average="macro", zero_division=0))

    pred = pipe.predict(df[TEXT])
    conf = pipe.predict_proba(df[TEXT]).max(axis=1)

    now = datetime.datetime.utcnow()
    version = "V1"

    rows = [[now, version, str(t), str(p), float(c),
             bool(pd.notna(l)), (None if pd.isna(l) else str(l))]
            for t, p, c, l in zip(df["TICKET_ID"], pred, conf, df[LABEL])]
    session.create_dataframe(
        rows,
        schema=["SCORED_AT", "MODEL_VERSION", "TICKET_ID", "PREDICTED_REASON_CODE",
                "CONFIDENCE", "WAS_TRAINED_ON", "TRAIN_LABEL"],
    ).write.save_as_table("QCOMMERCE.LAB.COMPLAINT_PREDICTION", mode="overwrite")

    metric_rows = []
    for split, acc, f1, n in (("FIT", fit_acc, fit_f1, len(tr)),
                              ("CV", cv_acc, cv_f1, len(tr))):
        for k, v in (("accuracy", acc), ("macro_f1", f1), ("n", float(n))):
            if v == v:                       # skip NaN, which means CV was skipped
                metric_rows.append([now, MODEL_NAME, version, split, k, float(v)])
    metric_rows.append([now, MODEL_NAME, version, "FIT", "vocabulary", float(vocab)])
    session.create_dataframe(
        metric_rows,
        schema=["TRAINED_AT", "MODEL_NAME", "MODEL_VERSION", "SPLIT", "METRIC", "VALUE"],
    ).write.save_as_table("QCOMMERCE.OPS.MODEL_METRICS", mode="append")

    # Everything above is committed. Only the registry can fail from here.
    reg_note = "registry not attempted"
    try:
        from snowflake.ml.registry import Registry
        reg = Registry(session=session, database_name="QCOMMERCE", schema_name="LAB")
        try:
            taken = {v.version_name.upper() for v in reg.get_model(MODEL_NAME).versions()}
        except Exception:
            taken = set()
        n = 1
        while "V%d" % n in taken:
            n += 1
        rv = "V%d" % n
        mv = reg.log_model(
            pipe,
            model_name=MODEL_NAME,
            version_name=rv,
            sample_input_data=tr[[TEXT]].head(20),
            options={"embed_local_ml_library": True},
            comment=("complaint text -> reason code. %d labels, %d classes, "
                     "vocab %d, sklearn %s" % (len(tr), len(classes), vocab,
                                               sklearn.__version__)),
            metrics={"fit_accuracy": fit_acc, "fit_macro_f1": fit_f1,
                     "cv_accuracy": cv_acc, "cv_macro_f1": cv_f1},
        )
        reg_note = "registry OK version=%s" % mv.version_name
    except Exception as exc:
        reg_note = "registry FAILED %s: %s" % (
            type(exc).__name__, str(exc).replace("\n", " ")[:200])

    return ("%s trained on %d labels across %d classes (smallest %d) | vocabulary %d | "
            "fit acc=%.4f macro_f1=%.4f | %d-fold CV acc=%.4f macro_f1=%.4f | "
            "scored %d | %s"
            % (MODEL_NAME, len(tr), len(classes), smallest, vocab,
               fit_acc, fit_f1, n_splits, cv_acc, cv_f1, len(df), reg_note))
$$;

CALL LAB.SP_TRAIN_COMPLAINT_MODEL();

-- =============================================================================
-- STEP 2 — what it predicted, without reference to whether it was right.
--
-- Nothing below can score the model. The 240 unlabelled rows have no truth in
-- this database yet, by design, so all these show is the SHAPE of the output:
-- whether the predicted distribution resembles the labelled one, and whether
-- confidence separates the rows it will get right from the ones it will not.
-- =============================================================================
SELECT PREDICTED_REASON_CODE,
       COUNT(*)                                                   AS predicted,
       SUM(IFF(WAS_TRAINED_ON, 1, 0))                             AS among_the_60,
       SUM(IFF(WAS_TRAINED_ON, 0, 1))                             AS among_the_240,
       ROUND(AVG(CONFIDENCE), 3)                                  AS avg_confidence,
       ROUND(MIN(CONFIDENCE), 3)                                  AS min_confidence
FROM   LAB.COMPLAINT_PREDICTION
GROUP  BY PREDICTED_REASON_CODE
ORDER  BY predicted DESC;

-- The training rows are a memorisation check and nothing more. 60 examples and
-- a vocabulary in the hundreds will fit perfectly; a model that CANNOT
-- reproduce its own training labels is broken, but one that can has proved
-- nothing about the other 240.
SELECT SUM(IFF(PREDICTED_REASON_CODE = TRAIN_LABEL, 1, 0))        AS reproduced,
       COUNT(*)                                                   AS training_rows,
       ROUND(100.0 * SUM(IFF(PREDICTED_REASON_CODE = TRAIN_LABEL, 1, 0))
             / COUNT(*), 2)                                       AS pct
FROM   LAB.COMPLAINT_PREDICTION
WHERE  WAS_TRAINED_ON;

-- Confidence deciles over the 240. If the model is calibrated at all, the low
-- deciles are where the unseen templates ended up.
SELECT fifth,
       COUNT(*)                                                   AS complaints,
       ROUND(MIN(CONFIDENCE), 3)                                  AS from_conf,
       ROUND(MAX(CONFIDENCE), 3)                                  AS to_conf,
       COUNT(DISTINCT PREDICTED_REASON_CODE)                      AS distinct_codes
FROM (
    -- NTILE has to be assigned in here. A window function is evaluated after
    -- GROUP BY, so one cannot sit in the select list of the query that groups
    -- by it: "CONFIDENCE is not a valid group by expression".
    SELECT NTILE(5) OVER (ORDER BY CONFIDENCE DESC) AS fifth,
           CONFIDENCE, PREDICTED_REASON_CODE
    FROM   LAB.COMPLAINT_PREDICTION
    WHERE  NOT WAS_TRAINED_ON
)
GROUP  BY fifth
ORDER  BY fifth;

SELECT MODEL_VERSION, SPLIT, METRIC, ROUND(VALUE, 4) AS value
FROM   OPS.MODEL_METRICS
WHERE  MODEL_NAME = 'COMPLAINT_REASON'
  AND  TRAINED_AT = (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS
                     WHERE MODEL_NAME = 'COMPLAINT_REASON')
ORDER  BY SPLIT, METRIC;

SHOW MODELS IN SCHEMA LAB;

-- =============================================================================
-- STEP 3 — checks. None of these can look at the answer key either.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'every_complaint_predicted_once', 'LAB.COMPLAINT_PREDICTION',
       (SELECT COUNT(*) FROM LAB.COMPLAINT_PREDICTION)
         = (SELECT COUNT(*) FROM CORE.COMPLAINT)
       AND (SELECT COUNT(DISTINCT TICKET_ID) FROM LAB.COMPLAINT_PREDICTION)
         = (SELECT COUNT(*) FROM LAB.COMPLAINT_PREDICTION)
       AND (SELECT COUNT(*) FROM LAB.COMPLAINT_PREDICTION) > 0,
       (SELECT COUNT(*) FROM LAB.COMPLAINT_PREDICTION),
       'one prediction per complaint, no duplicates, not zero rows',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'model_reproduces_its_training_labels', 'LAB.COMPLAINT_PREDICTION',
       (SELECT SUM(IFF(PREDICTED_REASON_CODE = TRAIN_LABEL, 1, 0))
        FROM LAB.COMPLAINT_PREDICTION WHERE WAS_TRAINED_ON) >= 57
       AND (SELECT COUNT(*) FROM LAB.COMPLAINT_PREDICTION WHERE WAS_TRAINED_ON) = 60,
       (SELECT SUM(IFF(PREDICTED_REASON_CODE = TRAIN_LABEL, 1, 0))
        FROM LAB.COMPLAINT_PREDICTION WHERE WAS_TRAINED_ON),
       'at least 57 of 60 training labels reproduced -- a model that cannot '
         || 'fit 60 examples is broken, though fitting them proves nothing',
       NULL;

-- The failure this guards against is a model that collapses onto the majority
-- class. It would score 30% and look like a working classifier in a single
-- accuracy number.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'predictions_are_not_one_class', 'LAB.COMPLAINT_PREDICTION',
       (SELECT COUNT(DISTINCT PREDICTED_REASON_CODE)
        FROM LAB.COMPLAINT_PREDICTION WHERE NOT WAS_TRAINED_ON) >= 8
       AND (SELECT MAX(n) FROM (SELECT COUNT(*) AS n FROM LAB.COMPLAINT_PREDICTION
                                WHERE NOT WAS_TRAINED_ON
                                GROUP BY PREDICTED_REASON_CODE)) < 120,
       (SELECT COUNT(DISTINCT PREDICTED_REASON_CODE)
        FROM LAB.COMPLAINT_PREDICTION WHERE NOT WAS_TRAINED_ON),
       'at least 8 of 10 codes predicted among the 240, and no single code '
         || 'takes more than half of them',
       (SELECT OBJECT_AGG(PREDICTED_REASON_CODE, n::VARIANT)
        FROM (SELECT PREDICTED_REASON_CODE, COUNT(*) AS n
              FROM LAB.COMPLAINT_PREDICTION WHERE NOT WAS_TRAINED_ON
              GROUP BY PREDICTED_REASON_CODE));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'confidence_is_a_probability', 'LAB.COMPLAINT_PREDICTION',
       (SELECT COUNT(*) FROM LAB.COMPLAINT_PREDICTION
         WHERE CONFIDENCE IS NULL OR CONFIDENCE < 0.1 OR CONFIDENCE > 1) = 0
       AND (SELECT COUNT(DISTINCT ROUND(CONFIDENCE, 4))
            FROM LAB.COMPLAINT_PREDICTION) > 50,
       (SELECT COUNT(DISTINCT ROUND(CONFIDENCE, 4)) FROM LAB.COMPLAINT_PREDICTION),
       'max class probability in [0.1, 1] and more than 50 distinct values',
       OBJECT_CONSTRUCT('min', (SELECT ROUND(MIN(CONFIDENCE), 4) FROM LAB.COMPLAINT_PREDICTION),
                        'max', (SELECT ROUND(MAX(CONFIDENCE), 4) FROM LAB.COMPLAINT_PREDICTION));

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET = 'LAB.COMPLAINT_PREDICTION'
ORDER  BY CHECK_TS DESC
LIMIT  4;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE     IF EXISTS QCOMMERCE.LAB.COMPLAINT_PREDICTION;
-- DROP MODEL     IF EXISTS QCOMMERCE.LAB.COMPLAINT_REASON;
-- DROP PROCEDURE IF EXISTS QCOMMERCE.LAB.SP_TRAIN_COMPLAINT_MODEL();

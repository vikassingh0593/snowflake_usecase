-- =============================================================================
-- PART 10 / STEP 3 — score the classifier against the answer key.
--
-- This is the only file in the project that reads the complaint answer key.
-- Nothing that builds a feature, fits a model or writes a prediction touches
-- it. The key was loaded by scripts/p10_truth.sh into OPS, on an internal
-- stage, never into RAW or CORE where a feature query might reach it by
-- accident.
--
-- The 60 training rows are reported separately and are not part of any
-- headline. A model that reproduces its own training labels has demonstrated
-- that it fits, not that it works.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p10:eval';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — the headline, and the baseline it has to beat.
--
-- Always guessing LATE_DELIVERY scores about 30% on this corpus. Memorising
-- the templates that appear in training reaches about 84.6% without
-- generalising at all. Both numbers are printed beside the model's so that the
-- model's number means something.
-- =============================================================================
WITH scored AS (
    SELECT p.TICKET_ID,
           p.PREDICTED_REASON_CODE       AS pred,
           t.REASON_CODE                 AS actual,
           p.CONFIDENCE,
           p.WAS_TRAINED_ON
    FROM      LAB.COMPLAINT_PREDICTION p
    JOIN      OPS.COMPLAINT_TRUTH      t ON t.TICKET_ID = p.TICKET_ID
),
majority AS (
    SELECT actual AS code, COUNT(*) AS n
    FROM   scored WHERE NOT WAS_TRAINED_ON
    GROUP  BY actual ORDER BY n DESC LIMIT 1
)
SELECT IFF(WAS_TRAINED_ON, 'trained on (not a result)', 'held out (the result)') AS split,
       COUNT(*)                                                    AS complaints,
       SUM(IFF(pred = actual, 1, 0))                               AS correct,
       ROUND(100.0 * SUM(IFF(pred = actual, 1, 0)) / COUNT(*), 2)  AS accuracy_pct,
       ROUND(100.0 * (SELECT n FROM majority)
             / (SELECT COUNT(*) FROM scored WHERE NOT WAS_TRAINED_ON), 2) AS baseline_pct,
       ROUND(AVG(CONFIDENCE), 3)                                   AS avg_confidence
FROM   scored
GROUP  BY WAS_TRAINED_ON
ORDER  BY split;

-- =============================================================================
-- STEP 2 — per class, on the 240 held out. This is the table that matters.
--
-- PREC rather than PRECISION: PRECISION is a keyword in a numeric type
-- declaration. Fourth reserved-word collision in this project after SAMPLE,
-- ROWS and CHECK.
-- =============================================================================
WITH held AS (
    SELECT p.PREDICTED_REASON_CODE AS pred, t.REASON_CODE AS actual
    FROM      LAB.COMPLAINT_PREDICTION p
    JOIN      OPS.COMPLAINT_TRUTH      t ON t.TICKET_ID = p.TICKET_ID
    WHERE NOT p.WAS_TRAINED_ON
),
per_class AS (
    SELECT c.REASON_CODE                                            AS class,
           SUM(IFF(h.actual = c.REASON_CODE, 1, 0))                 AS support,
           SUM(IFF(h.pred   = c.REASON_CODE, 1, 0))                 AS predicted,
           SUM(IFF(h.actual = c.REASON_CODE
                   AND h.pred = c.REASON_CODE, 1, 0))               AS tp
    FROM       RAW.COMPLAINT_REASON_CODE c
    CROSS JOIN held h
    GROUP BY   c.REASON_CODE
),
labels AS (
    SELECT REASON_CODE, COUNT(*) AS trained_on
    FROM   CORE.COMPLAINT WHERE IS_LABELLED GROUP BY REASON_CODE
)
SELECT pc.class,
       l.trained_on,
       pc.support,
       pc.predicted,
       pc.tp,
       ROUND(pc.tp / NULLIF(pc.predicted, 0), 3)                    AS prec,
       ROUND(pc.tp / NULLIF(pc.support, 0), 3)                      AS recall,
       ROUND(2.0 * pc.tp / NULLIF(pc.predicted + pc.support, 0), 3) AS f1
FROM      per_class pc
LEFT JOIN labels    l ON l.REASON_CODE = pc.class
ORDER BY  pc.support DESC;

-- Macro averages weight every class equally, which is the point: the three
-- rarest classes are 12% of the corpus and would be invisible in accuracy.
WITH held AS (
    SELECT p.PREDICTED_REASON_CODE AS pred, t.REASON_CODE AS actual
    FROM      LAB.COMPLAINT_PREDICTION p
    JOIN      OPS.COMPLAINT_TRUTH      t ON t.TICKET_ID = p.TICKET_ID
    WHERE NOT p.WAS_TRAINED_ON
),
per_class AS (
    SELECT c.REASON_CODE AS class,
           SUM(IFF(h.actual = c.REASON_CODE, 1, 0))   AS support,
           SUM(IFF(h.pred   = c.REASON_CODE, 1, 0))   AS predicted,
           SUM(IFF(h.actual = c.REASON_CODE AND h.pred = c.REASON_CODE, 1, 0)) AS tp
    FROM RAW.COMPLAINT_REASON_CODE c CROSS JOIN held h
    GROUP BY c.REASON_CODE
)
SELECT COUNT(*)                                                        AS classes,
       ROUND(AVG(tp / NULLIF(predicted, 0)), 4)                        AS macro_precision,
       ROUND(AVG(tp / NULLIF(support, 0)), 4)                          AS macro_recall,
       ROUND(AVG(2.0 * tp / NULLIF(predicted + support, 0)), 4)        AS macro_f1,
       ROUND(SUM(tp) / SUM(support), 4)                                AS accuracy
FROM   per_class;

-- =============================================================================
-- STEP 3 — where it went wrong. Only the confusions that actually occurred.
-- A 10x10 matrix is 90 empty cells and two interesting ones.
-- =============================================================================
SELECT t.REASON_CODE                     AS actual,
       p.PREDICTED_REASON_CODE           AS predicted_as,
       COUNT(*)                          AS n,
       ROUND(AVG(p.CONFIDENCE), 3)       AS avg_confidence
FROM      LAB.COMPLAINT_PREDICTION p
JOIN      OPS.COMPLAINT_TRUTH      t ON t.TICKET_ID = p.TICKET_ID
WHERE NOT p.WAS_TRAINED_ON
  AND  p.PREDICTED_REASON_CODE <> t.REASON_CODE
GROUP  BY actual, predicted_as
ORDER  BY n DESC, actual;

-- Does confidence know when it is wrong? If the low-confidence rows are where
-- the errors concentrate, the score is usable as a routing threshold -- send
-- the bottom fifth to a human and the rest straight to a queue.
SELECT NTILE(5) OVER (ORDER BY CONFIDENCE DESC)                    AS fifth,
       COUNT(*)                                                    AS complaints,
       ROUND(MIN(CONFIDENCE), 3)                                   AS from_conf,
       ROUND(MAX(CONFIDENCE), 3)                                   AS to_conf,
       SUM(IFF(pred = actual, 1, 0))                               AS correct,
       ROUND(100.0 * SUM(IFF(pred = actual, 1, 0)) / COUNT(*), 1)  AS accuracy_pct
FROM (
    SELECT p.PREDICTED_REASON_CODE AS pred, t.REASON_CODE AS actual, p.CONFIDENCE
    FROM      LAB.COMPLAINT_PREDICTION p
    JOIN      OPS.COMPLAINT_TRUTH      t ON t.TICKET_ID = p.TICKET_ID
    WHERE NOT p.WAS_TRAINED_ON
)
GROUP  BY fifth
ORDER  BY fifth;

-- =============================================================================
-- STEP 4 — record the held-out result beside the cross-validated one.
--
-- The CV figure in p10_classify.sql was computed from labelled data only, with
-- two folds because the rarest class has two members. It should read LOW
-- against the held-out result: each CV model trained on 30 rows where the
-- final model trained on 60, and on one example of the rarest classes rather
-- than two. The size of that gap says how far a CV estimate can be trusted
-- when the labels are this thin.
-- =============================================================================
INSERT INTO OPS.MODEL_METRICS (TRAINED_AT, MODEL_NAME, MODEL_VERSION, SPLIT, METRIC, VALUE)
WITH held AS (
    SELECT p.PREDICTED_REASON_CODE AS pred, t.REASON_CODE AS actual
    FROM      LAB.COMPLAINT_PREDICTION p
    JOIN      OPS.COMPLAINT_TRUTH      t ON t.TICKET_ID = p.TICKET_ID
    WHERE NOT p.WAS_TRAINED_ON
),
per_class AS (
    SELECT c.REASON_CODE AS class,
           SUM(IFF(h.actual = c.REASON_CODE, 1, 0))   AS support,
           SUM(IFF(h.pred   = c.REASON_CODE, 1, 0))   AS predicted,
           SUM(IFF(h.actual = c.REASON_CODE AND h.pred = c.REASON_CODE, 1, 0)) AS tp
    FROM RAW.COMPLAINT_REASON_CODE c CROSS JOIN held h
    GROUP BY c.REASON_CODE
),
agg AS (
    SELECT AVG(2.0 * tp / NULLIF(predicted + support, 0)) AS macro_f1,
           AVG(tp / NULLIF(support, 0))                   AS macro_recall,
           SUM(tp) / SUM(support)                         AS accuracy,
           SUM(support)                                   AS n
    FROM per_class
)
SELECT ts, 'COMPLAINT_REASON', 'V1', 'HELDOUT', METRIC, VALUE
FROM (
    SELECT (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS
            WHERE MODEL_NAME = 'COMPLAINT_REASON')      AS ts,
           'macro_f1' AS METRIC, macro_f1     AS VALUE FROM agg
    UNION ALL
    SELECT (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS
            WHERE MODEL_NAME = 'COMPLAINT_REASON'),
           'macro_recall', macro_recall               FROM agg
    UNION ALL
    SELECT (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS
            WHERE MODEL_NAME = 'COMPLAINT_REASON'),
           'accuracy',     accuracy                   FROM agg
    UNION ALL
    SELECT (SELECT MAX(TRAINED_AT) FROM OPS.MODEL_METRICS
            WHERE MODEL_NAME = 'COMPLAINT_REASON'),
           'n',            n                          FROM agg
);

SELECT SPLIT,
       MAX(IFF(METRIC = 'n', VALUE, NULL))::INT                  AS n,
       ROUND(MAX(IFF(METRIC = 'accuracy', VALUE, NULL)), 4)      AS accuracy,
       ROUND(MAX(IFF(METRIC = 'macro_f1', VALUE, NULL)), 4)      AS macro_f1,
       ROUND(MAX(IFF(METRIC = 'macro_recall', VALUE, NULL)), 4)  AS macro_recall
FROM   OPS.MODEL_METRICS
WHERE  MODEL_NAME = 'COMPLAINT_REASON'
GROUP  BY SPLIT
ORDER  BY SPLIT;

-- =============================================================================
-- STEP 5 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'answer_key_covers_every_prediction', 'OPS.COMPLAINT_TRUTH',
       (SELECT COUNT(*) FROM LAB.COMPLAINT_PREDICTION p
         JOIN OPS.COMPLAINT_TRUTH t ON t.TICKET_ID = p.TICKET_ID)
         = (SELECT COUNT(*) FROM LAB.COMPLAINT_PREDICTION)
       AND (SELECT COUNT(*) FROM OPS.COMPLAINT_TRUTH) = 300,
       (SELECT COUNT(*) FROM OPS.COMPLAINT_TRUTH),
       'the key has 300 rows and joins every prediction',
       NULL;

-- The key must also agree with the 60 hand labels. If the generator that
-- produced the key drifted from the corpus that was uploaded, this is where it
-- shows -- and every number above would be scoring the wrong documents.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'answer_key_agrees_with_the_hand_labels', 'OPS.COMPLAINT_TRUTH',
       (SELECT COUNT(*) FROM CORE.COMPLAINT c
         JOIN OPS.COMPLAINT_TRUTH t ON t.TICKET_ID = c.TICKET_ID
         WHERE c.IS_LABELLED AND c.REASON_CODE <> t.REASON_CODE) = 0
       AND (SELECT COUNT(*) FROM CORE.COMPLAINT WHERE IS_LABELLED) = 60,
       (SELECT COUNT(*) FROM CORE.COMPLAINT c
         JOIN OPS.COMPLAINT_TRUTH t ON t.TICKET_ID = c.TICKET_ID
         WHERE c.IS_LABELLED AND c.REASON_CODE <> t.REASON_CODE),
       'all 60 hand labels match the regenerated key exactly',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
WITH held AS (
    SELECT p.PREDICTED_REASON_CODE AS pred, t.REASON_CODE AS actual
    FROM LAB.COMPLAINT_PREDICTION p JOIN OPS.COMPLAINT_TRUTH t ON t.TICKET_ID = p.TICKET_ID
    WHERE NOT p.WAS_TRAINED_ON
)
SELECT 'beats_guessing_the_commonest_class', 'LAB.COMPLAINT_PREDICTION',
       AVG(IFF(pred = actual, 1.0, 0.0)) > 0.59,
       ROUND(AVG(IFF(pred = actual, 1.0, 0.0)) * 10000),
       'held-out accuracy above twice the 29.6% majority baseline, in basis points',
       NULL
FROM held;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
WITH held AS (
    SELECT p.PREDICTED_REASON_CODE AS pred, t.REASON_CODE AS actual
    FROM LAB.COMPLAINT_PREDICTION p JOIN OPS.COMPLAINT_TRUTH t ON t.TICKET_ID = p.TICKET_ID
    WHERE NOT p.WAS_TRAINED_ON
),
per_class AS (
    SELECT c.REASON_CODE AS class,
           SUM(IFF(h.actual = c.REASON_CODE, 1, 0)) AS support,
           SUM(IFF(h.pred   = c.REASON_CODE, 1, 0)) AS predicted,
           SUM(IFF(h.actual = c.REASON_CODE AND h.pred = c.REASON_CODE, 1, 0)) AS tp
    FROM RAW.COMPLAINT_REASON_CODE c CROSS JOIN held h
    GROUP BY c.REASON_CODE
)
SELECT 'macro_f1_clears_the_memorisation_floor', 'LAB.COMPLAINT_PREDICTION',
       AVG(2.0 * tp / NULLIF(predicted + support, 0)) > 0.60
       AND COUNT(*) = 10,
       ROUND(AVG(2.0 * tp / NULLIF(predicted + support, 0)) * 10000),
       'macro-F1 above 0.60 across all 10 classes, in basis points',
       (SELECT OBJECT_AGG(class, ROUND(2.0 * tp / NULLIF(predicted + support, 0), 3)::VARIANT)
        FROM per_class)
FROM per_class;

-- The prediction made before any of this ran: the classes that trained on one
-- of their three templates are the ones that fail. If this check passes, the
-- template-coverage account of the errors holds. If it fails, the errors are
-- somewhere else and that account was wrong.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
WITH held AS (
    SELECT p.PREDICTED_REASON_CODE AS pred, t.REASON_CODE AS actual
    FROM LAB.COMPLAINT_PREDICTION p JOIN OPS.COMPLAINT_TRUTH t ON t.TICKET_ID = p.TICKET_ID
    WHERE NOT p.WAS_TRAINED_ON
),
rec AS (
    SELECT c.REASON_CODE AS class,
           SUM(IFF(h.actual = c.REASON_CODE AND h.pred = c.REASON_CODE, 1, 0))
             / NULLIF(SUM(IFF(h.actual = c.REASON_CODE, 1, 0)), 0) AS recall
    FROM RAW.COMPLAINT_REASON_CODE c CROSS JOIN held h
    GROUP BY c.REASON_CODE
)
SELECT 'thin_template_coverage_explains_the_errors', 'LAB.COMPLAINT_PREDICTION',
       AVG(IFF(class IN ('APP_ISSUE', 'PACKAGING'), recall, NULL))
         < AVG(IFF(class IN ('LATE_DELIVERY', 'MISSING_ITEM',
                             'PAYMENT_ISSUE', 'REFUND_DELAY'), recall, NULL))
       AND COUNT(*) = 10,
       ROUND(AVG(IFF(class IN ('APP_ISSUE', 'PACKAGING'), recall, NULL)) * 10000),
       'the two classes trained on 1 of 3 templates recall worse than the four '
         || 'trained on 3 of 3, in basis points',
       OBJECT_CONSTRUCT(
         'one_of_three_templates', ROUND(AVG(IFF(class IN ('APP_ISSUE', 'PACKAGING'),
                                                 recall, NULL)), 3),
         'three_of_three',         ROUND(AVG(IFF(class IN ('LATE_DELIVERY', 'MISSING_ITEM',
                                                 'PAYMENT_ISSUE', 'REFUND_DELAY'),
                                                 recall, NULL)), 3))
FROM rec;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('OPS.COMPLAINT_TRUTH', 'LAB.COMPLAINT_PREDICTION')
ORDER  BY CHECK_TS DESC
LIMIT  5;

-- =============================================================================
-- PART 10 / STEP 5 — the two approaches, on the same 240.
--
-- Approach A: TF-IDF over word unigrams and bigrams into a balanced logistic
-- regression, trained in a stored procedure, registered as a model object,
-- scored through the registry's generated function.
--
-- Approach B: signed feature hashing into a 256-dimensional unit vector and
-- one nearest neighbour by cosine. No training step, no model artefact, no
-- Python at inference -- a window function.
--
-- They share nothing but the input text and the 60 labels. If they land in the
-- same place, the limit is the corpus and the label sample rather than either
-- method, and adding a third lexical model would not move it.
--
-- Reads the answer key. Nothing that builds a feature or fits a model does.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p10:compare';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — head to head.
-- =============================================================================
WITH both AS (
    SELECT t.TICKET_ID,
           t.REASON_CODE                      AS actual,
           m.PREDICTED_REASON_CODE            AS tfidf,
           k.PREDICTED_REASON_CODE            AS knn
    FROM      OPS.COMPLAINT_TRUTH          t
    JOIN      LAB.COMPLAINT_PREDICTION     m ON m.TICKET_ID = t.TICKET_ID
    JOIN      LAB.COMPLAINT_KNN_PREDICTION k ON k.TICKET_ID = t.TICKET_ID
    WHERE NOT m.WAS_TRAINED_ON
),
long AS (
    SELECT 'A  TF-IDF + logistic regression' AS approach, actual, tfidf AS pred FROM both
    UNION ALL
    SELECT 'B  hashed vector + 1-NN',                     actual, knn        FROM both
),
per_class AS (
    SELECT l.approach,
           c.REASON_CODE                                                   AS class,
           SUM(IFF(l.actual = c.REASON_CODE, 1, 0))                        AS support,
           SUM(IFF(l.pred   = c.REASON_CODE, 1, 0))                        AS predicted,
           SUM(IFF(l.actual = c.REASON_CODE AND l.pred = c.REASON_CODE, 1, 0)) AS tp
    FROM       long l
    CROSS JOIN RAW.COMPLAINT_REASON_CODE c
    GROUP BY   l.approach, c.REASON_CODE
)
SELECT approach,
       SUM(support)                                                        AS complaints,
       SUM(tp)                                                             AS correct,
       ROUND(100.0 * SUM(tp) / SUM(support), 2)                            AS accuracy_pct,
       ROUND(AVG(2.0 * tp / NULLIF(predicted + support, 0)), 4)            AS macro_f1,
       ROUND(AVG(tp / NULLIF(support, 0)), 4)                              AS macro_recall
FROM   per_class
GROUP  BY approach
ORDER  BY approach;

-- Per class, side by side. Recall only -- precision differs between the two in
-- ways that are about how each spreads its errors, and recall is what tells
-- you whether a class is being found at all.
WITH both AS (
    SELECT t.REASON_CODE AS actual,
           m.PREDICTED_REASON_CODE AS tfidf,
           k.PREDICTED_REASON_CODE AS knn
    FROM      OPS.COMPLAINT_TRUTH          t
    JOIN      LAB.COMPLAINT_PREDICTION     m ON m.TICKET_ID = t.TICKET_ID
    JOIN      LAB.COMPLAINT_KNN_PREDICTION k ON k.TICKET_ID = t.TICKET_ID
    WHERE NOT m.WAS_TRAINED_ON
)
SELECT actual                                                    AS class,
       COUNT(*)                                                  AS support,
       SUM(IFF(tfidf = actual, 1, 0))                            AS tfidf_found,
       SUM(IFF(knn   = actual, 1, 0))                            AS knn_found,
       ROUND(AVG(IFF(tfidf = actual, 1.0, 0.0)), 3)              AS tfidf_recall,
       ROUND(AVG(IFF(knn   = actual, 1.0, 0.0)), 3)              AS knn_recall
FROM   both
GROUP  BY actual
ORDER  BY support DESC;

-- =============================================================================
-- STEP 2 — the same split by template coverage, for both.
--
-- If the collapse on unseen phrasings is a property of TF-IDF, approach B
-- should not share it. If it is a property of the corpus, B collapses too.
-- =============================================================================
WITH trained_pairs AS (
    SELECT DISTINCT t.REASON_CODE, t.TEMPLATE_INDEX
    FROM   OPS.COMPLAINT_TRUTH t
    JOIN   CORE.COMPLAINT      c ON c.TICKET_ID = t.TICKET_ID
    WHERE  c.IS_LABELLED
),
both AS (
    SELECT t.REASON_CODE                      AS actual,
           m.PREDICTED_REASON_CODE            AS tfidf,
           k.PREDICTED_REASON_CODE            AS knn,
           tp.REASON_CODE IS NOT NULL         AS template_was_seen
    FROM      OPS.COMPLAINT_TRUTH          t
    JOIN      LAB.COMPLAINT_PREDICTION     m  ON m.TICKET_ID = t.TICKET_ID
    JOIN      LAB.COMPLAINT_KNN_PREDICTION k  ON k.TICKET_ID = t.TICKET_ID
    LEFT JOIN trained_pairs                tp ON tp.REASON_CODE    = t.REASON_CODE
                                             AND tp.TEMPLATE_INDEX = t.TEMPLATE_INDEX
    WHERE NOT m.WAS_TRAINED_ON
)
SELECT IFF(template_was_seen, 'template seen in training',
                              'template never seen')             AS phrasing,
       COUNT(*)                                                  AS complaints,
       SUM(IFF(tfidf = actual, 1, 0))                            AS tfidf_correct,
       ROUND(100.0 * AVG(IFF(tfidf = actual, 1.0, 0.0)), 2)      AS tfidf_pct,
       SUM(IFF(knn = actual, 1, 0))                              AS knn_correct,
       ROUND(100.0 * AVG(IFF(knn = actual, 1.0, 0.0)), 2)        AS knn_pct
FROM   both
GROUP  BY template_was_seen
ORDER  BY template_was_seen DESC;

-- =============================================================================
-- STEP 3 — where they agree, and whether agreement is worth anything.
--
-- Two methods with nothing in common but the input. Agreement between them is
-- a confidence signal that costs nothing to compute and does not depend on
-- either model's own probability being calibrated.
-- =============================================================================
WITH both AS (
    SELECT t.REASON_CODE AS actual,
           m.PREDICTED_REASON_CODE AS tfidf,
           k.PREDICTED_REASON_CODE AS knn,
           m.CONFIDENCE
    FROM      OPS.COMPLAINT_TRUTH          t
    JOIN      LAB.COMPLAINT_PREDICTION     m ON m.TICKET_ID = t.TICKET_ID
    JOIN      LAB.COMPLAINT_KNN_PREDICTION k ON k.TICKET_ID = t.TICKET_ID
    WHERE NOT m.WAS_TRAINED_ON
)
SELECT IFF(tfidf = knn, 'the two agree', 'the two disagree')     AS verdict,
       COUNT(*)                                                  AS complaints,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)        AS pct_of_held_out,
       SUM(IFF(tfidf = actual, 1, 0))                            AS tfidf_right,
       SUM(IFF(knn   = actual, 1, 0))                            AS knn_right,
       ROUND(100.0 * AVG(IFF(tfidf = actual, 1.0, 0.0)), 1)      AS tfidf_pct,
       ROUND(AVG(CONFIDENCE), 3)                                 AS avg_tfidf_confidence
FROM   both
GROUP  BY verdict
ORDER  BY complaints DESC;

-- =============================================================================
-- STEP 4 — record approach B beside approach A.
-- =============================================================================
INSERT INTO OPS.MODEL_METRICS (TRAINED_AT, MODEL_NAME, MODEL_VERSION, SPLIT, METRIC, VALUE)
WITH held AS (
    SELECT t.REASON_CODE AS actual, k.PREDICTED_REASON_CODE AS pred
    FROM      OPS.COMPLAINT_TRUTH          t
    JOIN      LAB.COMPLAINT_KNN_PREDICTION k ON k.TICKET_ID = t.TICKET_ID
    JOIN      LAB.COMPLAINT_PREDICTION     m ON m.TICKET_ID = t.TICKET_ID
    WHERE NOT m.WAS_TRAINED_ON
),
per_class AS (
    SELECT c.REASON_CODE AS class,
           SUM(IFF(h.actual = c.REASON_CODE, 1, 0))   AS support,
           SUM(IFF(h.pred   = c.REASON_CODE, 1, 0))   AS predicted,
           SUM(IFF(h.actual = c.REASON_CODE AND h.pred = c.REASON_CODE, 1, 0)) AS tp
    FROM held h CROSS JOIN RAW.COMPLAINT_REASON_CODE c
    GROUP BY c.REASON_CODE
),
agg AS (
    SELECT AVG(2.0 * tp / NULLIF(predicted + support, 0)) AS macro_f1,
           AVG(tp / NULLIF(support, 0))                   AS macro_recall,
           SUM(tp) / SUM(support)                         AS accuracy,
           SUM(support)                                   AS n
    FROM per_class
)
SELECT SYSDATE(), 'COMPLAINT_KNN', 'V1', 'HELDOUT', METRIC, VALUE
FROM (
    SELECT 'macro_f1'     AS METRIC, macro_f1     AS VALUE FROM agg
    UNION ALL SELECT 'macro_recall', macro_recall            FROM agg
    UNION ALL SELECT 'accuracy',     accuracy                FROM agg
    UNION ALL SELECT 'n',            n                       FROM agg
);

SELECT MODEL_NAME, SPLIT,
       MAX(IFF(METRIC = 'n', VALUE, NULL))::INT                 AS n,
       ROUND(MAX(IFF(METRIC = 'accuracy', VALUE, NULL)), 4)     AS accuracy,
       ROUND(MAX(IFF(METRIC = 'macro_f1', VALUE, NULL)), 4)     AS macro_f1,
       ROUND(MAX(IFF(METRIC = 'macro_recall', VALUE, NULL)), 4) AS macro_recall
FROM   OPS.MODEL_METRICS
WHERE  MODEL_NAME IN ('COMPLAINT_REASON', 'COMPLAINT_KNN')
  AND  SPLIT = 'HELDOUT'
GROUP  BY MODEL_NAME, SPLIT
ORDER  BY MODEL_NAME;

-- =============================================================================
-- STEP 5 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
WITH both AS (
    SELECT t.REASON_CODE AS actual, m.PREDICTED_REASON_CODE AS tfidf,
           k.PREDICTED_REASON_CODE AS knn
    FROM      OPS.COMPLAINT_TRUTH          t
    JOIN      LAB.COMPLAINT_PREDICTION     m ON m.TICKET_ID = t.TICKET_ID
    JOIN      LAB.COMPLAINT_KNN_PREDICTION k ON k.TICKET_ID = t.TICKET_ID
    WHERE NOT m.WAS_TRAINED_ON
)
SELECT 'two_unrelated_lexical_methods_reach_the_same_ceiling', 'LAB.COMPLAINT_KNN_PREDICTION',
       ABS(AVG(IFF(tfidf = actual, 1.0, 0.0)) - AVG(IFF(knn = actual, 1.0, 0.0))) < 0.05
       AND COUNT(*) = 240,
       ROUND(ABS(AVG(IFF(tfidf = actual, 1.0, 0.0))
                 - AVG(IFF(knn = actual, 1.0, 0.0))) * 10000),
       'the two approaches land within 5 points of each other, gap in basis '
         || 'points -- the limit is the corpus, not the method',
       OBJECT_CONSTRUCT('tfidf', ROUND(AVG(IFF(tfidf = actual, 1.0, 0.0)), 4),
                        'knn',   ROUND(AVG(IFF(knn   = actual, 1.0, 0.0)), 4))
FROM both;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
WITH both AS (
    SELECT t.REASON_CODE AS actual, m.PREDICTED_REASON_CODE AS tfidf,
           k.PREDICTED_REASON_CODE AS knn
    FROM      OPS.COMPLAINT_TRUTH          t
    JOIN      LAB.COMPLAINT_PREDICTION     m ON m.TICKET_ID = t.TICKET_ID
    JOIN      LAB.COMPLAINT_KNN_PREDICTION k ON k.TICKET_ID = t.TICKET_ID
    WHERE NOT m.WAS_TRAINED_ON
)
SELECT 'agreement_between_the_two_predicts_correctness', 'LAB.COMPLAINT_KNN_PREDICTION',
       AVG(IFF(tfidf = knn, IFF(tfidf = actual, 1.0, 0.0), NULL))
         > AVG(IFF(tfidf = knn, NULL, IFF(tfidf = actual, 1.0, 0.0)))
       AND COUNT(*) = 240,
       ROUND(AVG(IFF(tfidf = knn, IFF(tfidf = actual, 1.0, 0.0), NULL)) * 10000),
       'accuracy where the two approaches agree exceeds accuracy where they '
         || 'do not, agreement accuracy in basis points',
       OBJECT_CONSTRUCT(
         'agree_n',    SUM(IFF(tfidf = knn, 1, 0)),
         'agree_acc',  ROUND(AVG(IFF(tfidf = knn, IFF(tfidf = actual, 1.0, 0.0), NULL)), 4),
         'differ_n',   SUM(IFF(tfidf = knn, 0, 1)),
         'differ_acc', ROUND(AVG(IFF(tfidf = knn, NULL, IFF(tfidf = actual, 1.0, 0.0))), 4))
FROM both;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET = 'LAB.COMPLAINT_KNN_PREDICTION'
ORDER  BY CHECK_TS DESC
LIMIT  3;

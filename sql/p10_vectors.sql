-- =============================================================================
-- PART 10 / STEP 4 — vectors, similarity, and a second classifier for free.
--
-- Snowflake has a native VECTOR type and VECTOR_COSINE_SIMILARITY. What it
-- does not have on this account is an embedding model, because Cortex is
-- unavailable (Finding 1). So the vectors are built here, by feature hashing
-- in a Python UDF.
--
-- THIS IS LEXICAL SIMILARITY, NOT SEMANTIC. Two complaints are close when they
-- share words, not when they mean the same thing. "The milk was warm" and "the
-- cold chain failed" are unrelated to this UDF. That limitation is the whole
-- reason the upgrade path matters -- staging all-MiniLM-L6-v2 at ~90 MB and
-- running it inside the UDF -- and it should be stated in any write-up rather
-- than left for a reader to discover.
--
-- The second use is the more interesting one. Nearest-neighbour over these
-- vectors is a complete classifier with no model artefact at all: no training,
-- no registry, no Python at inference. Scoring it on the same held-out 240
-- gives the project's stated "two ML approaches compared" on identical data.
--
-- PREDICTION, recorded before it runs: this will land within a point or two of
-- the TF-IDF model, near 85%, perfect on seen templates and near zero on
-- unseen. Both are bag-of-words methods over a corpus built from 30 sentence
-- skeletons. If two unrelated lexical methods hit the same ceiling, the
-- ceiling belongs to the corpus and the 60-label sample, not to either model.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p10:vectors';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — text to a 256-dimensional unit vector.
--
-- Signed feature hashing. Each token lands in one of 256 slots by hash, and
-- carries a sign taken from a different part of the same hash, so that
-- collisions cancel on average instead of accumulating. The vector is L2
-- normalised, which makes cosine similarity a plain dot product.
--
-- Returns ARRAY and is cast to VECTOR in SQL. A Python UDF returning
-- VECTOR(FLOAT, 256) directly may work; the ARRAY-to-VECTOR cast is the
-- documented path and this is not the place to find out.
-- =============================================================================
CREATE OR REPLACE FUNCTION LAB.TEXT_HASH_VECTOR(TXT STRING)
RETURNS ARRAY
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'vec'
AS
$$
import hashlib
import math
import re

DIM = 256
TOKEN = re.compile(r"[a-z]{2,}")


def vec(txt):
    if not txt:
        return [0.0] * DIM
    toks = TOKEN.findall(txt.lower())
    # Unigrams and bigrams, the same shape the TF-IDF model was given, so the
    # comparison between the two is about the method and not about the
    # tokenisation.
    grams = toks + ["%s_%s" % (toks[i], toks[i + 1]) for i in range(len(toks) - 1)]

    v = [0.0] * DIM
    for g in grams:
        h = int(hashlib.md5(g.encode("utf-8")).hexdigest()[:16], 16)
        v[h % DIM] += 1.0 if (h >> 32) & 1 else -1.0

    norm = math.sqrt(sum(x * x for x in v))
    if norm == 0.0:
        return v
    return [x / norm for x in v]
$$;

CREATE OR REPLACE TABLE LAB.COMPLAINT_VECTOR AS
SELECT TICKET_ID,
       REASON_CODE,
       IS_LABELLED,
       COMPLAINT_TEXT,
       LAB.TEXT_HASH_VECTOR(COMPLAINT_TEXT)::VECTOR(FLOAT, 256) AS EMBEDDING
FROM   CORE.COMPLAINT;

SELECT COUNT(*)                                        AS complaints,
       COUNT(EMBEDDING)                                AS with_vector,
       SUM(IFF(IS_LABELLED, 1, 0))                     AS labelled
FROM   LAB.COMPLAINT_VECTOR;

-- =============================================================================
-- STEP 2 — "complaints like this one".
--
-- The five nearest neighbours of one ticket. This is the query a support tool
-- would run when an agent opens a case: has this happened before, and what was
-- done about it.
-- =============================================================================
WITH anchor AS (
    SELECT TICKET_ID, REASON_CODE, COMPLAINT_TEXT, EMBEDDING
    FROM   LAB.COMPLAINT_VECTOR
    WHERE  IS_LABELLED
    ORDER  BY TICKET_ID
    LIMIT  1
)
SELECT a.TICKET_ID                                              AS anchor_ticket,
       a.REASON_CODE                                            AS anchor_code,
       n.TICKET_ID                                              AS neighbour,
       n.REASON_CODE                                            AS neighbour_code,
       ROUND(VECTOR_COSINE_SIMILARITY(a.EMBEDDING, n.EMBEDDING), 4) AS similarity,
       LEFT(n.COMPLAINT_TEXT, 90)                               AS neighbour_text
FROM   anchor a
JOIN   LAB.COMPLAINT_VECTOR n ON n.TICKET_ID <> a.TICKET_ID
ORDER  BY similarity DESC
LIMIT  5;

-- How separable are the classes in this space at all? If within-class pairs
-- are not measurably closer than between-class pairs, nearest neighbour has
-- nothing to work with and the next step is pointless.
SELECT IFF(a.REASON_CODE = b.REASON_CODE, 'same reason code',
                                          'different reason code')  AS pairing,
       COUNT(*)                                                     AS pairs,
       ROUND(AVG(VECTOR_COSINE_SIMILARITY(a.EMBEDDING, b.EMBEDDING)), 4) AS avg_similarity,
       ROUND(MAX(VECTOR_COSINE_SIMILARITY(a.EMBEDDING, b.EMBEDDING)), 4) AS max_similarity
FROM   LAB.COMPLAINT_VECTOR a
JOIN   LAB.COMPLAINT_VECTOR b ON b.TICKET_ID > a.TICKET_ID
WHERE  a.IS_LABELLED AND b.IS_LABELLED
GROUP  BY pairing
ORDER  BY pairing;

-- How much of this corpus is literally repeated once numbers are removed.
-- Every complaint carries a minute count, a rupee amount or a pack size drawn
-- at random, and none of it survives tokenisation, so documents built from one
-- template collapse onto each other. This number is the floor under every
-- accuracy figure in Part 10.
SELECT COUNT(*)                                                     AS complaints,
       SUM(IFF(top_sim >= 0.9999, 1, 0))                            AS with_an_identical_twin,
       ROUND(AVG(top_sim), 4)                                       AS avg_nearest,
       ROUND(MIN(top_sim), 4)                                       AS most_isolated
FROM (
    SELECT a.TICKET_ID,
           MAX(VECTOR_COSINE_SIMILARITY(a.EMBEDDING, b.EMBEDDING))  AS top_sim
    FROM   LAB.COMPLAINT_VECTOR a
    JOIN   LAB.COMPLAINT_VECTOR b ON b.TICKET_ID <> a.TICKET_ID
    GROUP  BY a.TICKET_ID
);

-- =============================================================================
-- STEP 3 — nearest neighbour as a classifier.
--
-- Every complaint takes the reason code of the most similar LABELLED complaint
-- other than itself. No training step, no model object, no Python at inference
-- -- one window function over a cosine similarity. The 60 labelled rows
-- exclude themselves from their own candidate set, so their prediction is
-- leave-one-out rather than a lookup of their own answer.
-- =============================================================================
CREATE OR REPLACE TABLE LAB.COMPLAINT_KNN_PREDICTION AS
SELECT c.TICKET_ID,
       l.REASON_CODE                                                AS PREDICTED_REASON_CODE,
       VECTOR_COSINE_SIMILARITY(c.EMBEDDING, l.EMBEDDING)           AS SIMILARITY,
       l.TICKET_ID                                                  AS NEIGHBOUR_TICKET,
       c.IS_LABELLED                                                AS WAS_TRAINED_ON,
       c.REASON_CODE                                                AS TRAIN_LABEL
FROM   LAB.COMPLAINT_VECTOR c
JOIN   LAB.COMPLAINT_VECTOR l
       ON l.IS_LABELLED
      AND l.TICKET_ID <> c.TICKET_ID
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY c.TICKET_ID
          ORDER BY VECTOR_COSINE_SIMILARITY(c.EMBEDDING, l.EMBEDDING) DESC,
                   l.TICKET_ID) = 1;

SELECT PREDICTED_REASON_CODE,
       COUNT(*)                                                     AS predicted,
       SUM(IFF(WAS_TRAINED_ON, 0, 1))                               AS among_the_240,
       ROUND(AVG(SIMILARITY), 3)                                    AS avg_similarity,
       ROUND(MIN(SIMILARITY), 3)                                    AS min_similarity
FROM   LAB.COMPLAINT_KNN_PREDICTION
GROUP  BY PREDICTED_REASON_CODE
ORDER  BY predicted DESC;

-- =============================================================================
-- STEP 4 — sentiment, by lexicon.
--
-- A scalar Python UDF, no model. Counting words from a fixed list is a weak
-- method and it is the honest one to reach for here: with 60 labels there is
-- nothing to train a sentiment model on, and every complaint is negative by
-- construction, so what this actually measures is INTENSITY rather than
-- polarity. Reported as such.
-- =============================================================================
CREATE OR REPLACE FUNCTION LAB.COMPLAINT_TONE(TXT STRING)
RETURNS OBJECT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'tone'
AS
$$
import re

STRONG = {"unacceptable", "disappointing", "rude", "threatened", "refused",
          "wasteful", "spoiled", "unusable", "damaged", "crushed", "torn",
          "warm", "leaked", "soaked", "browning", "limp", "never", "nobody",
          "twice", "duplicate", "wrong", "missing", "failed", "crashed"}
ESCALATION = {"refund", "photographed", "photographs", "statement", "again",
              "third", "second", "follow", "expect", "demand", "collection",
              "invoice"}
TOKEN = re.compile(r"[a-z]{2,}")


def tone(txt):
    if not txt:
        return {"intensity": 0, "escalation": 0, "words": 0, "band": "UNKNOWN"}
    toks = TOKEN.findall(txt.lower())
    strong = sum(1 for t in toks if t in STRONG)
    esc = sum(1 for t in toks if t in ESCALATION)
    score = strong + 2 * esc
    band = "HIGH" if score >= 6 else ("MEDIUM" if score >= 3 else "LOW")
    return {"intensity": strong, "escalation": esc, "words": len(toks),
            "score": score, "band": band}
$$;

SELECT t.TONE:band::STRING                                        AS band,
       COUNT(*)                                                   AS complaints,
       ROUND(AVG(t.TONE:score::FLOAT), 2)                         AS avg_score,
       ROUND(AVG(t.TONE:words::FLOAT), 1)                         AS avg_words
FROM  (SELECT LAB.COMPLAINT_TONE(COMPLAINT_TEXT) AS TONE FROM CORE.COMPLAINT) t
GROUP BY band
ORDER BY avg_score DESC;

-- Does tone track the reason code, on the 60 where the code is known? If the
-- bands are flat across codes the lexicon is measuring writing style rather
-- than anything operational, which is worth knowing before it is put in front
-- of anyone.
SELECT c.REASON_CODE,
       COUNT(*)                                                   AS labelled,
       ROUND(AVG(LAB.COMPLAINT_TONE(c.COMPLAINT_TEXT):score::FLOAT), 2) AS avg_score
FROM   CORE.COMPLAINT c
WHERE  c.IS_LABELLED
GROUP  BY c.REASON_CODE
ORDER  BY avg_score DESC;

-- =============================================================================
-- STEP 5 — checks. None of these can see the answer key either.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'every_complaint_has_a_unit_vector', 'LAB.COMPLAINT_VECTOR',
       (SELECT COUNT(*) FROM LAB.COMPLAINT_VECTOR)
         = (SELECT COUNT(*) FROM CORE.COMPLAINT)
       AND (SELECT COUNT(*) FROM LAB.COMPLAINT_VECTOR
             WHERE ABS(VECTOR_COSINE_SIMILARITY(EMBEDDING, EMBEDDING) - 1) > 0.001) = 0
       AND (SELECT COUNT(*) FROM LAB.COMPLAINT_VECTOR) > 0,
       (SELECT COUNT(*) FROM LAB.COMPLAINT_VECTOR),
       'one vector per complaint and every vector self-similar to 1 -- a zero '
         || 'vector would fail this rather than scoring perfectly',
       NULL;

-- The failure this guards against is a hash that puts everything in the same
-- place. Identical vectors are all similarity 1 and nearest neighbour becomes
-- alphabetical order.
-- This check originally also asserted that no held-out complaint matched a
-- training example at similarity 1. It failed, and the assertion was wrong
-- rather than the vectors. The tokeniser keeps [a-z]{2,} and drops digits, so
-- two complaints from one template differing only in a minute count or a rupee
-- amount ARE the same document. Ten of the 240 held-out rows have an identical
-- twin in the training set, and all ten carry the correct label. That is the
-- memorisation result at its most literal, so it is reported rather than
-- guarded against. What is worth asserting is that the hash is not degenerate:
-- a hash collapsing everything into one slot would put every pair at 1.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'vectors_separate_the_documents', 'LAB.COMPLAINT_VECTOR',
       (SELECT COUNT(DISTINCT ROUND(SIMILARITY, 4))
        FROM LAB.COMPLAINT_KNN_PREDICTION) > 100
       AND (SELECT AVG(SIMILARITY) FROM LAB.COMPLAINT_KNN_PREDICTION) < 0.95,
       (SELECT COUNT(DISTINCT ROUND(SIMILARITY, 4)) FROM LAB.COMPLAINT_KNN_PREDICTION),
       'more than 100 distinct nearest-neighbour similarities and a mean below '
         || '0.95 -- a degenerate hash would put every pair at 1',
       OBJECT_CONSTRUCT(
         'min',  (SELECT ROUND(MIN(SIMILARITY), 4) FROM LAB.COMPLAINT_KNN_PREDICTION),
         'mean', (SELECT ROUND(AVG(SIMILARITY), 4) FROM LAB.COMPLAINT_KNN_PREDICTION),
         'max',  (SELECT ROUND(MAX(SIMILARITY), 4) FROM LAB.COMPLAINT_KNN_PREDICTION),
         'held_out_with_an_identical_twin_in_training',
                 (SELECT COUNT(*) FROM LAB.COMPLAINT_KNN_PREDICTION
                   WHERE NOT WAS_TRAINED_ON AND SIMILARITY >= 0.9999));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'same_code_pairs_are_closer_than_different_code_pairs', 'LAB.COMPLAINT_VECTOR',
       (SELECT AVG(IFF(a.REASON_CODE = b.REASON_CODE,
                       VECTOR_COSINE_SIMILARITY(a.EMBEDDING, b.EMBEDDING), NULL))
             > AVG(IFF(a.REASON_CODE = b.REASON_CODE, NULL,
                       VECTOR_COSINE_SIMILARITY(a.EMBEDDING, b.EMBEDDING)))
        FROM LAB.COMPLAINT_VECTOR a JOIN LAB.COMPLAINT_VECTOR b ON b.TICKET_ID > a.TICKET_ID
        WHERE a.IS_LABELLED AND b.IS_LABELLED),
       (SELECT ROUND(AVG(IFF(a.REASON_CODE = b.REASON_CODE,
                             VECTOR_COSINE_SIMILARITY(a.EMBEDDING, b.EMBEDDING), NULL)) * 10000)
        FROM LAB.COMPLAINT_VECTOR a JOIN LAB.COMPLAINT_VECTOR b ON b.TICKET_ID > a.TICKET_ID
        WHERE a.IS_LABELLED AND b.IS_LABELLED),
       'complaints sharing a reason code sit closer together than ones that '
         || 'do not, same-code mean in basis points',
       NULL;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'knn_predicts_every_complaint_once', 'LAB.COMPLAINT_KNN_PREDICTION',
       (SELECT COUNT(*) FROM LAB.COMPLAINT_KNN_PREDICTION)
         = (SELECT COUNT(*) FROM CORE.COMPLAINT)
       AND (SELECT COUNT(DISTINCT TICKET_ID) FROM LAB.COMPLAINT_KNN_PREDICTION)
         = (SELECT COUNT(*) FROM LAB.COMPLAINT_KNN_PREDICTION)
       AND (SELECT COUNT(*) FROM LAB.COMPLAINT_KNN_PREDICTION
             WHERE NEIGHBOUR_TICKET = TICKET_ID) = 0,
       (SELECT COUNT(*) FROM LAB.COMPLAINT_KNN_PREDICTION),
       'one neighbour per complaint, no duplicates, and nothing is its own '
         || 'neighbour -- self-matching would make the 60 look perfect',
       NULL;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('LAB.COMPLAINT_VECTOR', 'LAB.COMPLAINT_KNN_PREDICTION')
ORDER  BY CHECK_TS DESC
LIMIT  4;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE    IF EXISTS QCOMMERCE.LAB.COMPLAINT_KNN_PREDICTION;
-- DROP TABLE    IF EXISTS QCOMMERCE.LAB.COMPLAINT_VECTOR;
-- DROP FUNCTION IF EXISTS QCOMMERCE.LAB.TEXT_HASH_VECTOR(STRING);
-- DROP FUNCTION IF EXISTS QCOMMERCE.LAB.COMPLAINT_TONE(STRING);

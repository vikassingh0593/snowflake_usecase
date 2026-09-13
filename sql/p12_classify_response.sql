-- =============================================================================
-- PART 12 / STEP 2 — act on what the classifier found, and on what it missed.
--
-- EXTRACT_SEMANTIC_CATEGORIES on MART.DIM_CUSTOMER disagreed with the hand
-- tagging in both directions, and both directions are the point.
--
--   FOUND, AND I HAD MISSED IT
--   HOME_LAT and HOME_LON came back QUASI_IDENTIFIER / LATITUDE and LONGITUDE
--   at HIGH confidence. A customer's home coordinates re-identify them more
--   sharply than their phone number does -- there is exactly one household at
--   six decimal places -- and they were sitting in the clear because I tagged
--   the columns that look like PII rather than the columns that behave like it.
--
--   MISSED, AND I HAD CAUGHT IT
--   PHONE got no recommendation at all. The values are +919895660819. The
--   pattern library evidently keys on North American formats, so it
--   under-detects on Indian data -- which is the general lesson: an automated
--   classifier's silence is not evidence of absence, it is evidence about the
--   classifier's training.
--
-- So: classification PROPOSES. It is a very good way to find what you forgot
-- and a very bad way to decide you are finished.
--
-- SYSTEM$CLASSIFY does not exist here -- "Unknown function", not a privilege
-- error. EXTRACT_SEMANTIC_CATEGORIES is where it went.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:classify_response';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — keep the classifier's output rather than reading it once.
--
-- A recommendation that exists only in a terminal cannot be diffed against the
-- next run, and the interesting question six months from now is what CHANGED:
-- a column that starts being classified as an identifier is a column whose
-- contents changed underneath someone.
-- =============================================================================
CREATE TABLE IF NOT EXISTS GOV.CLASSIFICATION_RESULT (
  CLASSIFIED_AT     TIMESTAMP_NTZ DEFAULT SYSDATE(),
  OBJECT_NAME       STRING,
  COLUMN_NAME       STRING,
  PRIVACY_CATEGORY  STRING,
  SEMANTIC_CATEGORY STRING,
  CONFIDENCE        STRING,
  COVERAGE          FLOAT,
  RAW               VARIANT
) COMMENT = 'what EXTRACT_SEMANTIC_CATEGORIES proposed, kept so it can be diffed';

-- ONE-TIME CLEANUP. The first version appended ten rows on every execution,
-- and five retries while debugging left five identical snapshots. They carry
-- no information -- a history of when a script was re-run is not a history of
-- when the data changed -- so all but the most recent go. Nothing is lost
-- because they are identical, and after the guarded insert below there will
-- never be two the same again.
DELETE FROM GOV.CLASSIFICATION_RESULT
WHERE  CLASSIFIED_AT < (SELECT MAX(CLASSIFIED_AT) FROM GOV.CLASSIFICATION_RESULT);

-- No PARSE_JSON. On this account EXTRACT_SEMANTIC_CATEGORIES already returns
-- an OBJECT, and wrapping it gives "Invalid argument types for function
-- 'PARSE_JSON': (OBJECT)". The first version assumed a JSON string because the
-- probe's output RENDERED as pretty-printed JSON, which is just how Snowflake
-- displays a VARIANT. FLATTEN takes the object directly.
--
-- The insert is GUARDED: a snapshot is written only when the classification
-- differs from the last one, or when there is no last one. The point of this
-- table is to diff runs against each other, and a row per script execution
-- buries the only signal that matters -- a column that starts being classified
-- as an identifier is a column whose contents changed underneath somebody --
-- under a pile of rows saying nothing happened.
INSERT INTO GOV.CLASSIFICATION_RESULT
  (OBJECT_NAME, COLUMN_NAME, PRIVACY_CATEGORY, SEMANTIC_CATEGORY,
   CONFIDENCE, COVERAGE, RAW)
WITH raw AS (
    SELECT EXTRACT_SEMANTIC_CATEGORIES('QCOMMERCE.MART.DIM_CUSTOMER') AS j
),
this_run AS (
    SELECT f.key                                            AS COLUMN_NAME,
           f.value:recommendation:privacy_category::STRING  AS PRIVACY_CATEGORY,
           f.value:recommendation:semantic_category::STRING AS SEMANTIC_CATEGORY,
           f.value:recommendation:confidence::STRING        AS CONFIDENCE,
           f.value:recommendation:coverage::FLOAT           AS COVERAGE,
           f.value                                          AS RAW
    FROM   raw, LATERAL FLATTEN(input => raw.j) f
),
previous AS (
    SELECT COLUMN_NAME, PRIVACY_CATEGORY, SEMANTIC_CATEGORY
    FROM   GOV.CLASSIFICATION_RESULT
    WHERE  CLASSIFIED_AT = (SELECT MAX(CLASSIFIED_AT) FROM GOV.CLASSIFICATION_RESULT)
),
-- Symmetric difference, so a column that GAINS a classification and one that
-- LOSES one both count as a change. A one-sided MINUS would miss the second,
-- and a column quietly ceasing to be classified is the more alarming of the two.
changed AS (
    SELECT COUNT(*) AS n FROM (
        (SELECT COLUMN_NAME, PRIVACY_CATEGORY, SEMANTIC_CATEGORY FROM this_run
         MINUS
         SELECT COLUMN_NAME, PRIVACY_CATEGORY, SEMANTIC_CATEGORY FROM previous)
        UNION ALL
        (SELECT COLUMN_NAME, PRIVACY_CATEGORY, SEMANTIC_CATEGORY FROM previous
         MINUS
         SELECT COLUMN_NAME, PRIVACY_CATEGORY, SEMANTIC_CATEGORY FROM this_run)
    )
)
SELECT 'QCOMMERCE.MART.DIM_CUSTOMER',
       COLUMN_NAME, PRIVACY_CATEGORY, SEMANTIC_CATEGORY, CONFIDENCE, COVERAGE, RAW
FROM   this_run
WHERE  (SELECT n FROM changed) > 0
   OR  (SELECT COUNT(*) FROM previous) = 0;

SELECT COLUMN_NAME,
       COALESCE(PRIVACY_CATEGORY, '— none proposed —')  AS privacy_category,
       COALESCE(SEMANTIC_CATEGORY, '—')                 AS semantic_category,
       COALESCE(CONFIDENCE, '—')                        AS confidence
FROM   GOV.CLASSIFICATION_RESULT
WHERE  CLASSIFIED_AT = (SELECT MAX(CLASSIFIED_AT) FROM GOV.CLASSIFICATION_RESULT)
ORDER  BY PRIVACY_CATEGORY NULLS LAST, COLUMN_NAME;

-- =============================================================================
-- STEP 2 — protect the coordinates.
--
-- Not by masking them to null, which would break the distance feature the SLA
-- model depends on, but by ROUNDING. Two decimal places is about a kilometre:
-- enough to tell which neighbourhood an order went to, not enough to tell
-- which building. The model reads MART through QC_ENGINEER and is unaffected.
--
-- This is the argument for masking policies over redaction. The policy can
-- return a USEFUL transformation of the value rather than a hole, and analysis
-- survives the protection.
-- =============================================================================
-- Created then altered, never replaced -- a policy attached to a column
-- cannot be replaced at all, which is what this file hit on its second run:
-- "Policy MASK_COORDINATE cannot be dropped/replaced as it is associated with
-- one or more entities." The placeholder body is NULL rather than a
-- pass-through, so the column is never attached to a policy that reveals it.
CREATE MASKING POLICY IF NOT EXISTS GOV.MASK_COORDINATE AS (v FLOAT)
RETURNS FLOAT -> NULL
COMMENT = 'about a kilometre of precision. Neighbourhood, not doorstep';

ALTER MASKING POLICY GOV.MASK_COORDINATE SET BODY ->
  CASE
    WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'QC_ADMIN', 'QC_ENGINEER') THEN v
    ELSE ROUND(v, 2)
  END;

-- A tag can carry one masking policy PER DATA TYPE, so GOV.PII could hold
-- MASK_NAME for strings and MASK_COORDINATE for floats, and the columns would
-- need no policy of their own. That is the more elegant arrangement.
--
-- An earlier version of this comment claimed the tag route was unusable
-- because ALTER TAG ... SET MASKING POLICY has no FORCE. That was wrong.
-- p12_policies.sql uses FORCE on the tag binding and it runs clean, so the
-- tag route is available and MASK_COORDINATE could be bound to GOV.PII
-- instead of to the columns.
--
-- It stays on the columns, and the reason is worth stating plainly: both work,
-- this one is verified on this account, and a change would buy elegance only.
-- The columns still carry the tag, so the inventory query below finds them
-- either way -- the tag carries the classification, the policy carries the
-- behaviour.
ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN HOME_LAT
  SET MASKING POLICY GOV.MASK_COORDINATE FORCE;
ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN HOME_LON
  SET MASKING POLICY GOV.MASK_COORDINATE FORCE;

ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN HOME_LAT SET TAG GOV.PII = 'LOCATION';
ALTER TABLE MART.DIM_CUSTOMER MODIFY COLUMN HOME_LON SET TAG GOV.PII = 'LOCATION';

-- =============================================================================
-- STEP 3 — look again, as both roles.
-- =============================================================================
SELECT 'ACCOUNTADMIN' AS as_role, CUSTOMER_ID, HOME_LAT, HOME_LON
FROM   MART.DIM_CUSTOMER ORDER BY CUSTOMER_ID LIMIT 3;

USE ROLE QC_ANALYST;
USE WAREHOUSE WH_APP_XS;

SELECT 'QC_ANALYST' AS as_role, CUSTOMER_ID, HOME_LAT, HOME_LON
FROM   QCOMMERCE.MART.DIM_CUSTOMER ORDER BY CUSTOMER_ID LIMIT 3;

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;

-- Everything the PII tag now reaches, in one query. This is the inventory a
-- column-by-column policy attachment can never produce.
-- SELECT *, deliberately. The first version named REF_ENTITY_NAME and
-- REF_COLUMN_NAME, borrowed from POLICY_REFERENCES, and this is a different
-- function with a different shape. Printing everything means the next person
-- reads the columns instead of guessing them, and the check below can be
-- checked against what actually came back.
SELECT *
FROM   TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
              'QCOMMERCE.MART.DIM_CUSTOMER', 'TABLE'))
ORDER  BY COLUMN_NAME;

-- =============================================================================
-- STEP 4 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'classifier_output_is_retained', 'GOV.CLASSIFICATION_RESULT',
       (SELECT COUNT(*) FROM GOV.CLASSIFICATION_RESULT
         WHERE CLASSIFIED_AT = (SELECT MAX(CLASSIFIED_AT) FROM GOV.CLASSIFICATION_RESULT)) = 10
       AND (SELECT COUNT(*) FROM GOV.CLASSIFICATION_RESULT
             WHERE PRIVACY_CATEGORY IS NOT NULL
               AND CLASSIFIED_AT = (SELECT MAX(CLASSIFIED_AT)
                                    FROM GOV.CLASSIFICATION_RESULT)) >= 4,
       (SELECT COUNT(*) FROM GOV.CLASSIFICATION_RESULT
         WHERE PRIVACY_CATEGORY IS NOT NULL
           AND CLASSIFIED_AT = (SELECT MAX(CLASSIFIED_AT)
                                FROM GOV.CLASSIFICATION_RESULT)),
       'all 10 columns in the latest snapshot, at least 4 carrying a proposal. '
         || 'Scoped to that snapshot: the first version counted every row ever '
         || 'written, so the observed number grew with each retry and described '
         || 'the script rather than the data',
       (SELECT OBJECT_AGG(COLUMN_NAME, SEMANTIC_CATEGORY::VARIANT)
        FROM GOV.CLASSIFICATION_RESULT
        WHERE SEMANTIC_CATEGORY IS NOT NULL
          AND CLASSIFIED_AT = (SELECT MAX(CLASSIFIED_AT) FROM GOV.CLASSIFICATION_RESULT));

-- The finding, as an assertion: every column the classifier called an
-- identifier or quasi-identifier is now protected. If a future run proposes a
-- new one, this goes red until somebody decides what to do about it.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
WITH proposed AS (
    SELECT COLUMN_NAME FROM GOV.CLASSIFICATION_RESULT
    WHERE  PRIVACY_CATEGORY IN ('IDENTIFIER', 'QUASI_IDENTIFIER')
      AND  CLASSIFIED_AT = (SELECT MAX(CLASSIFIED_AT) FROM GOV.CLASSIFICATION_RESULT)
),
protected AS (
    SELECT COLUMN_NAME
    FROM   TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
                  'QCOMMERCE.MART.DIM_CUSTOMER', 'TABLE'))
    UNION
    SELECT 'EMAIL' UNION SELECT 'PHONE'
)
SELECT 'every_proposed_identifier_is_protected', 'MART.DIM_CUSTOMER',
       (SELECT COUNT(*) FROM proposed WHERE COLUMN_NAME NOT IN (SELECT COLUMN_NAME FROM protected)) = 0
       AND (SELECT COUNT(*) FROM proposed) >= 4,
       (SELECT COUNT(*) FROM proposed WHERE COLUMN_NAME NOT IN (SELECT COLUMN_NAME FROM protected)),
       'no column the classifier flagged as an identifier is left unprotected. '
         || 'A future run proposing a new one turns this red, which is the '
         || 'intended alarm rather than a failure',
       -- OBJECT_CONSTRUCT, not OBJECT_AGG. OBJECT_AGG is itself an aggregate
       -- and ARRAY_AGG inside it is a second one, which Snowflake rejects.
       -- A single-key object needs no aggregation over keys in any case.
       (SELECT OBJECT_CONSTRUCT('unprotected', ARRAY_AGG(COLUMN_NAME))
        FROM proposed WHERE COLUMN_NAME NOT IN (SELECT COLUMN_NAME FROM protected));

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('GOV.CLASSIFICATION_RESULT', 'MART.DIM_CUSTOMER')
ORDER  BY CHECK_TS DESC
LIMIT  3;

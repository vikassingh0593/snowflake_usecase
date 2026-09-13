-- =============================================================================
-- PART 10 / STEP 1 — CORE.COMPLAINT
--
-- 300 complaint PDFs landed in RAW.COMPLAINT_DOC in Part 6, one row per file,
-- with the text already extracted by pypdf inside a Python UDF. What arrived
-- is the whole page: a title line, two header lines of structured fields, then
-- the complaint prose wrapped at 88 characters.
--
--   QuickCommerce - Customer Complaint
--
--   Ticket CMP-000001    Order 17788    Store DS006
--   Raised 2026-07-15T11:49:00Z    Channel: app    City: Faridabad
--
--   Hello, The packaging was torn on arrival and the Amul Taaza milk 1L
--   inside is damaged. Rider said it was already like that when he
--   collected it. I expect a refund.
--
-- This step splits the structured header from the prose, because a classifier
-- trained on the whole page learns the title line -- which is identical on all
-- 300 documents and carries nothing -- and, worse, learns store codes and
-- cities that happen to correlate with a label in 60 examples.
--
-- The line wrapping is undone deliberately. It is a property of how the PDF
-- was rendered at 88 characters, not of what the customer wrote, and leaving
-- it in produces tokens like "damaged.\nRider" that occur exactly once in the
-- corpus and never again.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p10:text_prep';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — look before parsing.
-- =============================================================================
SELECT TICKET_ID, BODY_CHARS, REPLACE(LEFT(BODY, 200), CHR(10), ' | ') AS SNIPPET
FROM   RAW.COMPLAINT_DOC
ORDER  BY TICKET_ID
LIMIT  3;

-- =============================================================================
-- STEP 2 — conform.
--
-- ORDER_ID carries a correction that should not be needed.
--
-- gen_complaints.py:38 says "N_ORDERS = 20_000 -- must match generate.py, so
-- order ids resolve". It does not. generate.py issues order ids from
-- range(900_000, 920_000); gen_complaints.py draws rng.randint(1, N_ORDERS),
-- which is 1..20,000. The two ranges do not overlap at all, so every complaint
-- in RAW references an order that does not exist.
--
-- The offset below recovers what the generator meant: randint(1, 20_000) is
-- uniform over 20,000 values and 899_999 + x maps it one-to-one onto the real
-- id space, preserving the distribution. Which specific order a complaint
-- points at was arbitrary to begin with.
--
-- Fixing the generator instead would change every complaint body that
-- interpolates an order id -- three of the ten reason codes do -- and require
-- all 300 PDFs to be regenerated and re-uploaded. It is left for a rebuild,
-- and the correction lives here, in one place, where it cannot be applied
-- twice.
-- =============================================================================
CREATE OR REPLACE TABLE CORE.COMPLAINT AS
WITH parsed AS (
    SELECT
        d.TICKET_ID,

        TRY_TO_NUMBER(REGEXP_SUBSTR(d.BODY, 'Order ([0-9]+)', 1, 1, 'e', 1))  AS RAW_ORDER_ID,
        REGEXP_SUBSTR(d.BODY, 'Store (DS[0-9]+)', 1, 1, 'e', 1)               AS STORE_CODE,
        TRY_TO_TIMESTAMP_NTZ(
            REGEXP_SUBSTR(d.BODY, 'Raised ([0-9-]+T[0-9:]+)Z', 1, 1, 'e', 1)) AS RAISED_TS,
        REGEXP_SUBSTR(d.BODY, 'Channel: ([a-z_]+)', 1, 1, 'e', 1)             AS CHANNEL,
        REGEXP_SUBSTR(d.BODY, 'City: ([A-Za-z]+)', 1, 1, 'e', 1)              AS CITY,

        -- Everything after the city, with the wrap undone. The 's' parameter
        -- lets . cross a newline; without it this returns the first line of
        -- the complaint and silently drops the rest, which would look like a
        -- short complaint rather than like a bug.
        REGEXP_REPLACE(
            REGEXP_SUBSTR(d.BODY, 'City: [A-Za-z]+[[:space:]]*(.*)$', 1, 1, 'se', 1),
            '[[:space:]]+', ' ')                                              AS COMPLAINT_TEXT,

        d.BODY_CHARS,
        d.FILE_MD5,
        d.RELATIVE_PATH,
        d.LOAD_TS
    FROM RAW.COMPLAINT_DOC d
)
SELECT
    p.TICKET_ID,
    899999 + p.RAW_ORDER_ID                                   AS ORDER_ID,
    p.RAW_ORDER_ID                                            AS SOURCE_ORDER_ID,
    p.STORE_CODE,
    p.RAISED_TS,
    p.CHANNEL,
    p.CITY,

    TRIM(p.COMPLAINT_TEXT)                                    AS COMPLAINT_TEXT,
    LENGTH(TRIM(p.COMPLAINT_TEXT))                            AS TEXT_CHARS,
    ARRAY_SIZE(SPLIT(TRIM(p.COMPLAINT_TEXT), ' '))            AS WORD_COUNT,

    -- 60 of 300 carry a hand label. The other 240 are NULL, and they stay NULL
    -- -- that is the problem Part 10 exists to solve, not a gap to fill in.
    l.REASON_CODE,
    l.REASON_CODE IS NOT NULL                                 AS IS_LABELLED,

    p.BODY_CHARS,
    p.FILE_MD5,
    p.RELATIVE_PATH,
    p.LOAD_TS
FROM      parsed p
LEFT JOIN RAW.COMPLAINT_LABEL l ON l.TICKET_ID = p.TICKET_ID;

-- =============================================================================
-- STEP 3 — what the corpus looks like.
-- =============================================================================
SELECT COUNT(*)                                   AS complaints,
       COUNT(REASON_CODE)                         AS labelled,
       COUNT(*) - COUNT(REASON_CODE)              AS unlabelled,
       MIN(TEXT_CHARS)                            AS min_chars,
       ROUND(AVG(TEXT_CHARS))                     AS avg_chars,
       MAX(TEXT_CHARS)                            AS max_chars,
       ROUND(AVG(WORD_COUNT), 1)                  AS avg_words,
       MIN(RAISED_TS)::DATE                       AS from_date,
       MAX(RAISED_TS)::DATE                       AS to_date
FROM   CORE.COMPLAINT;

-- The labelled distribution is the whole difficulty of this part. Three
-- classes have two examples each, and every class is generated from three
-- sentence templates, so those three train on at most two thirds of their own
-- vocabulary. Accuracy will not show this -- LATE_DELIVERY alone is a quarter
-- of the corpus -- which is why the evaluation reports macro-F1 first.
SELECT REASON_CODE,
       COUNT(*)                                                   AS labelled,
       ROUND(AVG(WORD_COUNT), 1)                                  AS avg_words,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)         AS pct_of_labelled
FROM   CORE.COMPLAINT
WHERE  IS_LABELLED
GROUP  BY REASON_CODE
ORDER  BY labelled DESC;

SELECT CHANNEL, CITY, COUNT(*) AS complaints
FROM   CORE.COMPLAINT
GROUP  BY CHANNEL, CITY
ORDER  BY complaints DESC
LIMIT  10;

SELECT TICKET_ID, REASON_CODE, LEFT(COMPLAINT_TEXT, 150) AS text
FROM   CORE.COMPLAINT
WHERE  IS_LABELLED
ORDER  BY TICKET_ID
LIMIT  5;

-- =============================================================================
-- STEP 4 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'every_document_conformed', 'CORE.COMPLAINT',
       (SELECT COUNT(*) FROM CORE.COMPLAINT)
         = (SELECT COUNT(*) FROM RAW.COMPLAINT_DOC)
       AND (SELECT COUNT(*) FROM CORE.COMPLAINT) > 0,
       (SELECT COUNT(*) FROM CORE.COMPLAINT),
       'one row per landed document, and not zero of them',
       OBJECT_CONSTRUCT('raw', (SELECT COUNT(*) FROM RAW.COMPLAINT_DOC));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'every_header_field_parsed', 'CORE.COMPLAINT',
       (SELECT COUNT(*) FROM CORE.COMPLAINT
         WHERE SOURCE_ORDER_ID IS NULL OR STORE_CODE IS NULL OR RAISED_TS IS NULL
            OR CHANNEL IS NULL OR CITY IS NULL) = 0
       AND (SELECT COUNT(*) FROM CORE.COMPLAINT) > 0,
       (SELECT COUNT(*) FROM CORE.COMPLAINT
         WHERE SOURCE_ORDER_ID IS NULL OR STORE_CODE IS NULL OR RAISED_TS IS NULL
            OR CHANNEL IS NULL OR CITY IS NULL),
       'no null in any of the five header fields',
       NULL;

-- The regex that extracts the prose must not leave any of the header in it,
-- and must not return only the first line. Both failures are invisible in a
-- row count and both would quietly change what the classifier is reading.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'prose_is_separated_from_header', 'CORE.COMPLAINT',
       (SELECT COUNT(*) FROM CORE.COMPLAINT
         WHERE COMPLAINT_TEXT ILIKE '%QuickCommerce%'
            OR COMPLAINT_TEXT ILIKE '%Ticket CMP-%'
            OR COMPLAINT_TEXT ILIKE '%Channel:%'
            OR COMPLAINT_TEXT ILIKE '%City:%'
            OR TEXT_CHARS < 40) = 0
       AND (SELECT COUNT(*) FROM CORE.COMPLAINT) > 0,
       (SELECT COUNT(*) FROM CORE.COMPLAINT
         WHERE COMPLAINT_TEXT ILIKE '%QuickCommerce%'
            OR COMPLAINT_TEXT ILIKE '%Ticket CMP-%'
            OR COMPLAINT_TEXT ILIKE '%Channel:%'
            OR COMPLAINT_TEXT ILIKE '%City:%'
            OR TEXT_CHARS < 40),
       'no header text survives into the prose, and nothing is under 40 chars',
       OBJECT_CONSTRUCT('shortest', (SELECT MIN(TEXT_CHARS) FROM CORE.COMPLAINT));

-- A classifier that can read its own answer out of the input is not a
-- classifier. The reason codes are upper-snake strings; none should appear.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'label_does_not_appear_in_the_text', 'CORE.COMPLAINT',
       (SELECT COUNT(*) FROM CORE.COMPLAINT c
         JOIN RAW.COMPLAINT_REASON_CODE r ON c.COMPLAINT_TEXT ILIKE '%' || r.REASON_CODE || '%') = 0
       AND (SELECT COUNT(*) FROM RAW.COMPLAINT_REASON_CODE) = 10,
       (SELECT COUNT(*) FROM CORE.COMPLAINT c
         JOIN RAW.COMPLAINT_REASON_CODE r ON c.COMPLAINT_TEXT ILIKE '%' || r.REASON_CODE || '%'),
       'no complaint contains its own reason code as a string, and there are '
         || '10 codes to check against',
       NULL;

-- The offset in STEP 2 either fixes the order reference or it does not, and a
-- count of resolved ids is the only way to tell.
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'order_reference_resolves_after_offset', 'CORE.COMPLAINT',
       (SELECT COUNT(*) FROM CORE.COMPLAINT c
         JOIN MART.FCT_ORDER o ON o.ORDER_ID = c.ORDER_ID)
         = (SELECT COUNT(*) FROM CORE.COMPLAINT)
       AND (SELECT COUNT(*) FROM CORE.COMPLAINT) > 0,
       (SELECT COUNT(*) FROM CORE.COMPLAINT c
         JOIN MART.FCT_ORDER o ON o.ORDER_ID = c.ORDER_ID),
       'all 300 complaints point at a real order once 899,999 is added',
       OBJECT_CONSTRUCT(
         'unresolved_without_offset',
           (SELECT COUNT(*) FROM CORE.COMPLAINT c
             LEFT JOIN MART.FCT_ORDER o ON o.ORDER_ID = c.SOURCE_ORDER_ID
             WHERE o.ORDER_ID IS NULL));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'every_class_has_at_least_one_label', 'CORE.COMPLAINT',
       (SELECT COUNT(DISTINCT REASON_CODE) FROM CORE.COMPLAINT WHERE IS_LABELLED) = 10
       AND (SELECT COUNT(*) FROM CORE.COMPLAINT WHERE IS_LABELLED) = 60,
       (SELECT COUNT(DISTINCT REASON_CODE) FROM CORE.COMPLAINT WHERE IS_LABELLED),
       'all 10 reason codes appear among the 60 labels -- a class with none '
         || 'can never be predicted',
       (SELECT OBJECT_AGG(REASON_CODE, n::VARIANT)
        FROM (SELECT REASON_CODE, COUNT(*) AS n FROM CORE.COMPLAINT
              WHERE IS_LABELLED GROUP BY REASON_CODE));

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET = 'CORE.COMPLAINT'
ORDER  BY CHECK_TS DESC
LIMIT  6;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE IF EXISTS QCOMMERCE.CORE.COMPLAINT;

-- =============================================================================
-- sql/p6_directory_docs.sql — mechanism 10.
--
--   Directory table over docs/complaints/, a stream on it, and PDF text
--   extracted by pypdf inside a Python UDF.
--
-- This is the mechanism Cortex's absence changed most. SNOWFLAKE.CORTEX.
-- PARSE_DOCUMENT is one function call and is blocked on this account, so the
-- reader has to be built: SnowflakeFile to open the blob, pypdf to decode it.
-- More code, and the version of pypdf is pinned by us rather than by Snowflake.
--
-- PREREQUISITE — Anaconda terms. pypdf is a third-party package. Until an
-- ORGADMIN accepts the Anaconda Terms of Service in Snowsight (Admin ->
-- Billing & Terms -> Anaconda -> Enable), CREATE FUNCTION with PACKAGES =
-- ('pypdf') fails. STEP 0 below tells you which case you are in before you
-- spend anything.
--
-- COST: resumes WH_TRANSFORM_XS. 300 files, ~320 KB. A Python UDF pays a cold
-- start of roughly 5-10 s on first call and is fast after. Estimate 0.02-0.04
-- credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p06:directory_docs';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 0 — is pypdf reachable at all?
--
-- Zero rows back means the Anaconda terms have not been accepted. Stop here
-- and accept them; everything below this point depends on it.
-- =============================================================================
SELECT PACKAGE_NAME, RUNTIME_VERSION, MAX(VERSION) AS LATEST
FROM   INFORMATION_SCHEMA.PACKAGES
WHERE  LANGUAGE = 'python'
  AND  PACKAGE_NAME IN ('pypdf', 'snowflake-snowpark-python')
GROUP  BY PACKAGE_NAME, RUNTIME_VERSION
ORDER  BY PACKAGE_NAME, RUNTIME_VERSION;

-- =============================================================================
-- STEP 1 — register the files.
--
-- A directory table is metadata, not a listing: it does not notice a blob until
-- ALTER STAGE ... REFRESH reconciles it against the container. REFRESH is
-- idempotent -- a file already registered is not registered again -- which is
-- exactly why it cannot be used to replay a load.
-- =============================================================================
SELECT COUNT(*) AS files_before_refresh FROM DIRECTORY(@LAND.STG_DOCS);

ALTER STAGE LAND.STG_DOCS REFRESH;

SELECT COUNT(*) AS files_after_refresh FROM DIRECTORY(@LAND.STG_DOCS);

-- What the directory table actually holds. Note MD5 and SIZE: content
-- addressing for free, which is how a replaced file is told from a new one.
SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED, MD5
FROM   DIRECTORY(@LAND.STG_DOCS)
ORDER  BY RELATIVE_PATH
LIMIT  5;

-- =============================================================================
-- STEP 2 — the reader.
--
-- SnowflakeFile is the only supported way to read a stage file from inside a
-- UDF, and it requires a SCOPED file URL -- BUILD_SCOPED_FILE_URL issues one
-- that is valid for 24 hours and carries the caller's privileges. A plain
-- FILE_URL from the directory table will not open here; that is deliberate, so
-- a URL cannot be handed to someone who has no rights to the stage.
--
-- RUNTIME_VERSION 3.11 rather than 3.12: 3.12 support for Python UDFs is
-- UNVERIFIED on this account version. Raise it once STEP 0 shows a 3.12 row.
-- =============================================================================
CREATE OR REPLACE FUNCTION RAW.PDF_TEXT(SCOPED_URL STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdf')
HANDLER = 'extract'
COMMENT = 'mechanism 10 - PDF to text, standing in for CORTEX.PARSE_DOCUMENT'
AS
$$
import io
from pypdf import PdfReader
from snowflake.snowpark.files import SnowflakeFile


def extract(scoped_url: str) -> str:
    # A corrupt or password-protected file must not fail the whole load.
    # Returning the error as text keeps the row, and the row is how you find it.
    try:
        with SnowflakeFile.open(scoped_url, "rb") as f:
            reader = PdfReader(io.BytesIO(f.read()))
            pages = [(p.extract_text() or "").strip() for p in reader.pages]
        return "\n".join(p for p in pages if p)
    except Exception as exc:
        return f"__EXTRACT_FAILED__ {type(exc).__name__}: {exc}"
$$;

-- One file first. A UDF that is wrong is cheaper to find out about now.
SELECT RELATIVE_PATH,
       RAW.PDF_TEXT(BUILD_SCOPED_FILE_URL(@LAND.STG_DOCS, RELATIVE_PATH)) AS BODY
FROM   DIRECTORY(@LAND.STG_DOCS)
ORDER  BY RELATIVE_PATH
LIMIT  1;

-- =============================================================================
-- STEP 3 — backfill from the directory table, incrementally.
--
-- THE CORRECTION. This originally read from a stream, which worked exactly once
-- and then silently loaded nothing. A stream captures changes from the moment
-- it is created; on a stage whose files are already registered, a fresh stream
-- is empty and REFRESH has nothing left to announce. A stream can therefore
-- never be the backfill -- it is only ever the delta.
--
-- The anti-join on (RELATIVE_PATH, MD5) is what makes this re-runnable. MD5
-- rather than path alone, so a file the partner REPLACES is reprocessed while
-- an unchanged one is skipped. That is the content addressing the directory
-- table hands over for nothing.
--
-- FILE_MODIFIED is TIMESTAMP_TZ, not TIMESTAMP_LTZ. DIRECTORY() returns
-- LAST_MODIFIED as TIMESTAMP_TZ(3) and Snowflake will not implicitly convert
-- between the two on insert -- it raises "Expression type does not match column
-- data type" and the whole statement fails. Matching the source type is also
-- the right call rather than casting: that timestamp is Azure's, carrying the
-- offset the blob was written with, and RAW holds what arrived. LOAD_TS stays
-- LTZ because that one is our clock.
--
-- IF NOT EXISTS, not OR REPLACE: the table is additive across runs. The cost is
-- that a column-type change needs an explicit drop first:
--   DROP TABLE IF EXISTS QCOMMERCE.RAW.COMPLAINT_DOC;
-- =============================================================================
CREATE TABLE IF NOT EXISTS RAW.COMPLAINT_DOC (
  TICKET_ID       STRING,
  RELATIVE_PATH   STRING,
  FILE_SIZE       NUMBER,
  FILE_MD5        STRING,
  FILE_MODIFIED   TIMESTAMP_TZ,
  BODY            STRING,
  BODY_CHARS      NUMBER,
  LOAD_TS         TIMESTAMP_LTZ
);

INSERT INTO RAW.COMPLAINT_DOC
SELECT REGEXP_SUBSTR(d.RELATIVE_PATH, 'CMP-[0-9]+')                       AS TICKET_ID,
       d.RELATIVE_PATH,
       d.SIZE                                                             AS FILE_SIZE,
       d.MD5                                                              AS FILE_MD5,
       d.LAST_MODIFIED                                                    AS FILE_MODIFIED,
       RAW.PDF_TEXT(BUILD_SCOPED_FILE_URL(@LAND.STG_DOCS, d.RELATIVE_PATH)) AS BODY,
       LENGTH(BODY)                                                       AS BODY_CHARS,
       CURRENT_TIMESTAMP()                                                AS LOAD_TS
FROM   DIRECTORY(@LAND.STG_DOCS) d
WHERE  d.RELATIVE_PATH ILIKE 'complaints/%.pdf'
  AND  NOT EXISTS (SELECT 1
                   FROM   RAW.COMPLAINT_DOC c
                   WHERE  c.RELATIVE_PATH = d.RELATIVE_PATH
                     AND  c.FILE_MD5 = d.MD5);

-- =============================================================================
-- STEP 3b — the stream, for what arrives NEXT.
--
-- Fourth of the five stream types, and now pointed at the job it can actually
-- do. IF NOT EXISTS rather than OR REPLACE: replacing a stream resets its
-- offset, which is precisely how the pending 300 files were lost the first time.
--
-- Zero rows here is the correct answer right after a backfill. To see it work:
--   upload one more PDF to docs/complaints/, ALTER STAGE ... REFRESH, and this
--   returns exactly that one file. Re-running STEP 3 then loads only it, since
--   the anti-join skips the 300 already present.
-- =============================================================================
CREATE STREAM IF NOT EXISTS RAW.STR_DOCS_NEWFILES ON STAGE LAND.STG_DOCS;

SELECT COUNT(*) AS files_awaiting_processing FROM RAW.STR_DOCS_NEWFILES;

-- =============================================================================
-- STEP 4 — verify. Counts, not status fields.
-- =============================================================================
SELECT COUNT(*)                              AS docs,
       COUNT(DISTINCT TICKET_ID)             AS tickets,
       SUM(IFF(BODY LIKE '__EXTRACT_FAILED__%', 1, 0)) AS failed,
       MIN(BODY_CHARS)                       AS min_chars,
       ROUND(AVG(BODY_CHARS))                AS avg_chars,
       MAX(BODY_CHARS)                       AS max_chars
FROM   RAW.COMPLAINT_DOC;

-- Every extraction should carry the header line; anything that does not is a
-- reader problem, not a data problem. Asserted as a proportion, not a count. "0 rows missing the header" is also
-- what an EMPTY table returns -- the same false green that has been wrong every
-- time in this project. Comparing against the row count cannot be fooled that
-- way.
SELECT COUNT(*)                                                        AS docs,
       SUM(IFF(BODY LIKE '%QuickCommerce - Customer Complaint%', 1, 0)) AS with_header,
       IFF(COUNT(*) > 0
           AND COUNT(*) = SUM(IFF(BODY LIKE '%QuickCommerce - Customer Complaint%', 1, 0)),
           'OK', 'CHECK ME')                                            AS verdict
FROM   RAW.COMPLAINT_DOC;

-- SNIPPET, not SAMPLE. SAMPLE is reserved -- it is the table-sampling clause.
-- Third reserved-word collision in this project after `rows` and `check`.
SELECT TICKET_ID, BODY_CHARS, LEFT(BODY, 220) AS SNIPPET
FROM   RAW.COMPLAINT_DOC
ORDER  BY TICKET_ID
LIMIT  3;

-- Free text with a numeric id in it. Part 10 pulls that out with a regex UDF,
-- because a regex is the right tool for an id and a language model is not.
SELECT COUNT(*) AS bodies_naming_an_order
FROM   RAW.COMPLAINT_DOC
WHERE  REGEXP_LIKE(BODY, '.*Order [0-9]+.*');

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE  IF EXISTS QCOMMERCE.RAW.COMPLAINT_DOC;
-- DROP STREAM IF EXISTS QCOMMERCE.RAW.STR_DOCS_NEWFILES;
-- DROP FUNCTION IF EXISTS QCOMMERCE.RAW.PDF_TEXT(STRING);

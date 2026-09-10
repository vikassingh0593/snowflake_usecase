-- =============================================================================
-- sql/p4_copy_parquet.sql — mechanisms 6 and 7, plus VALIDATE and COPY_HISTORY.
--
--   6  Bulk COPY from the Azure stage: INFER_SCHEMA, CREATE TABLE USING
--      TEMPLATE, MATCH_BY_COLUMN_NAME, ON_ERROR, VALIDATION_MODE
--   7  Schema evolution: a v2 file gains coupon_code mid-load
--
-- The backfill is built and unloaded BY Snowflake rather than generated
-- locally. Two reasons: GENERATOR produces 20k rows in seconds with no Python,
-- no pyarrow and no upload step, and the round trip out to Parquet and back is
-- itself the demonstration -- unload and bulk load are the same file format
-- seen from both ends.
--
-- COST: resumes WH_TRANSFORM_XS. Generation, two unloads and three loads over
-- ~20k rows. Estimate 0.03-0.05 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p04:copy_parquet';
USE DATABASE QCOMMERCE;

-- -----------------------------------------------------------------------------
-- 0. Somewhere to write.
--
-- landing/, external/ and docs/ are granted Storage Blob Data READER to the
-- Snowflake principal: it reads them and never writes them, which is right for
-- a landing zone and an inbound partner drop. archive/ is the one container
-- with CONTRIBUTOR, because Iceberg writes there. The backfill therefore lives
-- under archive/backfill/ rather than widening a read-only grant for test data.
--
-- SET replaces the whole list, so all four locations are restated.
-- -----------------------------------------------------------------------------
ALTER STORAGE INTEGRATION SI_QC_AZURE SET STORAGE_ALLOWED_LOCATIONS = (
  'azure://snowflakeqcpoc25056.blob.core.windows.net/landing/',
  'azure://snowflakeqcpoc25056.blob.core.windows.net/external/',
  'azure://snowflakeqcpoc25056.blob.core.windows.net/docs/',
  'azure://snowflakeqcpoc25056.blob.core.windows.net/archive/'
);

CREATE OR REPLACE STAGE LAND.STG_BACKFILL
  STORAGE_INTEGRATION = SI_QC_AZURE
  URL = 'azure://snowflakeqcpoc25056.blob.core.windows.net/archive/backfill/'
  FILE_FORMAT = LAND.FF_PARQUET
  COMMENT = 'Parquet order backfill, written and read by Snowflake';

-- -----------------------------------------------------------------------------
-- 1. Build the backfill in Snowflake. No producer, no upload.
--
-- GENERATOR with SEQ4, UNIFORM and NORMAL makes 20k plausible orders in
-- seconds. Money stays integer paise.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE RAW.TMP_BACKFILL AS
SELECT
  800000 + SEQ4()                                           AS order_id,
  UNIFORM(1, 500,  RANDOM())                                AS customer_id,
  UNIFORM(1, 8,    RANDOM())                                AS store_id,
  UNIFORM(1, 60,   RANDOM())                                AS rider_id,
  DATEADD(second, -UNIFORM(0, 5184000, RANDOM()), CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
                                                            AS placed_ts,
  ARRAY_CONSTRUCT('DELIVERED','DELIVERED','DELIVERED','CANCELLED')
    [UNIFORM(0, 3, RANDOM())]::STRING                       AS status,
  GREATEST(1, ABS(NORMAL(3, 1.5, RANDOM()))::INT)           AS item_count,
  GREATEST(4250, ABS(NORMAL(46000, 25000, RANDOM()))::INT)  AS order_total_paise,
  ARRAY_CONSTRUCT('QC10','FIRST50','WEEKEND20',NULL)
    [UNIFORM(0, 3, RANDOM())]::STRING                       AS coupon_code
FROM TABLE(GENERATOR(ROWCOUNT => 20000));

-- v1: the historical extract, WITHOUT coupon_code.
COPY INTO @LAND.STG_BACKFILL/v1/
FROM (SELECT order_id, customer_id, store_id, rider_id, placed_ts,
             status, item_count, order_total_paise
      FROM RAW.TMP_BACKFILL)
FILE_FORMAT = (TYPE = PARQUET)
HEADER = TRUE
OVERWRITE = TRUE;

-- v2: the same extract after someone added a column upstream.
COPY INTO @LAND.STG_BACKFILL/v2/
FROM (SELECT order_id, customer_id, store_id, rider_id, placed_ts,
             status, item_count, order_total_paise, coupon_code
      FROM RAW.TMP_BACKFILL)
FILE_FORMAT = (TYPE = PARQUET)
HEADER = TRUE
OVERWRITE = TRUE;

LIST @LAND.STG_BACKFILL;

-- -----------------------------------------------------------------------------
-- 2. MECHANISM 6 — INFER_SCHEMA and CREATE TABLE USING TEMPLATE.
--
-- The table is never hand-written. Snowflake reads the Parquet footer and
-- declares the columns, which is the point: a backfill whose shape you did not
-- author is exactly when guessing the DDL goes wrong.
-- -----------------------------------------------------------------------------
SELECT COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION => '@LAND.STG_BACKFILL/v1/',
  FILE_FORMAT => 'LAND.FF_PARQUET'
))
ORDER BY COLUMN_NAME;

CREATE OR REPLACE TABLE RAW.ORDER_BACKFILL
USING TEMPLATE (
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
  FROM TABLE(INFER_SCHEMA(
    LOCATION => '@LAND.STG_BACKFILL/v1/',
    FILE_FORMAT => 'LAND.FF_PARQUET'
  ))
);

-- Look before loading. VALIDATION_MODE cannot be used here: Snowflake counts
-- MATCH_BY_COLUMN_NAME as a transform and rejects the combination outright.
-- Querying the stage does the same job for Parquet -- and VALIDATION_MODE gets
-- its proper outing in section 5, on the malformed CSV, which is the case it
-- exists for.
SELECT $1 AS parquet_row
FROM @LAND.STG_BACKFILL/v1/ (FILE_FORMAT => 'LAND.FF_PARQUET')
LIMIT 5;

-- The real load. MATCH_BY_COLUMN_NAME is what makes column ORDER irrelevant.
COPY INTO RAW.ORDER_BACKFILL
FROM @LAND.STG_BACKFILL/v1/
FILE_FORMAT = (FORMAT_NAME = LAND.FF_PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = ABORT_STATEMENT;

SELECT COUNT(*) AS v1_rows FROM RAW.ORDER_BACKFILL;
DESC TABLE RAW.ORDER_BACKFILL;   -- no coupon_code yet

-- -----------------------------------------------------------------------------
-- 3. MECHANISM 7 — schema evolution.
--
-- v2 carries a column the table does not have. Without evolution this fails.
-- With it, Snowflake adds coupon_code and loads. Deliberate, not accidental:
-- the table records the change and DESC shows which load introduced it.
-- -----------------------------------------------------------------------------
ALTER TABLE RAW.ORDER_BACKFILL SET ENABLE_SCHEMA_EVOLUTION = TRUE;

COPY INTO RAW.ORDER_BACKFILL
FROM @LAND.STG_BACKFILL/v2/
FILE_FORMAT = (FORMAT_NAME = LAND.FF_PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = ABORT_STATEMENT;

DESC TABLE RAW.ORDER_BACKFILL;   -- coupon_code now present
SELECT COUNT(*) AS total_rows,
       COUNT(COUPON_CODE) AS rows_with_coupon_column
FROM RAW.ORDER_BACKFILL;

-- -----------------------------------------------------------------------------
-- 4. COPY_HISTORY — what actually happened, per file.
-- -----------------------------------------------------------------------------
SELECT FILE_NAME, ROW_COUNT, ROW_PARSED, ERROR_COUNT, STATUS, LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'QCOMMERCE.RAW.ORDER_BACKFILL',
  START_TIME => DATEADD(hour, -2, CURRENT_TIMESTAMP())))
ORDER BY LAST_LOAD_TIME;

-- -----------------------------------------------------------------------------
-- 5. A deliberately bad file, then VALIDATE().
--
-- Every load so far succeeded, which proves nothing about what happens when one
-- does not. This writes a CSV with three broken rows among the good ones:
-- a non-numeric order_id, a missing column and an oversized value.
--
-- ON_ERROR = CONTINUE loads what it can and keeps going. VALIDATE() then
-- reports exactly which rows were rejected and why -- after the fact, from the
-- load's own history, without re-reading the file.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE STAGE LAND.STG_BADFILE
  STORAGE_INTEGRATION = SI_QC_AZURE
  URL = 'azure://snowflakeqcpoc25056.blob.core.windows.net/archive/badfile/'
  COMMENT = 'deliberate bad-file test';

-- Good rows and bad rows in one file, written as raw text so the errors survive.
COPY INTO @LAND.STG_BADFILE/orders_bad/
FROM (
  SELECT order_id::STRING || ',' || customer_id::STRING || ',' ||
         store_id::STRING || ',' || order_total_paise::STRING AS line
  FROM   RAW.TMP_BACKFILL SAMPLE (200 ROWS)
  UNION ALL SELECT 'NOT_A_NUMBER,42,3,50000'      -- order_id is not numeric
  UNION ALL SELECT '999001,42,3'                   -- one column short
  UNION ALL SELECT '999002,42,3,NOT_A_NUMBER'      -- total is not numeric
)
-- The rows are pre-formatted CSV text in ONE column, so the unload must not
-- treat the embedded commas as anything. Left at defaults, CSV unload quotes a
-- field containing the delimiter -- every line becomes "800000,42,3,50000",
-- one field instead of four, and the reload rejects all 200 good rows for
-- column count rather than the 3 intended ones.
FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE
               FIELD_OPTIONALLY_ENCLOSED_BY = NONE
               ESCAPE_UNENCLOSED_FIELD = NONE)
SINGLE = TRUE
OVERWRITE = TRUE;

CREATE OR REPLACE TABLE RAW.ORDER_BADFILE_TEST (
  ORDER_ID          NUMBER,
  CUSTOMER_ID       NUMBER,
  STORE_ID          NUMBER,
  ORDER_TOTAL_PAISE NUMBER
);

-- Dry run. No transform here, so VALIDATION_MODE works: it reports the errors
-- it WOULD hit and writes nothing.
COPY INTO RAW.ORDER_BADFILE_TEST
FROM @LAND.STG_BADFILE/orders_bad/
FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE FIELD_DELIMITER = ',')
VALIDATION_MODE = RETURN_ERRORS;

-- Now load for real, skipping the bad rows rather than aborting.
COPY INTO RAW.ORDER_BADFILE_TEST
FROM @LAND.STG_BADFILE/orders_bad/
FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE FIELD_DELIMITER = ',')
ON_ERROR = CONTINUE;

SELECT COUNT(*) AS good_rows_loaded FROM RAW.ORDER_BADFILE_TEST;

-- VALIDATE() reads the load history of the statement that just ran. This is
-- the post-mortem: which rows failed, in which file, at which byte offset.
--
-- JOB_ID => '_last' means the last COPY IN THIS SESSION. Run it in a separate
-- invocation and it fails with "We couldn't find a copy for this table which
-- occurred during this session" - the COPY and the VALIDATE have to share a
-- session, or you pass the COPY's query_id explicitly:
--
--   SELECT QUERY_ID FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
--   WHERE QUERY_TEXT ILIKE 'COPY INTO RAW.ORDER_BADFILE_TEST%'
--   ORDER BY START_TIME DESC LIMIT 1;
SELECT ERROR, LINE, CHARACTER, REJECTED_RECORD
FROM TABLE(VALIDATE(RAW.ORDER_BADFILE_TEST, JOB_ID => '_last'));

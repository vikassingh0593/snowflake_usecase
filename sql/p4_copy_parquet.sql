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

-- Dry run first. VALIDATION_MODE parses the files and reports what WOULD fail
-- without writing a row -- the cheap way to find out a backfill is malformed.
COPY INTO RAW.ORDER_BACKFILL
FROM @LAND.STG_BACKFILL/v1/
FILE_FORMAT = (FORMAT_NAME = LAND.FF_PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
VALIDATION_MODE = RETURN_10_ROWS;

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

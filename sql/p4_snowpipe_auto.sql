-- =============================================================================
-- sql/p4_snowpipe_auto.sql — mechanism 4: Snowpipe auto-ingest via Event Grid.
--
-- Files land in landing/clickstream/, Azure Event Grid raises a BlobCreated
-- notification onto snowpipe-queue, and the pipe consumes it. Nothing polls a
-- schedule and nothing calls an API: the storage account tells Snowflake.
--
-- Cost: serverless. No warehouse is resumed by the pipe, and RM_POC cannot see
-- a single credit of it - which is what the account budget is for.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p04:snowpipe_auto';
USE DATABASE QCOMMERCE;

-- -----------------------------------------------------------------------------
-- Target. Every RAW table carries its file provenance: which file a row came
-- from, which line of it, and when that file was last modified. That is what
-- makes a bad load reversible by deleting one filename instead of reloading
-- everything.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS RAW.CLICKSTREAM_AUTO (
  V             VARIANT,
  SRC_FILE      STRING,
  SRC_ROW       NUMBER,
  SRC_MODIFIED  TIMESTAMP_NTZ,
  LOAD_TS       TIMESTAMP_NTZ DEFAULT SYSDATE()
) COMMENT = 'mechanism 4: Snowpipe auto-ingest from Azure via Event Grid';

-- -----------------------------------------------------------------------------
-- The pipe. AUTO_INGEST = TRUE plus the notification integration is the whole
-- mechanism; the COPY inside it is ordinary.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PIPE LAND.PIPE_CLICKSTREAM_AUTO
  AUTO_INGEST = TRUE
  INTEGRATION = 'NI_QC_SNOWPIPE'
  COMMENT = 'clickstream NDJSON.gz, landing/clickstream/'
AS
COPY INTO RAW.CLICKSTREAM_AUTO (V, SRC_FILE, SRC_ROW, SRC_MODIFIED)
FROM (
  SELECT $1,
         METADATA$FILENAME,
         METADATA$FILE_ROW_NUMBER,
         METADATA$FILE_LAST_MODIFIED
  FROM @LAND.STG_LANDING
)
PATTERN = '.*clickstream/.*[.]ndjson[.]gz'
FILE_FORMAT = (FORMAT_NAME = LAND.FF_JSON_GZ)
ON_ERROR = CONTINUE;

-- -----------------------------------------------------------------------------
-- Verify. SYSTEM$PIPE_STATUS is the first thing to read when nothing lands:
-- auto-ingest fails silently, and executionState plus the queue counters say
-- whether the pipe is even seeing notifications.
-- -----------------------------------------------------------------------------
SHOW PIPES IN SCHEMA QCOMMERCE.LAND;
SELECT SYSTEM$PIPE_STATUS('QCOMMERCE.LAND.PIPE_CLICKSTREAM_AUTO');

-- After the upload, give it a minute then:
--   SELECT COUNT(*) FROM RAW.CLICKSTREAM_AUTO;
--   SELECT SRC_FILE, COUNT(*) FROM RAW.CLICKSTREAM_AUTO GROUP BY 1 ORDER BY 1;
--   SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
--       TABLE_NAME => 'QCOMMERCE.RAW.CLICKSTREAM_AUTO',
--       START_TIME => DATEADD(hour, -2, CURRENT_TIMESTAMP())));

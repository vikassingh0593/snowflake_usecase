-- =============================================================================
-- sql/p4_snowpipe_rest.sql — mechanism 5: Snowpipe triggered by REST.
--
-- Same pipe machinery as mechanism 4, one difference that forces everything
-- else: the stage is INTERNAL. Auto-ingest does not work on internal stages --
-- there is no cloud storage account to raise an event - so the client must call
-- insertFiles itself and tell Snowflake which files to load.
--
-- That is the whole point of running both: mechanism 4 is push (storage tells
-- Snowflake), mechanism 5 is pull (the client tells Snowflake). Same pipe, same
-- COPY, opposite direction of control.
--
-- Cost: serverless, like any pipe. No warehouse is resumed.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p04:snowpipe_rest';
USE DATABASE QCOMMERCE;

CREATE TABLE IF NOT EXISTS RAW.CLICKSTREAM_REST (
  V             VARIANT,
  SRC_FILE      STRING,
  SRC_ROW       NUMBER,
  SRC_MODIFIED  TIMESTAMP_NTZ,
  LOAD_TS       TIMESTAMP_NTZ DEFAULT SYSDATE()
) COMMENT = 'mechanism 5: Snowpipe REST insertFiles from an internal stage';

-- AUTO_INGEST is absent, not false-by-accident. A pipe on an internal stage
-- cannot have it: there is no notification source to subscribe to.
CREATE OR REPLACE PIPE LAND.PIPE_CLICKSTREAM_REST
  COMMENT = 'REST-triggered. Client calls insertFiles with the file list'
AS
COPY INTO RAW.CLICKSTREAM_REST (V, SRC_FILE, SRC_ROW, SRC_MODIFIED)
FROM (
  SELECT $1,
         METADATA$FILENAME,
         METADATA$FILE_ROW_NUMBER,
         METADATA$FILE_LAST_MODIFIED
  FROM @LAND.STG_INTERNAL
)
FILE_FORMAT = (FORMAT_NAME = LAND.FF_JSON_GZ)
ON_ERROR = CONTINUE;

-- The REST client authenticates as SVC_KAFKA with the same key pair the Kafka
-- connector uses, and needs to operate the pipe.
GRANT OPERATE, MONITOR ON PIPE LAND.PIPE_CLICKSTREAM_REST TO ROLE QC_LOADER;
GRANT READ, WRITE ON STAGE LAND.STG_INTERNAL TO ROLE QC_LOADER;

SHOW PIPES IN SCHEMA QCOMMERCE.LAND;
SELECT SYSTEM$PIPE_STATUS('QCOMMERCE.LAND.PIPE_CLICKSTREAM_REST');

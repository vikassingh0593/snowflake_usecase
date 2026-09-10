-- =============================================================================
-- sql/p5_external_iceberg.sql — mechanisms 8 and 9.
--
--   8  External table over external/settlement/ + an INSERT-ONLY stream on it
--   9  Snowflake-managed Iceberg table at FORMAT VERSION 3 on EXVOL_QC
--
-- COST: resumes WH_TRANSFORM_XS. External table refresh is metadata only; the
-- Iceberg load writes ~80k rows to Azure. Estimate 0.04-0.06 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p05:external_iceberg';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- MECHANISM 8 — external table: query the partner's files where they lie.
--
-- Nothing is copied. The table is metadata over blobs, and a settlement file
-- the partner replaces is reflected on the next refresh. That is the trade:
-- no storage cost and no load step, in exchange for reading Azure on every
-- query and having no Time Travel.
-- =============================================================================
CREATE OR REPLACE FILE FORMAT LAND.FF_SETTLEMENT_CSV
  TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL')
  EMPTY_FIELD_AS_NULL = TRUE;

CREATE OR REPLACE EXTERNAL TABLE RAW.EXT_SETTLEMENT (
  SETTLEMENT_ID       STRING  AS (VALUE:c1::STRING),
  SETTLEMENT_DATE     DATE    AS (TO_DATE(VALUE:c2::STRING)),
  CARRIER             STRING  AS (VALUE:c3::STRING),
  ORDER_ID            NUMBER  AS (VALUE:c4::NUMBER),
  FREIGHT_PAISE       NUMBER  AS (VALUE:c5::NUMBER),
  COD_COLLECTED_PAISE NUMBER  AS (VALUE:c6::NUMBER),
  ADJUSTMENT_PAISE    NUMBER  AS (VALUE:c7::NUMBER),
  STATUS              STRING  AS (VALUE:c8::STRING),
  REMARKS             STRING  AS (VALUE:c9::STRING),
  -- Partition on the filename date so a query for one day reads one file
  -- instead of every file in the container.
  SETTLEMENT_DAY      DATE    AS TO_DATE(SPLIT_PART(SPLIT_PART(METADATA$FILENAME, '_', -1), '.', 1), 'YYYYMMDD')
)
PARTITION BY (SETTLEMENT_DAY)
LOCATION = @LAND.STG_EXTERNAL/settlement/
AUTO_REFRESH = FALSE
FILE_FORMAT = (FORMAT_NAME = LAND.FF_SETTLEMENT_CSV)
COMMENT = 'mechanism 8: 3PL settlement, queried in place';

ALTER EXTERNAL TABLE RAW.EXT_SETTLEMENT REFRESH;

-- INSERT-ONLY is the only stream type an external table supports: a file that
-- appears is an insert, and there is no update or delete to track because the
-- partner replaces files rather than editing rows.
CREATE OR REPLACE STREAM RAW.STR_SETTLEMENT_NEWFILES
  ON EXTERNAL TABLE RAW.EXT_SETTLEMENT
  INSERT_ONLY = TRUE
  COMMENT = 'stream type 3 of 5: insert-only, on an external table';

SELECT COUNT(*) AS settlement_rows FROM RAW.EXT_SETTLEMENT;
SELECT SETTLEMENT_DAY, COUNT(*) AS n, SUM(FREIGHT_PAISE) AS freight_paise
FROM   RAW.EXT_SETTLEMENT GROUP BY 1 ORDER BY 1;

-- Reconciliation is the reason this stays external: the partner's view of an
-- order versus ours, without importing their file into our history.
SELECT STATUS, COUNT(*) AS n, SUM(ADJUSTMENT_PAISE) AS adjustments_paise
FROM   RAW.EXT_SETTLEMENT GROUP BY 1 ORDER BY 2 DESC;

-- =============================================================================
-- MECHANISM 9 — Iceberg, Snowflake-managed, format version 3.
--
-- ICEBERG_VERSION = 3 is set explicitly. v3 is GA since 2026-05-07 and brings
-- deletion vectors and row lineage; the upgrade from v2 is IRREVERSIBLE and v2
-- readers cannot read v3, so the table is created at 3 rather than created at 2
-- and upgraded.
--
-- Snowflake writes the data and metadata into archive/ on the external volume
-- verified in Part 2. Another engine could read it from there without Snowflake
-- being involved, which is the entire argument for Iceberg over a normal table.
-- =============================================================================
CREATE OR REPLACE ICEBERG TABLE RAW.ORDER_EVENTS_ICEBERG (
  EVENT_ID     STRING,
  ORDER_ID     NUMBER(38,0),
  STORE_ID     NUMBER(38,0),
  RIDER_ID     NUMBER(38,0),
  FROM_STATUS  STRING,
  TO_STATUS    STRING,
  EVENT_TS     TIMESTAMP_NTZ,
  SOURCE       STRING,
  APP_VERSION  STRING,
  NETWORK      STRING
)
CATALOG = 'SNOWFLAKE'
EXTERNAL_VOLUME = 'EXVOL_QC'
BASE_LOCATION = 'order_events/'
ICEBERG_VERSION = 3
COMMENT = 'mechanism 9: archived order events, Iceberg v3, Snowflake-managed';

INSERT INTO RAW.ORDER_EVENTS_ICEBERG
SELECT RECORD_CONTENT:event_id::STRING,
       RECORD_CONTENT:order_id::NUMBER,
       RECORD_CONTENT:store_id::NUMBER,
       RECORD_CONTENT:rider_id::NUMBER,
       RECORD_CONTENT:from_status::STRING,
       RECORD_CONTENT:to_status::STRING,
       TRY_TO_TIMESTAMP_NTZ(RECORD_CONTENT:event_ts::STRING),
       RECORD_CONTENT:source::STRING,
       RECORD_CONTENT:meta:app_version::STRING,
       RECORD_CONTENT:meta:network::STRING
FROM   RAW.ORDER_STATUS_KAFKA_V4;

SELECT COUNT(*) AS iceberg_rows FROM RAW.ORDER_EVENTS_ICEBERG;

-- v3's headline feature. In v2 a row-level delete writes positional delete
-- files that readers merge at O(log n); v3 writes a deletion vector, a binary
-- bitmap applied at O(1) per row. The DELETE below is what produces one.
DELETE FROM RAW.ORDER_EVENTS_ICEBERG WHERE TO_STATUS = 'CANCELLED';

SELECT COUNT(*) AS after_delete FROM RAW.ORDER_EVENTS_ICEBERG;

-- Where the files actually are, and what version they claim.
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('QCOMMERCE.RAW.ORDER_EVENTS_ICEBERG');
SHOW ICEBERG TABLES IN SCHEMA QCOMMERCE.RAW;

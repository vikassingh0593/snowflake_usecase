-- =============================================================================
-- sql/p3_prep.sql — everything Snowflake needs before the first byte arrives.
--
-- Cost: metadata only. No warehouse is resumed by this file. ~0 credits.
--
-- Sections 1 and 2 need values pasted in. 3 onward run as-is.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p03:prep';

-- -----------------------------------------------------------------------------
-- 1. Service user keys.
--
-- SVC_KAFKA and SVC_CI are TYPE = SERVICE: no password, no browser. The Kafka
-- connector runs headless in a container, so key-pair is the only option.
--
-- Generate on your Mac, in the repo root (rsa_*.p8 is gitignored):
--   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_kafka.p8 -nocrypt
--   openssl rsa -in rsa_kafka.p8 -pubout -out rsa_kafka.pub
--   chmod 600 rsa_kafka.p8
--   grep -v "^-----" rsa_kafka.pub | tr -d '\n'; echo
--
-- Paste that single line below. Unencrypted deliberately: a passphrase would
-- have to live in the connector config, which is the same exposure in a worse
-- place. File permissions do the work instead.
-- -----------------------------------------------------------------------------
-- ALTER USER SVC_KAFKA SET RSA_PUBLIC_KEY = '<paste rsa_kafka.pub, one line>';
-- ALTER USER SVC_CI    SET RSA_PUBLIC_KEY = '<paste rsa_ci.pub, one line>';

DESC USER SVC_KAFKA;   -- HAS_RSA_PUBLIC_KEY must read true before the connector starts

-- -----------------------------------------------------------------------------
-- 2. Confirm the Enterprise assumption before governance is built on it.
--
-- Masking policies, row access policies, aggregation policies and materialized
-- views all resolve under SHOW, and ACCESS_HISTORY reads. That is strong
-- evidence, not proof - an empty SHOW result misled this build once already.
-- CREATE either works or it does not.
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS QC_PROBE_TMP;
CREATE OR REPLACE MASKING POLICY QC_PROBE_TMP.PUBLIC.MP_PROBE
  AS (v STRING) RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() = 'ACCOUNTADMIN' THEN v ELSE '***' END;
SHOW MASKING POLICIES IN DATABASE QC_PROBE_TMP;
DROP DATABASE QC_PROBE_TMP;

-- -----------------------------------------------------------------------------
-- 3. Grants the connector needs beyond the bootstrap.
--
-- With schematization OFF the connector creates its own tables, so it needs
-- CREATE TABLE on RAW - already granted. File mode (mechanism 3) additionally
-- creates an internal stage and a pipe in the SAME schema as the target table,
-- which the bootstrap only granted on LAND.
-- -----------------------------------------------------------------------------
GRANT CREATE STAGE, CREATE PIPE ON SCHEMA QCOMMERCE.RAW TO ROLE QC_LOADER;
GRANT USAGE ON WAREHOUSE WH_INGEST_XS TO ROLE QC_LOADER;   -- idempotent

-- -----------------------------------------------------------------------------
-- 4. Target table for mechanism 2 - the Streaming SDK writing directly, with no
--    Kafka anywhere in the path.
--
-- Deliberately the same shape the connector creates for itself, so the three
-- mechanisms can be compared on identical columns. LOAD_TS is written by the
-- client rather than defaulted: column defaults are not reliably applied on the
-- streaming write path, and a silently NULL timestamp would quietly ruin the
-- latency comparison this part exists to produce.
-- -----------------------------------------------------------------------------
USE DATABASE QCOMMERCE;
USE SCHEMA RAW;

CREATE TABLE IF NOT EXISTS ORDER_STATUS_SDK (
  RECORD_CONTENT   VARIANT,
  RECORD_METADATA  VARIANT,
  LOAD_TS          TIMESTAMP_NTZ
) COMMENT = 'mechanism 2: Snowpipe Streaming SDK, direct, no Kafka';

-- -----------------------------------------------------------------------------
-- 5. OPS tables. Referenced by every later part, so they exist from here.
-- -----------------------------------------------------------------------------
USE SCHEMA OPS;

CREATE TABLE IF NOT EXISTS PIPELINE_LOG (
  LOG_TS        TIMESTAMP_NTZ DEFAULT SYSDATE(),
  PART          STRING,        -- 'p03'
  COMPONENT     STRING,        -- 'kafka_v4' | 'sdk_direct' | 'kafka_file_mode'
  EVENT         STRING,        -- 'run_start' | 'run_end' | 'error'
  ROWS_AFFECTED NUMBER,
  DETAIL        VARIANT,
  QUERY_ID      STRING
) COMMENT = 'structured pipeline logging. Substitutes for event tables';

CREATE TABLE IF NOT EXISTS DQ_RESULTS (
  CHECK_TS   TIMESTAMP_NTZ DEFAULT SYSDATE(),
  CHECK_NAME STRING,
  TARGET     STRING,
  PASSED     BOOLEAN,
  OBSERVED   NUMBER,
  EXPECTED   STRING,
  DETAIL     VARIANT
) COMMENT = 'dbt tests, Snowpark checks and DMFs all land here';

CREATE TABLE IF NOT EXISTS INGEST_BENCHMARK (
  MEASURED_AT     TIMESTAMP_NTZ DEFAULT SYSDATE(),
  MECHANISM       STRING,       -- the three-way comparison, a stated deliverable
  ROWS_LANDED     NUMBER,
  FIRST_EVENT_TS  TIMESTAMP_NTZ,
  LAST_LOAD_TS    TIMESTAMP_NTZ,
  P50_LATENCY_SEC FLOAT,
  P95_LATENCY_SEC FLOAT,
  CREDITS         FLOAT,
  NOTES           STRING
) COMMENT = 'mechanism 1 vs 2 vs 3 on identical input';

-- -----------------------------------------------------------------------------
-- 6. Verify
-- -----------------------------------------------------------------------------
SHOW TABLES IN SCHEMA QCOMMERCE.RAW;
SHOW TABLES IN SCHEMA QCOMMERCE.OPS;
SHOW GRANTS TO ROLE QC_LOADER;

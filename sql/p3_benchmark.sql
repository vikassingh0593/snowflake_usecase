-- =============================================================================
-- sql/p3_benchmark.sql — mechanism 1 vs 2 vs 3, on identical input.
--
-- The row counts match. That is the exactly-once claim holding, not the
-- comparison. This file produces the comparison: what each path cost, how each
-- behaved, and what is genuinely NOT measurable from the tables alone.
--
-- Cost: resumes WH_TRANSFORM_XS briefly. Under 0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p03:benchmark';
USE DATABASE QCOMMERCE;

-- -----------------------------------------------------------------------------
-- 1. All three paths created a pipe, including the two that never mention one.
--
-- "Snowpipe Streaming" is not pipe-less, it is pipe-implicit: the v4 connector
-- made ORDER_STATUS_KAFKA_V4-STREAMING and the SDK made
-- ORDER_STATUS_SDK-STREAMING, neither of which was declared. That is what lets
-- offset tokens live server-side rather than in the client.
-- -----------------------------------------------------------------------------
SHOW PIPES IN SCHEMA QCOMMERCE.RAW;

-- -----------------------------------------------------------------------------
-- 2. Row counts and duplicate load.
--
-- The generator plants 1% duplicate event_ids because Snowpipe Streaming is
-- at-least-once. Every mechanism therefore carries them: none of the three
-- deduped, and none of them should. Dedupe is CORE's job, one QUALIFY line.
-- -----------------------------------------------------------------------------
WITH src AS (
  SELECT 'a. kafka v4 streaming' AS mechanism, RECORD_CONTENT AS c FROM RAW.ORDER_STATUS_KAFKA_V4
  UNION ALL
  SELECT 'b. sdk direct',              RECORD_CONTENT FROM RAW.ORDER_STATUS_SDK
  UNION ALL
  SELECT 'c. kafka v3 file mode',      RECORD_CONTENT FROM RAW.ORDER_STATUS_KAFKA_V3FILE
)
SELECT mechanism,
       COUNT(*)                                   AS rows_landed,
       COUNT(DISTINCT c:event_id::STRING)         AS distinct_event_ids,
       COUNT(*) - COUNT(DISTINCT c:event_id::STRING) AS duplicates_carried,
       MIN(TRY_TO_TIMESTAMP_NTZ(c:event_ts::STRING)) AS first_event,
       MAX(TRY_TO_TIMESTAMP_NTZ(c:event_ts::STRING)) AS last_event
FROM   src
GROUP  BY mechanism
ORDER  BY mechanism;

-- -----------------------------------------------------------------------------
-- 3. Credits per mechanism.
--
-- This is the cleanest part of the comparison: each mechanism owns a distinct
-- pipe, so PIPE_USAGE_HISTORY attributes serverless credits per path with no
-- estimation at all. Serverless spend is invisible to RM_POC, which is exactly
-- why the account budget matters.
--
-- ACCOUNT_USAGE lags up to ~3 hours. If this returns nothing, it is too soon --
-- section 4 is the low-latency version.
-- -----------------------------------------------------------------------------
SELECT pipe_name,
       SUM(credits_used)  AS credits,
       SUM(bytes_inserted) AS bytes_inserted,
       SUM(files_inserted) AS files_inserted,
       MIN(start_time)     AS first_seen,
       MAX(end_time)       AS last_seen
FROM   SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE  start_time >= DATEADD(hour, -6, CURRENT_TIMESTAMP())
GROUP  BY pipe_name
ORDER  BY credits DESC;

-- Low-latency equivalent, per pipe. Run one per pipe name from section 1.
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.PIPE_USAGE_HISTORY(
--   DATE_RANGE_START => DATEADD(hour, -6, CURRENT_TIMESTAMP()),
--   PIPE_NAME => 'QCOMMERCE.RAW."ORDER_STATUS_KAFKA_V4-STREAMING"'));

-- -----------------------------------------------------------------------------
-- 4. Serverless spend by service type, last 6 hours.
-- Confirms the shape of the bill: streaming ingest is serverless, so none of
-- this appears against a warehouse.
-- -----------------------------------------------------------------------------
SELECT service_type, SUM(credits_used) AS credits
FROM   SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE  start_time >= DATEADD(hour, -6, CURRENT_TIMESTAMP())
GROUP  BY service_type
ORDER  BY credits DESC;

-- -----------------------------------------------------------------------------
-- 5. Latency, and an honest note about what cannot be measured here.
--
-- Only the SDK table carries a client-written LOAD_TS, so only it supports a
-- true per-row end-to-end latency. The two connector tables hold what the
-- connector chose to record and no arrival timestamp, so a "latency" computed
-- from them would be invented. What IS comparable:
--
--   * v4 records connectorPushTime, giving producer -> connector lag.
--   * v3 file mode batches on buffer.flush.time = 60s, so its floor is
--     structurally ~60s regardless of measurement.
--   * The SDK reports server_avg_processing_latency on the channel directly.
--
-- The design point stands without fake precision: streaming commits in
-- 5-10 second windows, file mode cannot beat its own flush interval, and the
-- SDK removes the broker from the path entirely.
-- -----------------------------------------------------------------------------
SELECT 'b. sdk direct' AS mechanism,
       COUNT(*)                                                          AS rows_measured,
       ROUND(AVG(DATEDIFF('millisecond',
              TRY_TO_TIMESTAMP_NTZ(RECORD_CONTENT:event_ts::STRING), LOAD_TS)) / 1000.0, 1)
                                                                          AS avg_producer_to_load_sec,
       MIN(LOAD_TS) AS first_load, MAX(LOAD_TS) AS last_load
FROM   RAW.ORDER_STATUS_SDK
WHERE  LOAD_TS IS NOT NULL;

-- v4 connector-side lag, where the connector recorded its own push time.
SELECT 'a. kafka v4 streaming' AS mechanism,
       COUNT(*) AS rows_with_push_time,
       MIN(RECORD_METADATA:CreateTime::STRING) AS sample_create_time,
       MIN(RECORD_METADATA:connectorPushTime::STRING) AS sample_push_time
FROM   RAW.ORDER_STATUS_KAFKA_V4
WHERE  RECORD_METADATA:connectorPushTime IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 6. Record it. Fill credits from section 3 once ACCOUNT_USAGE catches up.
-- -----------------------------------------------------------------------------
INSERT INTO OPS.INGEST_BENCHMARK
  (MECHANISM, ROWS_LANDED, FIRST_EVENT_TS, LAST_LOAD_TS, NOTES)
SELECT 'kafka_connector_v4_streaming', COUNT(*),
       MIN(TRY_TO_TIMESTAMP_NTZ(RECORD_CONTENT:event_ts::STRING)), NULL,
       'v4.1.0 SnowflakeStreamingSinkConnector, 3 tasks, schematization off, implicit pipe'
FROM RAW.ORDER_STATUS_KAFKA_V4
UNION ALL
SELECT 'snowpipe_streaming_sdk_direct', COUNT(*),
       MIN(TRY_TO_TIMESTAMP_NTZ(RECORD_CONTENT:event_ts::STRING)), MAX(LOAD_TS),
       'python SDK 1.8.0, one channel, server-side offset tokens, no broker'
FROM RAW.ORDER_STATUS_SDK
UNION ALL
SELECT 'kafka_connector_v3_file_mode', COUNT(*),
       MIN(TRY_TO_TIMESTAMP_NTZ(RECORD_CONTENT:event_ts::STRING)), NULL,
       'v3.5.4 SnowflakeSinkConnector, SNOWPIPE, buffer.flush.time 60s'
FROM RAW.ORDER_STATUS_KAFKA_V3FILE;

SELECT * FROM OPS.INGEST_BENCHMARK ORDER BY MECHANISM;

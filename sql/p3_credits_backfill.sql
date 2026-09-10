-- Run ~3 hours after the Part 3 ingest. ACCOUNT_USAGE.PIPE_USAGE_HISTORY lags,
-- so the credits column in OPS.INGEST_BENCHMARK is NULL until it catches up.
--
-- Each mechanism owns a distinct pipe, which is what makes this attribution
-- exact rather than estimated.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p03:credits';
USE DATABASE QCOMMERCE;

SELECT pipe_name, SUM(credits_used) AS credits, SUM(bytes_inserted) AS bytes
FROM   SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE  start_time >= DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP  BY pipe_name ORDER BY credits DESC;

UPDATE OPS.INGEST_BENCHMARK b
SET CREDITS = (
  SELECT SUM(p.credits_used)
  FROM   SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY p
  WHERE  p.pipe_name ILIKE CASE b.MECHANISM
           WHEN 'kafka_connector_v4_streaming'  THEN '%ORDER_STATUS_KAFKA_V4-STREAMING%'
           WHEN 'snowpipe_streaming_sdk_direct' THEN '%ORDER_STATUS_SDK-STREAMING%'
           ELSE                                      '%ORDER_STATUS_KAFKA_V3FILE%'
         END
    AND  p.start_time >= DATEADD(hour, -24, CURRENT_TIMESTAMP()));

SELECT MECHANISM, ROWS_LANDED, CREDITS, NOTES FROM OPS.INGEST_BENCHMARK ORDER BY MECHANISM;

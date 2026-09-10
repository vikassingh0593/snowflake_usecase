-- =============================================================================
-- sql/p6_external_access.sql — mechanism 11.
--
--   Network rule -> secret -> external access integration -> Python UDF that
--   calls Open-Meteo for each dark store's coordinates.
--
-- The point of this mechanism is that the call originates INSIDE Snowflake.
-- No Airflow task, no Lambda, no laptop with a cron entry. Egress is denied by
-- default and the network rule is the only thing that opens it, for exactly
-- these two hosts, for exactly the functions that name the integration.
--
-- PREREQUISITE: mechanism 13 (scripts/p6_pandas_run.sh) must have run.
-- RAW.DIM_STORE_SEED is where the coordinates come from.
--
-- COST: resumes WH_TRANSFORM_XS. Eight HTTPS calls, ~800 KB of JSON, flattened
-- to ~17,800 rows. Estimate 0.01-0.02 credits. Open-Meteo's free tier is
-- 10,000 calls/day (UNVERIFIED); this uses eight.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p06:external_access';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — the network rule. Egress, host list, nothing else reachable.
--
-- Both hosts are listed although only the first is used. api.open-meteo.com
-- serves recent history through past_days; archive-api.open-meteo.com serves
-- the long record but lags roughly five days. If past_days turns out to be
-- capped below 92 on the free tier, the fallback is a query change rather than
-- a DDL change and a re-consent -- which is the only reason to list a host you
-- are not calling today.
-- =============================================================================
CREATE OR REPLACE NETWORK RULE LAND.NR_OPEN_METEO
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.open-meteo.com:443', 'archive-api.open-meteo.com:443')
  COMMENT = 'mechanism 11 - weather per dark store';

-- =============================================================================
-- STEP 2 — the secret.
--
-- Open-Meteo's free endpoint takes no key. This secret is NOT a credential: it
-- carries the User-Agent that identifies this client, which their usage policy
-- asks heavy callers to send. It exists so the secret -> integration -> UDF
-- chain is built and exercised, and it is safe to commit precisely because it
-- is not sensitive.
--
-- A REAL credential never goes in this file. Create it once by hand instead:
--   snow sql -c qcpoc -q "CREATE SECRET LAND.SEC_X TYPE=GENERIC_STRING SECRET_STRING='...'"
-- and let the file reference it by name. A secret's value is readable only
-- through get_generic_secret_string() inside a function that the integration
-- allows -- not by SELECT, and not by DESC.
-- =============================================================================
CREATE OR REPLACE SECRET LAND.SEC_WEATHER_CLIENT
  TYPE = GENERIC_STRING
  SECRET_STRING = 'qcommerce-poc/1.0 (snowflake-udf)'
  COMMENT = 'mechanism 11 - User-Agent, not a credential';

-- =============================================================================
-- STEP 3 — the integration. Rules and secrets are inert until one names them.
-- =============================================================================
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION EAI_OPEN_METEO
  ALLOWED_NETWORK_RULES = (LAND.NR_OPEN_METEO)
  ALLOWED_AUTHENTICATION_SECRETS = (LAND.SEC_WEATHER_CLIENT)
  ENABLED = TRUE
  COMMENT = 'mechanism 11 - Open-Meteo egress';

GRANT USAGE ON INTEGRATION EAI_OPEN_METEO TO ROLE QC_ENGINEER;
GRANT USAGE ON SECRET LAND.SEC_WEATHER_CLIENT TO ROLE QC_ENGINEER;
GRANT READ ON SECRET LAND.SEC_WEATHER_CLIENT TO ROLE QC_ENGINEER;

-- =============================================================================
-- STEP 4 — the caller.
--
-- Returns the response VARIANT unshredded. Parsing parallel arrays is SQL's
-- job, not Python's: FLATTEN with an index does it in one expression and is
-- far easier to see wrong than a nested loop inside a UDF.
--
-- VOLATILE is explicit. A UDF Snowflake believes is deterministic can have its
-- result reused across rows and runs, and an HTTP call is neither.
-- =============================================================================
CREATE OR REPLACE FUNCTION RAW.FETCH_WEATHER(LAT FLOAT, LON FLOAT, PAST_DAYS INT)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
HANDLER = 'fetch'
EXTERNAL_ACCESS_INTEGRATIONS = (EAI_OPEN_METEO)
SECRETS = ('ua' = LAND.SEC_WEATHER_CLIENT)
VOLATILE
COMMENT = 'mechanism 11 - hourly weather for one dark store'
AS
$$
import _snowflake
import requests

SESSION = requests.Session()


def fetch(lat: float, lon: float, past_days: int):
    params = {
        "latitude": lat,
        "longitude": lon,
        "hourly": "temperature_2m,precipitation,wind_speed_10m,relative_humidity_2m",
        "past_days": int(past_days),
        "forecast_days": 1,
        "timezone": "UTC",
    }
    headers = {"User-Agent": _snowflake.get_generic_secret_string("ua")}

    # One retry. A single transient failure should not cost the whole load,
    # and more than one retry inside a UDF just holds a warehouse open.
    last = None
    for _ in range(2):
        try:
            r = SESSION.get("https://api.open-meteo.com/v1/forecast",
                            params=params, headers=headers, timeout=30)
            if r.status_code == 200:
                return r.json()
            last = f"HTTP {r.status_code}: {r.text[:200]}"
        except Exception as exc:
            last = f"{type(exc).__name__}: {exc}"
    # Return the failure as data. Raising here fails the whole statement and
    # tells you nothing about which of the eight stores was the problem.
    return {"error": last, "latitude": lat, "longitude": lon}
$$;

-- =============================================================================
-- STEP 5 — one store first.
--
-- If egress is not actually open this fails here, having called nothing eight
-- times. The error to expect when the integration is missing or not granted is
-- a network policy denial, not a timeout.
-- =============================================================================
SELECT RAW.FETCH_WEATHER(28.4595, 77.0266, 2):hourly.time[0]::STRING AS FIRST_HOUR,
       ARRAY_SIZE(RAW.FETCH_WEATHER(28.4595, 77.0266, 2):hourly.time) AS HOURS_RETURNED;

-- =============================================================================
-- STEP 6 — land the responses exactly as they arrived.
--
-- Eight rows of VARIANT, materialised BEFORE any flatten. This is not tidiness:
-- calling the UDF in a CTE that a LATERAL FLATTEN then expands can re-evaluate
-- it per output row -- eight calls become seventeen thousand. Materialising
-- first makes the call count a fact rather than a hope, and it is also what
-- RAW is for: the payload as sent, parsed later.
-- =============================================================================
CREATE OR REPLACE TABLE RAW.WEATHER_API_RESPONSE AS
SELECT s.STORE_ID,
       s.STORE_CODE,
       s.ZONE_CODE,
       s.LAT,
       s.LON,
       RAW.FETCH_WEATHER(s.LAT, s.LON, 92) AS RESPONSE,
       CURRENT_TIMESTAMP()                 AS LOAD_TS
FROM   RAW.DIM_STORE_SEED s;

-- Any store that failed says so here, by name, before anything is shredded.
SELECT STORE_CODE,
       RESPONSE:error::STRING              AS ERROR,
       ARRAY_SIZE(RESPONSE:hourly.time)    AS HOURS
FROM   RAW.WEATHER_API_RESPONSE
ORDER  BY STORE_ID;

-- =============================================================================
-- STEP 7 — shred the parallel arrays.
--
-- hourly.time, hourly.temperature_2m and the rest are separate arrays that
-- share an index. FLATTEN the timestamps, then subscript the others by
-- f.INDEX -- one pass, no join, no assumption that the arrays are sorted the
-- same way beyond the contract that says they are positional.
-- =============================================================================
CREATE OR REPLACE TABLE RAW.STORE_WEATHER AS
SELECT r.STORE_ID,
       r.STORE_CODE,
       r.ZONE_CODE,
       TO_TIMESTAMP_NTZ(f.VALUE::STRING)                    AS OBS_TS,
       r.RESPONSE:hourly.temperature_2m[f.INDEX]::FLOAT     AS TEMP_C,
       r.RESPONSE:hourly.precipitation[f.INDEX]::FLOAT      AS PRECIP_MM,
       r.RESPONSE:hourly.wind_speed_10m[f.INDEX]::FLOAT     AS WIND_KMH,
       r.RESPONSE:hourly.relative_humidity_2m[f.INDEX]::INT AS HUMIDITY_PCT,
       r.LOAD_TS
FROM   RAW.WEATHER_API_RESPONSE r,
       LATERAL FLATTEN(input => r.RESPONSE:hourly.time) f
WHERE  r.RESPONSE:error IS NULL;

-- =============================================================================
-- STEP 8 — verify.
-- =============================================================================
SELECT COUNT(*)                  AS n,
       COUNT(DISTINCT STORE_ID)  AS stores,
       MIN(OBS_TS)               AS from_ts,
       MAX(OBS_TS)               AS to_ts,
       ROUND(AVG(TEMP_C), 1)     AS avg_temp_c,
       ROUND(SUM(PRECIP_MM))     AS total_precip_mm
FROM   RAW.STORE_WEATHER;

-- Does the window actually cover the order data (2026-07-11 to 2026-09-09)?
-- If from_ts is later than 2026-07-11 the free tier capped past_days, and the
-- archive host in the network rule is the fallback.
SELECT IFF(MIN(OBS_TS) <= '2026-07-11'::TIMESTAMP_NTZ, 'covers order window',
           'SHORT - switch to archive-api') AS coverage
FROM   RAW.STORE_WEATHER;

-- Gaps matter more than averages here: a missing hour becomes a null feature
-- in the risk model, and a null feature is worse than a bad one.
SELECT STORE_CODE,
       COUNT(*)                                  AS hours,
       SUM(IFF(TEMP_C IS NULL, 1, 0))            AS null_temp,
       SUM(IFF(PRECIP_MM > 0, 1, 0))             AS wet_hours
FROM   RAW.STORE_WEATHER
GROUP  BY STORE_CODE
ORDER  BY STORE_CODE;

-- The join that makes this worth ingesting at all. Kept as a probe, not a
-- table: modelling belongs in CORE and MART, not here.
SELECT w.ZONE_CODE,
       ROUND(AVG(w.TEMP_C), 1)   AS avg_temp_c,
       ROUND(AVG(w.PRECIP_MM), 3) AS avg_precip_mm
FROM   RAW.STORE_WEATHER w
WHERE  HOUR(w.OBS_TS) BETWEEN 12 AND 16   -- the evening peak, in IST
GROUP  BY w.ZONE_CODE
ORDER  BY w.ZONE_CODE;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE    IF EXISTS QCOMMERCE.RAW.STORE_WEATHER;
-- DROP TABLE    IF EXISTS QCOMMERCE.RAW.WEATHER_API_RESPONSE;
-- DROP FUNCTION IF EXISTS QCOMMERCE.RAW.FETCH_WEATHER(FLOAT, FLOAT, INT);
-- DROP INTEGRATION IF EXISTS EAI_OPEN_METEO;
-- DROP SECRET       IF EXISTS QCOMMERCE.LAND.SEC_WEATHER_CLIENT;
-- DROP NETWORK RULE IF EXISTS QCOMMERCE.LAND.NR_OPEN_METEO;

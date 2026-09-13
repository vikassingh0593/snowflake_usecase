-- =============================================================================
-- PART 11 / STEP 0 — what kind of Streamlit can this account run.
--
-- Two questions, both settled by attempting the operation rather than by
-- reading a privileges list. That is how the three findings in §1 of
-- ARCHITECTURE.md were established, and each time SHOW would have been
-- misleading.
--
--   1. Does CREATE STREAMLIT work here at all? Cortex is gated on this trial
--      account and external access integrations are refused outright, so the
--      app surface being gated too is a live possibility rather than
--      pessimism.
--
--   2. Which packages and versions does the app runtime carry? Streamlit in
--      Snowflake pins a Streamlit version, and the API moved a great deal
--      across 1.2x to 1.4x -- st.tabs, dataframe column_config, the
--      width arguments on charts. Writing several hundred lines of app against
--      the wrong one is an avoidable way to lose a session.
--
-- Nothing here is the app. Everything is dropped at the end.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p11:probe';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — what the channel carries.
--
-- This is the UDF/procedure channel. It is the best available proxy for what
-- an app can import, but it is NOT a guarantee: the Streamlit runtime is a
-- separate environment and only the app itself can report what it is really
-- running. The first real app therefore prints streamlit.__version__ on its
-- own health tab rather than trusting this table.
-- =============================================================================
SELECT PACKAGE_NAME,
       COUNT(*)                                         AS versions_offered,
       MIN(VERSION)                                     AS oldest,
       MAX(VERSION)                                     AS newest
FROM   INFORMATION_SCHEMA.PACKAGES
WHERE  LANGUAGE = 'python'
  AND  PACKAGE_NAME IN ('streamlit', 'plotly', 'altair', 'pandas', 'numpy',
                        'pydeck', 'matplotlib', 'snowflake-snowpark-python')
GROUP  BY PACKAGE_NAME
ORDER  BY PACKAGE_NAME;

-- Version strings sort as text, so MAX above will mislead on anything that
-- reaches double digits -- '1.9' beats '1.40'. The newest few, listed.
SELECT PACKAGE_NAME, VERSION, RUNTIME_VERSION
FROM   INFORMATION_SCHEMA.PACKAGES
WHERE  LANGUAGE = 'python'
  AND  PACKAGE_NAME = 'streamlit'
ORDER  BY TRY_TO_NUMBER(SPLIT_PART(VERSION, '.', 1)) DESC NULLS LAST,
          TRY_TO_NUMBER(SPLIT_PART(VERSION, '.', 2)) DESC NULLS LAST,
          TRY_TO_NUMBER(SPLIT_PART(VERSION, '.', 3)) DESC NULLS LAST
LIMIT  8;

-- =============================================================================
-- STEP 2 — a stage for app files.
--
-- Internal, in APP, which p1_bootstrap created for exactly this and which has
-- been empty ever since.
-- =============================================================================
CREATE STAGE IF NOT EXISTS APP.STG_APP
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Streamlit source. app.py and environment.yml live here';

LIST @APP.STG_APP;

-- =============================================================================
-- STEP 3 — can this account create one at all.
--
-- Deliberately pointed at a location with no file in it. CREATE STREAMLIT
-- registers the object and resolves the source when the app is opened, so this
-- separates "the account permits Streamlit objects" from "the app code is
-- correct" -- two failures that would otherwise arrive as one error message.
--
-- If this fails, read the error carefully before concluding anything. A
-- privilege error, a trial-account refusal and an unsupported-region message
-- are three different outcomes and only one of them ends Part 11.
-- =============================================================================
CREATE OR REPLACE STREAMLIT APP.TMP_PROBE_APP
  ROOT_LOCATION = '@QCOMMERCE.APP.STG_APP'
  MAIN_FILE = '/probe.py'
  QUERY_WAREHOUSE = WH_APP_XS
  COMMENT = 'probe only, dropped at the end of p11_streamlit_probe.sql';

SHOW STREAMLITS IN SCHEMA APP;

DESCRIBE STREAMLIT APP.TMP_PROBE_APP;

-- =============================================================================
-- STEP 4 — record the outcome.
--
-- Reaching this statement at all means STEP 3 succeeded, because snow sql
-- aborts the file on the first error. The check is therefore about what was
-- created rather than about whether creation is possible -- the abort is the
-- real test.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'account_permits_streamlit_objects', 'APP.TMP_PROBE_APP',
       TRUE, 1,
       'CREATE STREAMLIT succeeded on this account -- reaching this row is '
         || 'the evidence, since the script aborts on the first error',
       OBJECT_CONSTRUCT('warehouse', 'WH_APP_XS',
                        'root_location', '@QCOMMERCE.APP.STG_APP');

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED, DETAIL
FROM   OPS.DQ_RESULTS
WHERE  TARGET = 'APP.TMP_PROBE_APP'
ORDER  BY CHECK_TS DESC
LIMIT  1;

-- =============================================================================
-- STEP 5 — clean up. The stage stays; the probe app does not.
-- =============================================================================
DROP STREAMLIT IF EXISTS APP.TMP_PROBE_APP;

SHOW STREAMLITS IN SCHEMA APP;

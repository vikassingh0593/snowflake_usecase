-- =============================================================================
-- sql/p6_pkg_probe.sql — can this account use third-party Python packages?
--
-- Mechanisms 10 and 11 need pypdf and requests. The documented gate is the
-- Anaconda Terms of Service, accepted by an ORGADMIN in Snowsight -- but there
-- is no Anaconda section on this account's Billing & Terms page, which means
-- either it lives somewhere else or the separate acceptance no longer exists.
--
-- Rather than hunt the UI, do what settled the Enterprise question in Part 2:
-- attempt the CREATE. A SHOW or a catalogue listing can report a package that
-- CREATE FUNCTION then refuses; a function that compiles and returns a version
-- string cannot be wrong.
--
-- COST: resumes WH_TRANSFORM_XS and pays one Python UDF cold start, roughly
-- 5-10 s. Under 0.01 credits. The functions are dropped at the end.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p06:pkg_probe';
USE DATABASE QCOMMERCE;

-- The catalogue view. Rows here are necessary but NOT sufficient -- this lists
-- what the channel carries, not what this account may compile against.
SELECT PACKAGE_NAME, MAX(VERSION) AS LATEST
FROM   INFORMATION_SCHEMA.PACKAGES
WHERE  LANGUAGE = 'python'
  AND  PACKAGE_NAME IN ('pypdf', 'requests', 'snowflake-snowpark-python')
GROUP  BY PACKAGE_NAME
ORDER  BY PACKAGE_NAME;

-- The real test. If the terms are unaccepted and still required, this is where
-- it fails, and the error names the reason.
CREATE OR REPLACE FUNCTION RAW.TMP_PROBE_PYPDF()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('pypdf')
HANDLER = 'v'
AS
$$
import pypdf
def v():
    return "pypdf " + pypdf.__version__
$$;

CREATE OR REPLACE FUNCTION RAW.TMP_PROBE_REQUESTS()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
HANDLER = 'v'
AS
$$
import requests
def v():
    return "requests " + requests.__version__
$$;

-- Compiling is not running. A package can resolve at CREATE and fail to import
-- at execution, so both functions are actually called.
SELECT RAW.TMP_PROBE_PYPDF()    AS pypdf_ok,
       RAW.TMP_PROBE_REQUESTS() AS requests_ok;

-- Is RUNTIME_VERSION 3.12 available yet? Mechanisms 10 and 11 pin 3.11 because
-- 3.12 support was UNVERIFIED. A row here means the pin can be raised.
SELECT DISTINCT RUNTIME_VERSION
FROM   INFORMATION_SCHEMA.PACKAGES
WHERE  LANGUAGE = 'python'
ORDER  BY RUNTIME_VERSION;

DROP FUNCTION IF EXISTS RAW.TMP_PROBE_PYPDF();
DROP FUNCTION IF EXISTS RAW.TMP_PROBE_REQUESTS();

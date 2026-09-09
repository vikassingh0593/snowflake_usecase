-- =============================================================================
-- sql/p2_integrations.sql — the three Azure integrations. THIS WRITES.
--
-- BEFORE RUNNING: replace <SA> with the storage account name and <TENANT_ID>
-- with the tenant GUID that scripts/p2_azure.sh printed.
--
-- Run section by section. Each integration needs a consent + RBAC round trip
-- in the Azure portal between creating it and using it, so this file is not a
-- single "run all".
--
-- Cost: metadata only, no warehouse. Free.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = 'p02:integrations';

-- =============================================================================
-- STEP 1 — create all three objects, then do the consent dance once per object
-- =============================================================================

-- 1a. External volume for Iceberg. ALLOW_WRITES because Snowflake manages the
--     table and writes metadata and data files into archive/.
CREATE OR REPLACE EXTERNAL VOLUME EXVOL_QC
  STORAGE_LOCATIONS = (
    (
      NAME = 'qc-archive'
      STORAGE_PROVIDER = 'AZURE'
      STORAGE_BASE_URL = 'azure://<SA>.blob.core.windows.net/archive/'
      AZURE_TENANT_ID = '<TENANT_ID>'
    )
  )
  ALLOW_WRITES = TRUE;

-- 1b. Storage integration for the three read-only containers.
CREATE OR REPLACE STORAGE INTEGRATION SI_QC_AZURE
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'AZURE'
  AZURE_TENANT_ID = '<TENANT_ID>'
  ENABLED = TRUE
  STORAGE_ALLOWED_LOCATIONS = (
    'azure://<SA>.blob.core.windows.net/landing/',
    'azure://<SA>.blob.core.windows.net/external/',
    'azure://<SA>.blob.core.windows.net/docs/'
  );

-- 1c. Notification integration: Event Grid drops BlobCreated messages on the
--     queue, Snowpipe reads them. This is what makes auto-ingest automatic.
CREATE OR REPLACE NOTIFICATION INTEGRATION NI_QC_SNOWPIPE
  ENABLED = TRUE
  TYPE = QUEUE
  NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE
  AZURE_STORAGE_QUEUE_PRIMARY_URI = 'https://<SA>.queue.core.windows.net/snowpipe-queue'
  AZURE_TENANT_ID = '<TENANT_ID>';

-- =============================================================================
-- STEP 2 — consent and RBAC. Repeat for EACH of the three objects.
--
--   DESC EXTERNAL VOLUME EXVOL_QC;
--   DESC INTEGRATION SI_QC_AZURE;
--   DESC INTEGRATION NI_QC_SNOWPIPE;
--
-- For each:
--   1. Read AZURE_CONSENT_URL and AZURE_MULTI_TENANT_APP_NAME from the output.
--      (For the external volume these are inside STORAGE_LOCATIONS - expand it.)
--   2. Open the consent URL, sign in as tenant admin, accept.
--   3. Azure portal -> Microsoft Entra ID -> Enterprise applications.
--      Search the part of AZURE_MULTI_TENANT_APP_NAME BEFORE the underscore.
--      That prefix is the app name; the suffix is a request id and will not match.
--   4. Assign the role, scoped to the container (not the whole account):
--
--        archive           Storage Blob Data Contributor   (Iceberg writes)
--        landing           Storage Blob Data Reader
--        external          Storage Blob Data Reader
--        docs              Storage Blob Data Reader
--        snowpipe-queue    Storage Queue Data Contributor
--
-- RBAC PROPAGATION TAKES ABOUT 5 MINUTES. If verification fails immediately
-- after granting, wait before debugging. This is the single most common way to
-- lose half an hour on this step.
-- =============================================================================
DESC EXTERNAL VOLUME EXVOL_QC;
DESC INTEGRATION SI_QC_AZURE;
DESC INTEGRATION NI_QC_SNOWPIPE;

-- =============================================================================
-- STEP 3 — THE GATE. Do not proceed past a failure here.
-- Every Iceberg step in the project depends on this returning success.
-- =============================================================================
SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('EXVOL_QC');

-- =============================================================================
-- STEP 4 — stages and file formats, once the gate is green
-- =============================================================================
USE DATABASE QCOMMERCE;
USE SCHEMA LAND;

CREATE OR REPLACE FILE FORMAT FF_JSON_GZ
  TYPE = JSON COMPRESSION = GZIP STRIP_OUTER_ARRAY = FALSE
  COMMENT = 'clickstream NDJSON.gz';

CREATE OR REPLACE FILE FORMAT FF_CSV
  TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL')
  COMMENT = '3PL settlement CSV';

CREATE OR REPLACE FILE FORMAT FF_PARQUET
  TYPE = PARQUET COMMENT = 'order backfill';

-- External stages, one per container.
CREATE OR REPLACE STAGE STG_LANDING
  STORAGE_INTEGRATION = SI_QC_AZURE
  URL = 'azure://<SA>.blob.core.windows.net/landing/'
  FILE_FORMAT = FF_JSON_GZ
  COMMENT = 'Snowpipe auto-ingest source';

CREATE OR REPLACE STAGE STG_EXTERNAL
  STORAGE_INTEGRATION = SI_QC_AZURE
  URL = 'azure://<SA>.blob.core.windows.net/external/'
  FILE_FORMAT = FF_CSV
  COMMENT = 'external table over 3PL settlement';

-- Directory table on the docs container, for complaint PDFs.
CREATE OR REPLACE STAGE STG_DOCS
  STORAGE_INTEGRATION = SI_QC_AZURE
  URL = 'azure://<SA>.blob.core.windows.net/docs/'
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'directory table, unstructured';

-- Internal named stage. Auto-ingest does not work on internal stages, which is
-- exactly why mechanism 5 (Snowpipe REST) exists to contrast with mechanism 4.
CREATE OR REPLACE STAGE STG_INTERNAL
  FILE_FORMAT = FF_JSON_GZ
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'internal stage for the REST-triggered pipe';

-- =============================================================================
-- STEP 5 — verify
-- =============================================================================
SHOW STAGES IN SCHEMA QCOMMERCE.LAND;
SHOW FILE FORMATS IN SCHEMA QCOMMERCE.LAND;
LIST @STG_LANDING;    -- empty is correct, it proves the credential works
LIST @STG_DOCS;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP STAGE IF EXISTS QCOMMERCE.LAND.STG_LANDING;
-- DROP STAGE IF EXISTS QCOMMERCE.LAND.STG_EXTERNAL;
-- DROP STAGE IF EXISTS QCOMMERCE.LAND.STG_DOCS;
-- DROP STAGE IF EXISTS QCOMMERCE.LAND.STG_INTERNAL;
-- DROP INTEGRATION IF EXISTS NI_QC_SNOWPIPE;
-- DROP INTEGRATION IF EXISTS SI_QC_AZURE;
-- DROP EXTERNAL VOLUME IF EXISTS EXVOL_QC;

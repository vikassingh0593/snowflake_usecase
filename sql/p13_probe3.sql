-- =============================================================================
-- PART 13 / STEP 0c — the listing manifest, and a hole that predates sharing.
--
-- WHAT THE SECOND RUN ESTABLISHED.
--
--   SECURE_OBJECTS_ONLY = FALSE   accepted. The familiar rule that a share
--                                 cannot carry a non-secure view is a
--                                 SHARE-LEVEL DEFAULT, not a law.
--   SERVE.ORDER_RISK in a share   accepted once the property was off. So BOTH
--                                 the policy-protected base table AND a
--                                 non-secure view inheriting that policy can be
--                                 put into a share, and nothing on the provider
--                                 side objects to either.
--   CREATE EXTERNAL LISTING       parsed, resolved the share, and reached YAML
--                                 validation. Listings are available and no
--                                 provider profile was demanded. The failure
--                                 was my manifest: "\\n" in the Python source
--                                 is a literal backslash-n, so the whole thing
--                                 was one line and YAML stopped at the second
--                                 colon. STEP 1 builds it with chr(10).
--
-- THE QUESTION THIS RAISED, WHICH IS BIGGER THAN SHARING.
--
-- SERVE.SLA_STORE_HOUR_AGG is a DYNAMIC TABLE. It refreshes under its owner's
-- role and stores the result. GOV.RAP_STORE filters MART.FCT_ORDER -- it cannot
-- filter rows that have already been computed and written down.
--
-- Part 12 verified by signing in as QC_ANALYST that the policy works: 1,977
-- rows of SERVE.ORDER_RISK against ACCOUNTADMIN's 4,777, across 3 stores of 8.
-- ORDER_RISK is a VIEW over FCT_ORDER, so the filter applies at read time.
--
-- SERVE.SLA_BY_STORE_HOUR is a view over the MATERIALISED aggregate. The same
-- role should see all eight stores through it.
--
-- IF THAT HOLDS, MATERIALISATION LAUNDERS THE ROW FILTER, and it has been true
-- since Part 11 -- before anything was shared, and independent of Part 13
-- entirely. The share is not the hole; the share is how the hole would leave
-- the account.
--
-- STEP 2 tests it the only way Part 12 accepted as evidence: by assuming the
-- role, not by reading a grant. Same object, same session, two paths.
--
-- ON COST. Read-only. Two role switches and four counts over 7,626 and 4,777
-- rows. Estimated spend: ~0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p13:probe3';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — the listing, with a manifest that is actually YAML.
-- =============================================================================
CREATE OR REPLACE PROCEDURE QCOMMERCE.LAB.TMP_P13_LISTING()
RETURNS TABLE (QUESTION STRING, VERDICT STRING, DETAIL STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.types import StringType, StructField, StructType

SCHEMA = StructType([
    StructField("QUESTION", StringType()),
    StructField("VERDICT", StringType()),
    StructField("DETAIL", StringType()),
])

# Built from character codes so neither the dollar pair nor a backslash escape
# has to survive a heredoc, a Python string literal and a SQL parser intact.
# Two runs were lost to exactly those two problems.
DQ = chr(36) * 2
NL = chr(10)
SHARE = "TMP_P13_LISTING_SHARE"

MANIFEST = NL.join([
    "title: QCOMMERCE probe listing",
    "subtitle: capability probe, not for publication",
    "description: Created by sql/p13_probe3.sql to establish whether this",
    "  account can define a listing. Dropped in the same call.",
    "listing_terms:",
    "  type: OFFLINE",
])


def run(session):
    rows = []

    def attempt(q, stmt, summarise=None):
        try:
            res = session.sql(stmt).collect()
        except Exception as e:
            rows.append((q, "ERROR", str(e).replace(NL, " ")[:400]))
            return None
        detail = "{} row(s)".format(len(res)) if summarise is None else summarise(res)
        rows.append((q, "OK", str(detail)[:400]))
        return res

    def drop(stmt):
        try:
            session.sql(stmt).collect()
        except Exception:
            pass

    made = attempt("share for the listing", "CREATE OR REPLACE SHARE " + SHARE)
    if made is not None:
        attempt("database usage", "GRANT USAGE ON DATABASE QCOMMERCE TO SHARE " + SHARE)
        attempt("schema usage", "GRANT USAGE ON SCHEMA QCOMMERCE.SERVE TO SHARE " + SHARE)
        attempt("secure view", "GRANT SELECT ON VIEW QCOMMERCE.SERVE.V_CUSTOMER TO SHARE " + SHARE)
        attempt(
            "create listing, valid YAML manifest",
            "CREATE EXTERNAL LISTING TMP_P13_PROBE_LISTING SHARE " + SHARE
            + " AS " + DQ + MANIFEST + DQ + " REVIEW = TRUE",
        )
        attempt("listing state", "SHOW LISTINGS LIKE 'TMP_P13%'",
                lambda r: "{} row(s)".format(len(r)))
        drop("DROP LISTING TMP_P13_PROBE_LISTING")
        drop("DROP SHARE " + SHARE)
        rows.append(("cleanup", "OK", "listing and share dropped"))

    return session.create_dataframe(rows, schema=SCHEMA)
$$;

CALL QCOMMERCE.LAB.TMP_P13_LISTING();

DROP PROCEDURE IF EXISTS QCOMMERCE.LAB.TMP_P13_LISTING();

-- =============================================================================
-- STEP 2 — does materialisation launder the row filter?
--
-- Verified by role, not by grant. Part 8 established that reading a grant
-- proves nothing and Part 12 established that reading what SHOW says is
-- attached proves nothing either. The only evidence this project accepts for a
-- protection is signing in as the role it is supposed to constrain.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE QCOMMERCE;

SELECT 'ACCOUNTADMIN'                        AS WHOAMI,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.SLA_BY_STORE_HOUR) AS STORES_VIA_AGGREGATE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM SERVE.ORDER_RISK)        AS STORES_VIA_VIEW,
       (SELECT COUNT(*)                   FROM SERVE.ORDER_RISK)        AS ROWS_VIA_VIEW;

USE ROLE QC_ANALYST;

SELECT 'QC_ANALYST'                          AS WHOAMI,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM QCOMMERCE.SERVE.SLA_BY_STORE_HOUR) AS STORES_VIA_AGGREGATE,
       (SELECT COUNT(DISTINCT STORE_CODE) FROM QCOMMERCE.SERVE.ORDER_RISK)        AS STORES_VIA_VIEW,
       (SELECT COUNT(*)                   FROM QCOMMERCE.SERVE.ORDER_RISK)        AS ROWS_VIA_VIEW;

USE ROLE ACCOUNTADMIN;
USE DATABASE QCOMMERCE;

-- The check. STORES_VIA_VIEW should differ between the two roles -- that is
-- RAP_STORE working, as Part 12 measured. STORES_VIA_AGGREGATE reading 8 for
-- BOTH roles is the finding: the same protected fact, reached two ways, one of
-- which the policy never sees.
SELECT 'materialisation_launders_the_filter' AS CHECK_NAME,
       'compare the two rows above'          AS HOW_TO_READ,
       'equal aggregate counts across roles means the filter did not travel' AS WHAT_IT_MEANS;

-- =============================================================================
-- STEP 3 — nothing left behind.
-- =============================================================================
SHOW SHARES LIKE 'TMP_P13%';
SHOW LISTINGS LIKE 'TMP_P13%';
SHOW PROCEDURES LIKE 'TMP_P13%' IN SCHEMA QCOMMERCE.LAB;

-- =============================================================================
-- PART 13 / STEP 0b — clean up after the first probe, then chase what it found.
--
-- WHAT THE FIRST RUN ESTABLISHED.
--
--   managed accounts        SHOW works, returns 0. The command exists; whether
--                           CREATE is permitted on a trial is still untested.
--   shares                  create, grant, drop all work
--   application packages    create and drop work; ADD VERSION complained about
--                           the STAGE, not the syntax, so Native Apps are here
--   listings                inconclusive -- my delimiter was wrong, not theirs
--   org accounts            ACCOUNTADMIN lacks MANAGE ORGANIZATION ACCOUNTS
--   SQL API precondition    SVC_CI and SVC_KAFKA both SERVICE, keypair true
--
-- THE FINDING. A base table carrying a row access policy WAS accepted into a
-- share:
--
--   GRANT SELECT ON TABLE QCOMMERCE.MART.FCT_ORDER TO SHARE ...   OK
--   SHOW GRANTS TO SHARE  ->  QCOMMERCE.MART.FCT_ORDER present
--
-- A refusal was expected. This makes sharing the THIRD consequence of
-- GOV.RAP_STORE and the quietest of the three:
--
--   materialized view   refused at CREATE          found immediately
--   dynamic table       accepted, then stopped     found two days later
--   share               accepted, and stays so     found never
--
-- PREDICTION, EXPLICITLY UNVERIFIED. The policy evaluates in the CONSUMER's
-- role context, where nothing matches the store mapping, so a consumer should
-- see an empty table indefinitely with no error raised on either side. That is
-- mechanism, not measurement. Confirming it needs a consumer account, which is
-- the reader account not yet created. Recorded as a prediction so that if a
-- reader account is ever built, this is the first thing it tests.
--
-- THE SHARE PROPERTY NOBODY MENTIONS. The non-secure view was refused with:
--
--   090838: Non-secure object can only be granted to shares with
--           "secure_objects_only" property set to false.
--
-- So "a share cannot carry a non-secure view" is not a law, it is a SHARE-LEVEL
-- PROPERTY WITH A DEFAULT. STEP 3 tests whether it can be turned off here, and
-- whether the non-secure view then goes in. If it does, the protection story
-- changes: SERVE.ORDER_RISK inherits RAP_STORE, and a share that accepts it
-- would carry a view whose filter the consumer cannot satisfy either.
--
-- WHY THE LAST RUN ABORTED, WHICH IS ITSELF THE LESSON.
--
--   090105: Cannot perform DROP. This session does not have a current database.
--
-- AN APPLICATION PACKAGE IS A DATABASE-SHAPED OBJECT. Creating one makes it the
-- session's current database the way CREATE DATABASE does, and dropping it
-- leaves the session with none. The unqualified DROP PROCEDURE that followed
-- had nothing to resolve against, so it failed, the file aborted, and the two
-- cleanup SHOW statements never ran. Everything after an application package
-- is fully qualified from here on, and the USE DATABASE is re-issued rather
-- than assumed.
--
-- ON COST. Metadata only. Estimated spend: ~0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p13:probe2';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — clean up what the aborted run left behind.
-- Fully qualified, because the reason the last one failed was that it was not.
-- =============================================================================
DROP PROCEDURE IF EXISTS QCOMMERCE.LAB.TMP_P13_PROBE();

SHOW SHARES LIKE 'TMP_P13%';

SHOW APPLICATION PACKAGES LIKE 'TMP_P13%';

SHOW PROCEDURES LIKE 'TMP_P13%' IN SCHEMA QCOMMERCE.LAB;

-- =============================================================================
-- STEP 2 — SHOW ORGANIZATION ACCOUNTS outside a procedure.
-- The refusal named owner's rights explicitly, which is a procedure-context
-- artefact worth ruling out before recording a privilege as absent.
-- =============================================================================
SHOW ORGANIZATION ACCOUNTS;

-- =============================================================================
-- STEP 3 — the two questions the first run raised.
-- =============================================================================
CREATE OR REPLACE PROCEDURE QCOMMERCE.LAB.TMP_P13_PROBE2()
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

# The listing manifest wants Snowflake's own dollar-quoting, and this procedure
# body is itself dollar-quoted, so a literal pair anywhere in this file would
# end the body early -- the exact bug that cost two runs in Part 12. Building it
# from a character code keeps the pair out of the file text entirely.
DQ = chr(36) * 2

OPEN_SHARE = "TMP_P13_OPEN_SHARE"
SECURE_SHARE = "TMP_P13_SECURE_SHARE"


def run(session):
    rows = []

    def classify(msg):
        low = msg.lower()
        if "not available" in low or "not enabled" in low or "not supported" in low:
            return "GATED"
        if "unsupported feature" in low:
            return "NO SUCH FEATURE"
        if "syntax error" in low:
            return "NO SUCH SYNTAX"
        # Deliberately last and narrow. The first probe classified
        # "Stage ... does not exist or not authorized" as NO PRIVILEGE by
        # matching the second half, when the first half was the actual answer.
        if "insufficient privileges" in low:
            return "NO PRIVILEGE"
        return "ERROR"

    def attempt(q, stmt, summarise=None):
        try:
            res = session.sql(stmt).collect()
        except Exception as e:
            msg = str(e).replace("\n", " ")
            rows.append((q, classify(msg), msg[:350]))
            return None
        detail = "{} row(s)".format(len(res)) if summarise is None else summarise(res)
        rows.append((q, "OK", str(detail)[:350]))
        return res

    def drop(stmt):
        try:
            session.sql(stmt).collect()
        except Exception:
            pass

    def granted(res):
        out = []
        for r in res:
            try:
                d = r.as_dict()
            except Exception:
                continue
            flat = {str(k).strip('"').lower(): v for k, v in d.items()}
            if "name" in flat:
                out.append(str(flat["name"]))
        return "{}: {}".format(len(out), ", ".join(out[:20])) if out else "none"

    # -- Q1. Can a share be created that accepts non-secure objects? ----------
    made = attempt(
        "share with secure_objects_only = false",
        "CREATE OR REPLACE SHARE " + OPEN_SHARE + " SECURE_OBJECTS_ONLY = FALSE",
    )
    if made is not None:
        attempt("open share: database usage",
                "GRANT USAGE ON DATABASE QCOMMERCE TO SHARE " + OPEN_SHARE)
        attempt("open share: schema usage",
                "GRANT USAGE ON SCHEMA QCOMMERCE.SERVE TO SHARE " + OPEN_SHARE)
        # The view that was refused last time. If it goes in now, the rule is a
        # property rather than a law -- and the share then carries a view whose
        # row filter no consumer role can satisfy.
        attempt("open share: NON-secure view inheriting RAP_STORE",
                "GRANT SELECT ON VIEW QCOMMERCE.SERVE.ORDER_RISK TO SHARE " + OPEN_SHARE)
        attempt("open share: contents", "SHOW GRANTS TO SHARE " + OPEN_SHARE, granted)
        drop("DROP SHARE " + OPEN_SHARE)
        rows.append(("open share: cleanup", "OK", "dropped"))

    # -- Q2. Does a listing work once the delimiter is right? -----------------
    # A listing needs a live share. A provider profile is created in Snowsight
    # rather than SQL, so a complaint about the profile is the good outcome
    # here: it means the command and the grammar are both present and only a
    # one-time UI step is missing.
    made2 = attempt("share for the listing",
                    "CREATE OR REPLACE SHARE " + SECURE_SHARE)
    if made2 is not None:
        attempt("listing share: database usage",
                "GRANT USAGE ON DATABASE QCOMMERCE TO SHARE " + SECURE_SHARE)
        attempt("listing share: schema usage",
                "GRANT USAGE ON SCHEMA QCOMMERCE.SERVE TO SHARE " + SECURE_SHARE)
        attempt("listing share: secure view",
                "GRANT SELECT ON VIEW QCOMMERCE.SERVE.V_CUSTOMER TO SHARE " + SECURE_SHARE)

        manifest = (
            "title: QCOMMERCE probe listing\\n"
            "subtitle: capability probe, not for publication\\n"
            "description: Created by sql/p13_probe2.sql to establish whether "
            "this account can define a listing at all. Dropped in the same call.\\n"
            "listing_terms:\\n  type: OFFLINE\\n"
        )
        attempt(
            "create listing, correct delimiter",
            "CREATE EXTERNAL LISTING TMP_P13_PROBE_LISTING SHARE " + SECURE_SHARE
            + " AS " + DQ + manifest + DQ + " REVIEW = TRUE",
        )
        drop("DROP LISTING TMP_P13_PROBE_LISTING")
        drop("DROP SHARE " + SECURE_SHARE)
        rows.append(("listing: cleanup", "OK", "listing and share dropped"))

    return session.create_dataframe(rows, schema=SCHEMA)
$$;

CALL QCOMMERCE.LAB.TMP_P13_PROBE2();

DROP PROCEDURE IF EXISTS QCOMMERCE.LAB.TMP_P13_PROBE2();

-- Empty is the pass, on all three.
SHOW SHARES LIKE 'TMP_P13%';
SHOW LISTINGS LIKE 'TMP_P13%';
SHOW PROCEDURES LIKE 'TMP_P13%' IN SCHEMA QCOMMERCE.LAB;

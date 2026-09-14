-- =============================================================================
-- PART 13 / STEP 0 — which outbound surfaces this account actually has.
--
-- §13 designs four ways the platform's output reaches someone outside it:
--
--   reader account    CREATE MANAGED ACCOUNT. A whole Snowflake account the
--                     consumer logs into, with compute billed to us.
--   private listing   Provider Studio. A share with a storefront on it.
--   Native App        an application package wrapping the Streamlit console.
--   SQL API           POST /api/v2/statements with a key-pair JWT. No SQL here;
--                     it is an HTTP call and belongs in a shell script.
--
-- This account has refused Cortex and external access on tier grounds and has
-- twice misdescribed a capability it does have. Neither a SHOW nor a grant
-- listing settles any of this. Every attempt below is made, isolated, and
-- cleaned up.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO.
--
-- It does not run CREATE MANAGED ACCOUNT. A reader account is the only object
-- in Part 13 that can spend real money: it is a full account whose compute
-- bills back to this one, and it is created with a password that would then
-- exist. The probe tests whether the PRIVILEGE and the COMMAND exist by
-- listing, and the creation itself is a separate decision with its own yes.
--
-- THE PART 12 BRIDGE, AND THE REASON THIS PROBE IS MORE THAN A CHECKLIST.
--
-- Shares have two rules that collide with everything Part 12 attached:
-- a share cannot carry a non-secure view, and a table under a row access
-- policy is a question nobody documents from both sides. Part 12 already
-- produced two consequences of GOV.RAP_STORE that no single feature's
-- documentation mentions -- materialized views refused, dynamic tables
-- accepted-then-stopped. STEP 2 asks whether sharing is the third:
--
--   MART.FCT_ORDER     a base table carrying RAP_STORE
--   SERVE.ORDER_RISK   a NON-secure view that inherits it
--   SERVE.V_CUSTOMER   a SECURE view over masked columns
--
-- Three grants to one throwaway share. The expected answers are refuse, refuse,
-- allow -- and if the first one ALLOWS, that is the finding, because it would
-- mean a share can carry a table whose row filter the consumer's role cannot
-- satisfy.
--
-- ON COST. Shares, application packages and listings are metadata objects and
-- cost nothing to create or drop. No warehouse work beyond the procedure
-- itself. Estimated spend: ~0.02 credits, nearly all of it the suspend tail.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p13:probe';
USE DATABASE QCOMMERCE;

CREATE OR REPLACE PROCEDURE LAB.TMP_P13_PROBE()
RETURNS TABLE (SURFACE STRING, VERDICT STRING, DETAIL STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.types import StringType, StructField, StructType

SCHEMA = StructType([
    StructField("SURFACE", StringType()),
    StructField("VERDICT", StringType()),
    StructField("DETAIL", StringType()),
])

SHARE = "TMP_P13_PROBE_SHARE"
APPPKG = "TMP_P13_PROBE_APP"


def run(session):
    rows = []

    def col(row, *names):
        """Case- and quote-insensitive column fetch.

        SHOW output arrives with lowercase quoted identifiers and this project
        has now lost three runs to guessing a spelling. Normalising removes the
        category rather than betting on it.
        """
        try:
            d = row.as_dict()
        except Exception:
            return None
        flat = {}
        for k, v in d.items():
            flat[str(k).strip('"').lower()] = v
        for n in names:
            if n in flat:
                return flat[n]
        return None

    def classify(msg):
        low = msg.lower()
        if "not available" in low or "not enabled" in low or "not supported" in low:
            return "GATED"
        if "unknown function" in low or "unsupported feature" in low:
            return "NO SUCH FEATURE"
        if "insufficient privileges" in low or "not authorized" in low:
            return "NO PRIVILEGE"
        if "syntax error" in low:
            return "NO SUCH SYNTAX"
        return "ERROR"

    def attempt(surface, stmt, summarise=None):
        try:
            res = session.sql(stmt).collect()
        except Exception as e:
            msg = str(e).replace("\n", " ")
            rows.append((surface, classify(msg), msg[:350]))
            return None
        if summarise is None:
            detail = "{} row(s)".format(len(res))
        else:
            try:
                detail = summarise(res)
            except Exception as e:
                detail = "{} row(s); summary failed: {}".format(len(res), e)
        rows.append((surface, "OK", str(detail)[:350]))
        return res

    def names_of(res, *cols):
        out = []
        for r in res:
            v = col(r, *cols)
            if v is not None:
                out.append(str(v))
        if not out:
            return "{} row(s), no name column".format(len(res))
        return "{}: {}".format(len(out), ", ".join(out[:30]))

    def drop(stmt):
        try:
            session.sql(stmt).collect()
        except Exception:
            pass

    # -- STEP 1. What already exists, read-only -------------------------------
    # MANAGED ACCOUNTS is listed rather than created. If the command itself is
    # absent the reader-account surface is gone and nothing later depends on it.
    attempt("list managed accounts", "SHOW MANAGED ACCOUNTS",
            lambda r: names_of(r, "name"))
    attempt("list shares", "SHOW SHARES",
            lambda r: names_of(r, "name"))
    attempt("list application packages", "SHOW APPLICATION PACKAGES",
            lambda r: names_of(r, "name"))
    attempt("list listings", "SHOW LISTINGS",
            lambda r: names_of(r, "name", "global_name"))
    attempt("list organization accounts", "SHOW ORGANIZATION ACCOUNTS",
            lambda r: names_of(r, "account_name", "name"))

    # -- STEP 2. Sharing, and what Part 12 attached to the objects ------------
    share_ok = attempt("create share", "CREATE OR REPLACE SHARE " + SHARE) is not None
    if share_ok:
        attempt("share: grant database usage",
                "GRANT USAGE ON DATABASE QCOMMERCE TO SHARE " + SHARE)
        attempt("share: grant schema usage",
                "GRANT USAGE ON SCHEMA QCOMMERCE.SERVE TO SHARE " + SHARE)

        # The three that matter. Expected refuse, refuse, allow.
        attempt("share: base table under a row access policy",
                "GRANT SELECT ON TABLE QCOMMERCE.MART.FCT_ORDER TO SHARE " + SHARE)
        attempt("share: NON-secure view inheriting that policy",
                "GRANT SELECT ON VIEW QCOMMERCE.SERVE.ORDER_RISK TO SHARE " + SHARE)
        attempt("share: SECURE view over masked columns",
                "GRANT SELECT ON VIEW QCOMMERCE.SERVE.V_CUSTOMER TO SHARE " + SHARE)

        attempt("share: what it ended up carrying",
                "SHOW GRANTS TO SHARE " + SHARE,
                lambda r: names_of(r, "name"))

        # A listing needs a live share, so this has to happen before the drop.
        # A listing also needs a provider profile, which is created in Snowsight
        # rather than in SQL -- and the error text is the whole answer, because
        # a missing profile reads differently from a gated feature and only one
        # of the two is fixable from here.
        attempt("create listing",
                "CREATE EXTERNAL LISTING TMP_P13_PROBE_LISTING "
                "SHARE " + SHARE + " AS $x$ title: probe $x$ REVIEW")
        drop("DROP LISTING TMP_P13_PROBE_LISTING")

        drop("DROP SHARE " + SHARE)
        rows.append(("share: cleanup", "OK", "share and listing dropped"))

    # -- STEP 3. Native App framework -----------------------------------------
    pkg_ok = attempt("create application package",
                     "CREATE APPLICATION PACKAGE " + APPPKG) is not None
    if pkg_ok:
        # Deliberately aimed at a stage that does not exist. The point is to
        # separate "ADD VERSION is not a thing here" from "the stage is not
        # there": a complaint about the stage proves the syntax and the feature
        # both work, which is what a Native App would need next. Building a real
        # version would mean staging a manifest and a setup script, and that is
        # the build rather than the probe.
        attempt("application package: add a version",
                "ALTER APPLICATION PACKAGE " + APPPKG + " ADD VERSION v1 "
                "USING '@QCOMMERCE.APP.NO_SUCH_STAGE'")
        drop("DROP APPLICATION PACKAGE " + APPPKG)
        rows.append(("application package: cleanup", "OK", "dropped"))

    # -- STEP 4. The SQL API's precondition ------------------------------------
    # No SQL can test the endpoint. What SQL can test is whether the service
    # user it would authenticate as still holds a key pair, since the JWT is
    # signed with it and nothing else in the project has touched SVC_CI since
    # Part 1.
    attempt("SQL API: service users and key pairs",
            "SHOW USERS LIKE 'SVC%'",
            lambda r: "; ".join(
                "{} type={} keypair={}".format(
                    col(x, "name"),
                    col(x, "type"),
                    col(x, "has_rsa_public_key"),
                ) for x in r))

    return session.create_dataframe(rows, schema=SCHEMA)
$$;

CALL LAB.TMP_P13_PROBE();

DROP PROCEDURE IF EXISTS QCOMMERCE.LAB.TMP_P13_PROBE();

-- Nothing left behind. Empty results here are the pass.
SHOW SHARES LIKE 'TMP_P13%';
SHOW APPLICATION PACKAGES LIKE 'TMP_P13%';

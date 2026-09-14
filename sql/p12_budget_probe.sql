-- =============================================================================
-- PART 12 / ADDENDUM — does this account have a budget, and what is it called?
--
-- The account budget has been the one outstanding cost control since Part 3.
-- A budget was created through Snowsight and does not appear on the Budgets
-- page, and the documented method call
--
--     SELECT SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_LIMIT();
--
-- fails with "Unknown user-defined function". That error has two readings and
-- they need different responses:
--
--   (a) the method name is wrong -- the budget exists and is reachable under
--       some other name, and nothing is missing;
--   (b) the instance SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET was never created --
--       what Snowsight accepted was a custom budget, or nothing at all.
--
-- Part 12 already produced the rule this file obeys: the first probe reported
-- DATA_METRIC_SCHEDULE as available because the ALTER succeeded -- it tested
-- the statement, not the outcome. So this file does not call a method it
-- guessed. It ENUMERATES first (which classes exist, which instances exist,
-- which methods the class declares) and only then calls what it found, with
-- every call isolated so an unknown name costs one row rather than the file.
--
-- The discriminator between (a) and (b) is step 7: if a method name fails on
-- ACCOUNT_ROOT_BUDGET and succeeds on some other budget instance, the name is
-- right and the instance is missing. If it fails on both, the name is wrong.
--
-- ON COST. Every statement here is metadata or a scalar method call. Nothing
-- is created except one procedure in LAB, dropped on the last line. Estimated
-- WH_TRANSFORM_XS spend including the 60-second auto-suspend tail: ~0.02
-- credits.
--
-- READ-ONLY against the budget. This file never sets a spending limit and
-- never links a notification integration. Both are decisions, not diagnosis.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:budget_probe';
USE DATABASE QCOMMERCE;

CREATE OR REPLACE PROCEDURE LAB.TMP_BUDGET_PROBE()
RETURNS TABLE (ITEM STRING, VERDICT STRING, DETAIL STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.types import StringType, StructField, StructType

SCHEMA = StructType([
    StructField("ITEM", StringType()),
    StructField("VERDICT", StringType()),
    StructField("DETAIL", StringType()),
])


def run(session):
    rows = []

    def col(row, *names):
        """Fetch a column case- and quote-insensitively.

        SHOW output arrives with lowercase quoted identifiers, and Part 12 lost
        two runs to guessing which spelling a particular SHOW uses -- cluster_by
        against clustering_key. Normalising here removes the whole category.
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

    def attempt(item, stmt, summarise=None):
        """Run one statement. Record what came back, or the error verbatim.

        Returns the result rows on success and None on failure, so later steps
        can branch on what actually exists rather than on what should.
        """
        try:
            res = session.sql(stmt).collect()
        except Exception as e:
            msg = str(e).replace("\n", " ")
            rows.append((item, "ERROR", msg[:400]))
            return None
        if summarise is None:
            detail = "{} row(s)".format(len(res))
        else:
            try:
                detail = summarise(res)
            except Exception as e:
                detail = "{} row(s); summary failed: {}".format(len(res), e)
        rows.append((item, "OK", str(detail)[:400]))
        return res

    def names_of(res, *cols):
        out = []
        for r in res:
            v = col(r, *cols)
            if v is not None:
                out.append(str(v))
        if not out:
            return "{} row(s), no name column".format(len(res))
        return "{}: {}".format(len(out), ", ".join(out[:40]))

    def scalar(res):
        if not res:
            return "no rows"
        first = res[0]
        try:
            vals = list(first.as_dict().values())
        except Exception:
            return str(first)
        return " | ".join(str(v) for v in vals)[:400]

    # -- 1. what classes exist at all -----------------------------------------
    # If BUDGET is not among them the feature is absent from this account and
    # every later step is noise. This is the tier-gate question.
    attempt(
        "classes in account",
        "SHOW CLASSES IN ACCOUNT",
        lambda res: names_of(res, "name"),
    )

    # -- 2. which budget instances exist ---------------------------------------
    # THE DECISIVE STEP for reading (b). ACCOUNT_ROOT_BUDGET present here means
    # the instance exists and only the method name was wrong.
    inst = attempt(
        "instances of SNOWFLAKE.CORE.BUDGET",
        "SHOW INSTANCES OF CLASS SNOWFLAKE.CORE.BUDGET",
        lambda res: names_of(res, "name"),
    )

    # -- 3. what methods does the class declare -------------------------------
    # Two spellings attempted because neither is verified. Whichever answers
    # gives the real method names and ends the guessing for good.
    attempt(
        "DESC CLASS budget",
        "DESC CLASS SNOWFLAKE.CORE.BUDGET",
        lambda res: names_of(res, "name", "method_name", "property"),
    )
    attempt(
        "SHOW METHODS in class",
        "SHOW METHODS IN CLASS SNOWFLAKE.CORE.BUDGET",
        lambda res: names_of(res, "name", "method_name"),
    )

    # -- 4. the SHOW surface ---------------------------------------------------
    # Custom budgets are expected here. Whether the account root budget also
    # appears is unverified, and its absence proves nothing on its own.
    attempt(
        "SHOW BUDGETS IN ACCOUNT",
        "SHOW BUDGETS IN ACCOUNT",
        lambda res: names_of(res, "name"),
    )

    # -- 5. the catalogue surface ---------------------------------------------
    attempt(
        "ACCOUNT_USAGE.BUDGETS",
        "SELECT COUNT(*) AS N FROM SNOWFLAKE.ACCOUNT_USAGE.BUDGETS",
        scalar,
    )

    # -- 6. method calls against the account root budget -----------------------
    # Every name that has been seen in documentation or inferred, each isolated.
    # The point is not that one works; it is which ones fail and how.
    root = "SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET"
    root_methods = [
        "GET_SPENDING_LIMIT()",
        "SHOW_BUDGET_DETAILS()",
        "GET_LINKED_NOTIFICATION_INTEGRATION()",
        "GET_SPENDING_HISTORY()",
    ]
    for m in root_methods:
        attempt(
            "root!{}".format(m),
            "SELECT {}!{}".format(root, m),
            scalar,
        )
    # GET_SPENDING_HISTORY may be a table function rather than a scalar; the
    # scalar form above will have said so. Attempt the table form regardless.
    attempt(
        "root!GET_SPENDING_HISTORY as table",
        "SELECT * FROM TABLE({}!GET_SPENDING_HISTORY())".format(root),
        lambda res: "{} row(s)".format(len(res)),
    )

    # -- 7. the discriminator --------------------------------------------------
    # Run the same method names against whatever instances step 2 found. A name
    # that fails on the root and succeeds here is a correct name pointing at a
    # missing instance -- reading (b). Failing on both means the name is wrong
    # -- reading (a) -- and step 3's output has the right one.
    others = []
    if inst:
        for r in inst:
            nm = col(r, "name")
            db = col(r, "database_name")
            sc = col(r, "schema_name")
            if nm is None:
                continue
            fq = ".".join([p for p in (db, sc, nm) if p])
            if fq.upper() != root:
                others.append(fq)
    if not others:
        rows.append((
            "discriminator",
            "SKIP",
            "no budget instance other than the root to compare against",
        ))
    else:
        for fq in others[:3]:
            attempt(
                "{}!GET_SPENDING_LIMIT()".format(fq),
                "SELECT {}!GET_SPENDING_LIMIT()".format(fq),
                scalar,
            )

    # -- 8. what is actually guarding spend right now --------------------------
    # Whatever the budget turns out to be, the resource monitor is the control
    # that has been in force for twelve parts, and it sees warehouse compute
    # only. Reprinted here so the answer is on one screen.
    attempt(
        "resource monitors",
        "SHOW RESOURCE MONITORS",
        lambda res: "; ".join(
            "{} credit_quota={} used={} level={}".format(
                col(r, "name"),
                col(r, "credit_quota"),
                col(r, "used_credits"),
                col(r, "level"),
            )
            for r in res
        ),
    )

    return session.create_dataframe(rows, schema=SCHEMA)
$$;

CALL LAB.TMP_BUDGET_PROBE();

DROP PROCEDURE IF EXISTS LAB.TMP_BUDGET_PROBE();

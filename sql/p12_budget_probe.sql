-- =============================================================================
-- PART 12 / ADDENDUM — the account budget, reached by CALL rather than SELECT.
--
-- WHAT THE FIRST RUN OF THIS FILE ESTABLISHED.
--
-- BUDGET is the first of thirteen classes SHOW CLASSES returns, so the feature
-- is present on this account -- unlike Cortex and external access, this is not
-- a tier gate. But three surfaces that the documentation implies exist do not
-- exist here:
--
--   DESC CLASS SNOWFLAKE.CORE.BUDGET   ->  Unsupported feature 'CLASS'
--   SHOW BUDGETS IN ACCOUNT            ->  Object type or Class 'BUDGETS'
--                                          does not exist or not authorized
--   SNOWFLAKE.ACCOUNT_USAGE.BUDGETS    ->  does not exist or not authorized
--
-- There is no introspection surface and no catalogue view. The class instance
-- methods are the only way in, which is also the likeliest reason the Snowsight
-- Budgets page shows nothing: there is no SHOW command behind it to populate.
--
-- WHY THE METHOD CALLS FAILED, AND IT WAS NOT THE METHOD NAMES.
--
-- All four methods, called as SELECT instance!METHOD(), returned
--
--     Unknown user-defined function SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!X
--
-- which reads as "no such method" and means something narrower. The fifth
-- attempt is what gave it away. SELECT * FROM TABLE(instance!METHOD())
-- returned
--
--     Invalid stored procedure 'GET_SPENDING_HISTORY' in FROM clause:
--     Return table must declare a nonzero number of columns
--
-- It RESOLVED the name -- as a stored procedure -- and then objected to the
-- return shape. That is the same zero-column TABLE() signature that broke
-- ROW_COUNT in p12_quality_lineage.sql. So the instance exists, the methods
-- exist, and SELECT was the wrong verb: SELECT looks for a user-defined
-- function, finds no function by that name, and reports the absence of a
-- function as though it were the absence of the method.
--
-- Class instance methods here are PROCEDURES. They are called with CALL.
--
-- The lesson generalises past budgets, and it is the same one Part 12 kept
-- teaching: an error message names what the parser looked for, not what is
-- missing. "Unknown user-defined function" was never evidence about the
-- budget.
--
-- STRUCTURE. The four calls run twice on purpose.
--
--   Pass 1, inside a procedure, one try/except each. snow sql -f aborts the
--   whole file on the first error, and the point is to learn about four things
--   rather than the first one. Output is one summary table, truncated.
--
--   Pass 2, as plain top-level statements, LAST in the file and after the
--   procedure is dropped. These print the full result tables rather than a
--   400-character summary -- GET_SPENDING_HISTORY in particular is a table,
--   not a scalar. If one of them aborts the run, everything of value has
--   already printed and nothing is left behind.
--
-- ON COST. Metadata and method calls only. One procedure created in LAB and
-- dropped before pass 2. Estimated WH_TRANSFORM_XS spend including the
-- 60-second auto-suspend tail: ~0.02 credits.
--
-- READ-ONLY. Nothing here calls SET_SPENDING_LIMIT or links a notification
-- integration. Both are decisions and both need a yes first.
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

ROOT = "SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET"


def run(session):
    rows = []

    def col(row, *names):
        """Fetch a column case- and quote-insensitively.

        SHOW output arrives with lowercase quoted identifiers, and Part 12 lost
        two runs to guessing which spelling a given SHOW uses -- cluster_by
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

    def render(res, limit=3):
        """Flatten up to `limit` rows into one line.

        A method whose shape is unknown is easier to read as values than as a
        row count, and the shapes here are genuinely unknown -- there is no
        DESC CLASS on this account to ask.
        """
        if not res:
            return "no rows"
        parts = []
        for r in res[:limit]:
            try:
                d = r.as_dict()
                parts.append(", ".join("{}={}".format(k, v) for k, v in d.items()))
            except Exception:
                parts.append(str(r))
        tail = "" if len(res) <= limit else " ... +{} more".format(len(res) - limit)
        return "{} row(s): ".format(len(res)) + " | ".join(parts) + tail

    def attempt(item, stmt, summarise=render):
        """Run one statement. Record what came back, or the error verbatim."""
        try:
            res = session.sql(stmt).collect()
        except Exception as e:
            rows.append((item, "ERROR", str(e).replace("\n", " ")[:400]))
            return None
        try:
            detail = summarise(res)
        except Exception as e:
            detail = "{} row(s); summary failed: {}".format(len(res), e)
        rows.append((item, "OK", str(detail)[:400]))
        return res

    # -- the four methods, by CALL ---------------------------------------------
    # Ordered by what each settles. GET_SPENDING_LIMIT answers the original
    # question -- did the limit created in Snowsight actually land. The rest
    # describe what landed.
    for method in (
        "GET_SPENDING_LIMIT",
        "SHOW_BUDGET_DETAILS",
        "GET_LINKED_NOTIFICATION_INTEGRATION",
        "GET_SPENDING_HISTORY",
    ):
        attempt(
            "CALL root!{}()".format(method),
            "CALL {}!{}()".format(ROOT, method),
        )

    # -- what is actually guarding spend right now -----------------------------
    # RM_POC has been the only control in force for twelve parts and it reads
    # level=WAREHOUSE, which is the gap restated: serverless refresh, pipes and
    # search optimization are not in its used_credits figure. Reprinted so the
    # budget answer and the monitor answer land on one screen.
    attempt(
        "resource monitors",
        "SHOW RESOURCE MONITORS",
        lambda res: "; ".join(
            "{} quota={} used={} level={}".format(
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

-- =============================================================================
-- PASS 2 — the same four calls, unsummarised, last in the file.
--
-- Everything above has already printed and the procedure is already dropped,
-- so an abort here costs nothing. Full tables, not 400-character summaries.
-- =============================================================================
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_LIMIT();

CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SHOW_BUDGET_DETAILS();

CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_LINKED_NOTIFICATION_INTEGRATION();

CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_HISTORY();

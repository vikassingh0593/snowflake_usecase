-- =============================================================================
-- PART 12 / ADDENDUM — Finding 1 is wrong, and the billing record proved it.
--
-- ARCHITECTURE §1 Finding 1 has said since Part 0 that AI functions are
-- unavailable on this account, generalising from nine refusals to
--
--     "Everything downstream of an LLM goes with it."
--
-- CORTEX_AI_FUNCTIONS_USAGE_HISTORY contradicts it:
--
--   FUNCTION_NAME     QUERY_TAG   TOKENS  CREDITS      IS_COMPLETED
--   AI_AGG            p00:probe   163     0.00030155   True
--   AI_SUMMARIZE_AGG  p00:probe   181     0.00033485   True
--
-- Both ran on 2026-09-08, under this project's own Part 0 probe tag, and both
-- completed with real token counts and real credits. The nine functions in
-- Finding 1 are not the whole AI surface, and AI_AGG and AI_SUMMARIZE_AGG were
-- never among them. The gate is PER FUNCTION, not per account.
--
-- WHY THIS WENT UNNOTICED FOR SIX PARTS. The probe recorded a verdict per
-- function and the finding recorded a conclusion about the account. Nine
-- refusals became "the AI layer is gone", and two successes in the same run
-- did not survive the summary. The correction did not come from re-reading the
-- probe; it came from the billing, which has no opinion about what should
-- work. THE SPEND IS A HARDER TEST THAN THE PROBE.
--
-- WHAT IT COSTS IF IT IS TRUE. Part 10 classified 300 complaints with TF-IDF
-- and logistic regression because Cortex was believed unavailable, and reported
-- 5.41% accuracy on genuinely novel phrasings -- below a uniform guess over ten
-- classes. An LLM does not share that failure mode. If AI_CLASSIFY is gated but
-- AI_AGG is not, the write-up's "built without Cortex, which is unavailable" is
-- true only of the specific function, and Part 10 has a comparison it never ran.
--
-- WHAT THIS FILE DOES. Re-tests every AI function by calling it, one isolated
-- attempt each, on a two-row literal input. No table is read, nothing is
-- written, and each attempt records the verdict and the error verbatim.
--
-- ON COST. Each successful call bills tokens. The observed rate is ~0.0003
-- credits for ~170 tokens, and the inputs below are shorter than that. Worst
-- case with every function available: well under 0.01 credits, plus ~0.02 for
-- the warehouse. Failed calls bill nothing.
--
-- THIS FILE SPENDS AI CREDITS ON PURPOSE. That is the measurement.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:ai_recheck';
USE DATABASE QCOMMERCE;

CREATE OR REPLACE PROCEDURE LAB.TMP_AI_RECHECK()
RETURNS TABLE (FUNC STRING, VERDICT STRING, DETAIL STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.types import StringType, StructField, StructType

SCHEMA = StructType([
    StructField("FUNC", StringType()),
    StructField("VERDICT", StringType()),
    StructField("DETAIL", StringType()),
])

# Two short complaint-shaped strings. Literals rather than CORE.COMPLAINT so
# the test says something about the function and nothing about the data, and so
# the token count stays small enough that a full sweep is a rounding error.
A = "'Order arrived 20 minutes late and the ice cream had melted.'"
B = "'Two items were missing from my bag and nobody answered support.'"

# Each entry is one function and one statement that exercises it. The aggregate
# forms need a row source, so they get a two-row inline VALUES.
CASES = [
    ("AI_AGG",
     "SELECT AI_AGG(t.c, 'Summarise the common complaint') AS R "
     "FROM (SELECT {} AS c UNION ALL SELECT {}) t".format(A, B)),
    ("AI_SUMMARIZE_AGG",
     "SELECT AI_SUMMARIZE_AGG(t.c) AS R "
     "FROM (SELECT {} AS c UNION ALL SELECT {}) t".format(A, B)),
    ("AI_COMPLETE",
     "SELECT AI_COMPLETE('claude-3-5-sonnet', 'Reply with the word OK') AS R"),
    ("AI_CLASSIFY",
     "SELECT AI_CLASSIFY({}, ['LATE_DELIVERY','MISSING_ITEM']) AS R".format(A)),
    ("AI_FILTER",
     "SELECT AI_FILTER('Is this about a late delivery? ' || {}) AS R".format(A)),
    ("AI_EXTRACT",
     "SELECT AI_EXTRACT({}, ['how late was it']) AS R".format(A)),
    ("AI_SIMILARITY",
     "SELECT AI_SIMILARITY({}, {}) AS R".format(A, B)),
    ("AI_EMBED",
     "SELECT ARRAY_SIZE(AI_EMBED('snowflake-arctic-embed-m', {})::ARRAY) AS R".format(A)),
    ("AI_SENTIMENT",
     "SELECT AI_SENTIMENT({}) AS R".format(A)),
    ("SNOWFLAKE.CORTEX.SENTIMENT",
     "SELECT SNOWFLAKE.CORTEX.SENTIMENT({}) AS R".format(A)),
    ("SNOWFLAKE.CORTEX.SUMMARIZE",
     "SELECT SNOWFLAKE.CORTEX.SUMMARIZE({}) AS R".format(A)),
    ("SNOWFLAKE.CORTEX.COMPLETE",
     "SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-7b', 'Reply with OK') AS R"),
    ("SNOWFLAKE.CORTEX.EMBED_TEXT_768",
     "SELECT ARRAY_SIZE(SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m', {})::ARRAY) AS R".format(A)),
    ("SNOWFLAKE.CORTEX.TRANSLATE",
     "SELECT SNOWFLAKE.CORTEX.TRANSLATE({}, 'en', 'de') AS R".format(A)),
]


def run(session):
    rows = []
    for name, stmt in CASES:
        try:
            res = session.sql(stmt).collect()
        except Exception as e:
            msg = str(e).replace("\n", " ")
            # The distinction that matters. A tier gate says "not available for
            # trial accounts"; a moved API says "Unknown function"; a wrong
            # argument list says something else again. Part 12 learned this the
            # expensive way with SYSTEM$CLASSIFY -- an error message names what
            # the parser looked for, not what is missing.
            low = msg.lower()
            if "not available" in low or "not enabled" in low or "not supported" in low:
                verdict = "GATED"
            elif "unknown function" in low or "does not exist" in low:
                verdict = "NO SUCH FUNCTION"
            else:
                verdict = "ERROR"
            rows.append((name, verdict, msg[:300]))
            continue
        val = ""
        if res:
            try:
                val = " | ".join(str(v) for v in res[0].as_dict().values())
            except Exception:
                val = str(res[0])
        rows.append((name, "WORKS", val[:300]))
    return session.create_dataframe(rows, schema=SCHEMA)
$$;

CALL LAB.TMP_AI_RECHECK();

DROP PROCEDURE IF EXISTS LAB.TMP_AI_RECHECK();

-- What the sweep just spent, and what the two Part 0 calls spent, side by side.
-- ACCOUNT_USAGE lags up to three hours, so this run will not appear yet -- the
-- 09-08 rows will. Re-run this select tomorrow to see the sweep itself.
SELECT FUNCTION_NAME,
       QUERY_TAG,
       ROUND(CREDITS, 8) AS CREDITS,
       IS_COMPLETED,
       START_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
ORDER BY START_TIME DESC;

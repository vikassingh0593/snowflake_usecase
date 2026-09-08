#!/usr/bin/env python3
"""Generates sql/p0_probe.sql — Part 0 read-only feature probe.

Probe definitions live here so the emitted SQL stays consistent. The emitted file
uses only EXECUTE IMMEDIATE + assignment + EXCEPTION WHEN OTHER: no arrays, no
loops, no cursors, so there is minimal Snowflake Scripting syntax risk on a block
that cannot be tested before it is handed over.

Every probe is READ-ONLY. Nothing here creates, alters or drops an object.
"""

# (probe_name, sql_returning_anything) — failure of the statement is the signal.
# Single quotes inside the SQL are doubled because each becomes a SQL literal.
PROBES = [
    # --- SQL surface -------------------------------------------------------
    ("sql.asof_join",
     "WITH a AS (SELECT 1 k, TO_TIMESTAMP_NTZ(0) t), "
     "b AS (SELECT 1 k, TO_TIMESTAMP_NTZ(0) t) "
     "SELECT COUNT(*) FROM a ASOF JOIN b MATCH_CONDITION(a.t >= b.t) ON a.k = b.k"),
    ("sql.match_recognize",
     "SELECT COUNT(*) FROM (SELECT 1 id, 1 v UNION ALL SELECT 1, 2) "
     "MATCH_RECOGNIZE(PARTITION BY id ORDER BY v MEASURES COUNT(*) c "
     "ONE ROW PER MATCH PATTERN(x+) DEFINE x AS TRUE)"),
    ("sql.geography_st_distance",
     "SELECT ST_DISTANCE(TO_GEOGRAPHY(''POINT(77.02 28.45)''), "
     "TO_GEOGRAPHY(''POINT(77.03 28.46)''))"),
    ("sql.st_dwithin",
     "SELECT ST_DWITHIN(TO_GEOGRAPHY(''POINT(77.02 28.45)''), "
     "TO_GEOGRAPHY(''POINT(77.03 28.46)''), 5000)"),
    ("sql.h3_latlng_to_cell",  "SELECT H3_LATLNG_TO_CELL(28.45, 77.02, 8)"),
    ("sql.h3_grid_disk",       "SELECT ARRAY_SIZE(H3_GRID_DISK(H3_LATLNG_TO_CELL(28.45,77.02,8), 1))"),
    ("sql.h3_cell_to_boundary","SELECT H3_CELL_TO_BOUNDARY(H3_LATLNG_TO_CELL(28.45,77.02,8))"),
    ("sql.vector_type",        "SELECT [1,2,3]::VECTOR(FLOAT,3)"),
    ("sql.vector_cosine",
     "SELECT VECTOR_COSINE_SIMILARITY([1,2,3]::VECTOR(FLOAT,3), [1,2,4]::VECTOR(FLOAT,3))"),
    ("sql.qualify",
     "SELECT * FROM (SELECT 1 x) QUALIFY ROW_NUMBER() OVER (ORDER BY x) = 1"),
    ("sql.generator_uniform",
     "SELECT COUNT(*) FROM (SELECT SEQ4() s, UNIFORM(0,1,RANDOM()) u "
     "FROM TABLE(GENERATOR(ROWCOUNT => 10)))"),
    ("sql.recursive_cte",
     "WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM t WHERE n < 3) "
     "SELECT COUNT(*) FROM t"),
    ("sql.tablesample",
     "SELECT COUNT(*) FROM (SELECT SEQ4() s FROM TABLE(GENERATOR(ROWCOUNT=>100))) SAMPLE (10 ROWS)"),

    # --- Cortex AISQL (each call is one tiny row; keep inputs short) -------
    ("cortex.ai_complete",     "SELECT LEFT(AI_COMPLETE(''claude-4-sonnet'', ''say ok''), 20)"),
    ("cortex.ai_classify",
     "SELECT AI_CLASSIFY(''parcel arrived late'', [''DELIVERY'',''QUALITY''])"),
    ("cortex.ai_filter",       "SELECT AI_FILTER(''is this about delivery: parcel late'')"),
    ("cortex.ai_agg",
     "SELECT AI_AGG(c, ''summarise in five words'') FROM (SELECT ''late parcel'' c "
     "UNION ALL SELECT ''cold food'')"),
    ("cortex.ai_summarize_agg",
     "SELECT AI_SUMMARIZE_AGG(c) FROM (SELECT ''late parcel'' c UNION ALL SELECT ''cold food'')"),
    ("cortex.ai_extract",
     "SELECT AI_EXTRACT(text => ''order 918273 was late'', "
     "responseFormat => {''order_id'': ''the order number''})"),
    ("cortex.ai_similarity",   "SELECT AI_SIMILARITY(''late parcel'', ''parcel was late'')"),
    ("cortex.ai_embed",        "SELECT ARRAY_SIZE(AI_EMBED(''snowflake-arctic-embed-m-v1.5'', ''late'')::ARRAY)"),
    ("cortex.sentiment",       "SELECT SNOWFLAKE.CORTEX.SENTIMENT(''the parcel was very late'')"),
    ("cortex.embed_text_768",
     "SELECT ARRAY_SIZE(SNOWFLAKE.CORTEX.EMBED_TEXT_768(''snowflake-arctic-embed-m'', ''late'')::ARRAY)"),
    ("cortex.complete_legacy", "SELECT LEFT(SNOWFLAKE.CORTEX.COMPLETE(''mistral-large2'', ''say ok''), 20)"),

    # --- Metadata layers ---------------------------------------------------
    ("meta.object_dependencies",
     "SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES LIMIT 1"),
    ("meta.query_attribution_history",
     "SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY LIMIT 1"),
    ("meta.warehouse_metering",
     "SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY LIMIT 1"),
    ("meta.metering_history",
     "SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY LIMIT 1"),
    ("meta.organization_usage",
     "SELECT COUNT(*) FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY LIMIT 1"),
    ("meta.information_schema",
     "SELECT COUNT(*) FROM SNOWFLAKE.INFORMATION_SCHEMA.DATABASES"),
    ("meta.access_history_absent_expected",
     "SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY LIMIT 1"),

    # --- Enterprise gates: these SHOULD fail on Standard. FAIL = expected. --
    ("gate.materialized_view_expect_fail",
     "SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY LIMIT 1"),
    ("gate.data_metric_functions_expect_fail",
     "SHOW DATA METRIC FUNCTIONS IN ACCOUNT"),
]

HEADER = """-- sql/p0_probe.sql  —  PART 0 FEATURE PROBE (generated by scripts/gen_p0_probe.py)
-- =============================================================================
-- READ-ONLY. Creates nothing, alters nothing, drops nothing.
-- Run in a Snowsight worksheet as ACCOUNTADMIN. Paste the output back.
--
-- COST: needs an XS warehouse running for ~2-4 minutes.
--       Warehouse:  ~0.03-0.07 credits.
--       Cortex:     ~11 single-row AI calls, tokens are trivial; well inside the
--                   ~10 credit/day trial AI cap. UNVERIFIED but not a risk here.
--
-- ORDER: run SECTION 1, then SECTION 2, then SECTION 3. Paste all three outputs.
-- =============================================================================

ALTER SESSION SET QUERY_TAG = 'p00:probe';

-- =============================================================================
-- SECTION 1 — identity and account shape. Cannot fail. Run All is safe here.
-- =============================================================================
SELECT CURRENT_ORGANIZATION_NAME()  AS org,
       CURRENT_ACCOUNT()            AS account,
       CURRENT_REGION()             AS region,
       CURRENT_VERSION()            AS sf_version,
       CURRENT_ROLE()               AS role,
       CURRENT_WAREHOUSE()          AS wh,
       CURRENT_TIMESTAMP()          AS probed_at;

-- Credits consumed so far.
SELECT SUM(credits_used) AS credits_used_to_date
FROM   SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY;

-- -----------------------------------------------------------------------------
-- SECTION 1b — OPTIONAL, run separately. Needs ORGADMIN. If USE ROLE ORGADMIN is
-- rejected, skip the rest of 1b and read the edition off Snowsight ->
-- Admin -> Accounts instead. Do not let this abort the run.
-- -----------------------------------------------------------------------------
USE ROLE ORGADMIN;
SHOW ORGANIZATION ACCOUNTS;
SELECT "account_name", "edition", "snowflake_region", "created_on", "account_url"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));
USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- SECTION 2 — object-surface probes. SHOW never errors on a missing feature,
-- it returns zero rows, so Run All is safe for this whole section.
-- Record ROW COUNT and whether the command itself was rejected.
-- =============================================================================
SHOW WAREHOUSES;
SHOW RESOURCE MONITORS;
SHOW INTEGRATIONS;
SHOW EXTERNAL VOLUMES;
SHOW DYNAMIC TABLES IN ACCOUNT;
SHOW ICEBERG TABLES IN ACCOUNT;
SHOW HYBRID TABLES IN ACCOUNT;
SHOW STREAMLITS IN ACCOUNT;
SHOW CORTEX SEARCH SERVICES IN ACCOUNT;
SHOW SEMANTIC VIEWS IN ACCOUNT;
SHOW AGENTS IN ACCOUNT;                    -- Snowflake CoWork agents
SHOW GIT REPOSITORIES IN ACCOUNT;
SHOW DBT PROJECTS IN ACCOUNT;
SHOW APPLICATION PACKAGES;
SHOW MANAGED ACCOUNTS;                     -- reader accounts
SHOW SHARES;
SHOW TAGS IN ACCOUNT;
SHOW ALERTS IN ACCOUNT;
SHOW NOTEBOOKS IN ACCOUNT;
SHOW CLASSES IN SNOWFLAKE.ML;              -- FORECAST / ANOMALY_DETECTION / TOP_INSIGHTS
SHOW FUNCTIONS LIKE 'AI\\\\_%' IN SCHEMA SNOWFLAKE.CORTEX;
SHOW DATABASE ROLES IN DATABASE SNOWFLAKE; -- expect CORTEX_USER / AI_FUNCTIONS_USER

-- AISQL needs the USE AI FUNCTIONS account privilege (granted to PUBLIC by
-- default) PLUS the CORTEX_USER or AI_FUNCTIONS_USER database role.
SHOW GRANTS TO ROLE PUBLIC;
SELECT "privilege", "granted_on", "name"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE  "privilege" ILIKE '%AI%' OR "name" ILIKE '%CORTEX%';
SHOW GRANTS TO ROLE ACCOUNTADMIN;
SELECT "privilege", "granted_on", "name"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE  "privilege" ILIKE '%AI%' OR "name" ILIKE '%CORTEX%';

-- =============================================================================
-- SECTION 3 — function probes. A missing function is a COMPILE error, so each
-- probe is wrapped in its own exception block. This whole section is ONE
-- statement: put the cursor in it and run it once.
--
-- Output is a single text cell, one line per probe: name=VERDICT|detail
-- Copy the whole cell and paste it back.
--
-- If this block itself errors (Snowflake Scripting is not enabled, or a syntax
-- rejection), fall back to sql/p0_probe_flat.sql and run those one-liners
-- individually.
-- =============================================================================
EXECUTE IMMEDIATE $$
DECLARE
  r STRING DEFAULT '';
BEGIN
"""

FOOTER = """  RETURN r;
END;
$$;
"""

BLOCK = """  BEGIN
    EXECUTE IMMEDIATE '{sql}';
    r := r || '{name}=OK\\n';
  EXCEPTION WHEN OTHER THEN
    r := r || '{name}=FAIL|' || REPLACE(LEFT(SQLERRM, 140), '\\n', ' ') || '\\n';
  END;
"""

FLAT_HEADER = """-- sql/p0_probe_flat.sql — fallback for SECTION 3 of sql/p0_probe.sql
-- Use only if the scripting block in p0_probe.sql is rejected.
-- Run these ONE AT A TIME (cursor in the statement, Ctrl/Cmd+Enter).
-- A statement that errors = that feature is unavailable; record the error text.
-- READ-ONLY.

ALTER SESSION SET QUERY_TAG = 'p00:probe';

"""


def main() -> None:
    body = "".join(
        BLOCK.format(name=name, sql=sql) for name, sql in PROBES
    )
    with open("sql/p0_probe.sql", "w") as fh:
        fh.write(HEADER + body + FOOTER)

    flat = [FLAT_HEADER]
    for name, sql in PROBES:
        flat.append(f"-- [{name}]\n{sql.replace(chr(39) * 2, chr(39))};\n\n")
    with open("sql/p0_probe_flat.sql", "w") as fh:
        fh.write("".join(flat))

    print(f"wrote sql/p0_probe.sql and sql/p0_probe_flat.sql ({len(PROBES)} probes)")


if __name__ == "__main__":
    main()

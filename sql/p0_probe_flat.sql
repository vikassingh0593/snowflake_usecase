-- sql/p0_probe_flat.sql — fallback for SECTION 3 of sql/p0_probe.sql
-- Use only if the scripting block in p0_probe.sql is rejected.
-- Run these ONE AT A TIME (cursor in the statement, Ctrl/Cmd+Enter).
-- A statement that errors = that feature is unavailable; record the error text.
-- READ-ONLY.

ALTER SESSION SET QUERY_TAG = 'p00:probe';

-- [show.warehouses]
SHOW WAREHOUSES;

-- [show.resource_monitors]
SHOW RESOURCE MONITORS;

-- [show.integrations]
SHOW INTEGRATIONS;

-- [show.external_volumes]
SHOW EXTERNAL VOLUMES;

-- [show.dynamic_tables]
SHOW DYNAMIC TABLES IN ACCOUNT;

-- [show.iceberg_tables]
SHOW ICEBERG TABLES IN ACCOUNT;

-- [show.hybrid_tables]
SHOW HYBRID TABLES IN ACCOUNT;

-- [show.streamlits]
SHOW STREAMLITS IN ACCOUNT;

-- [show.cortex_search_services]
SHOW CORTEX SEARCH SERVICES IN ACCOUNT;

-- [show.semantic_views]
SHOW SEMANTIC VIEWS IN ACCOUNT;

-- [show.agents_cowork]
SHOW AGENTS IN ACCOUNT;

-- [show.git_repositories]
SHOW GIT REPOSITORIES IN ACCOUNT;

-- [show.dbt_projects]
SHOW DBT PROJECTS IN ACCOUNT;

-- [show.application_packages]
SHOW APPLICATION PACKAGES;

-- [show.managed_accounts_reader]
SHOW MANAGED ACCOUNTS;

-- [show.shares]
SHOW SHARES;

-- [show.tags]
SHOW TAGS IN ACCOUNT;

-- [show.alerts]
SHOW ALERTS IN ACCOUNT;

-- [show.notebooks]
SHOW NOTEBOOKS IN ACCOUNT;

-- [show.ml_classes]
SHOW CLASSES IN SNOWFLAKE.ML;

-- [show.cortex_ai_functions]
SHOW FUNCTIONS LIKE 'AI\_%' IN SCHEMA SNOWFLAKE.CORTEX;

-- [show.snowflake_db_roles]
SHOW DATABASE ROLES IN DATABASE SNOWFLAKE;

-- [show.budgets_class]
SHOW CLASSES IN SNOWFLAKE.CORE;

-- [show.data_metric_fns_expect_fail]
SHOW DATA METRIC FUNCTIONS IN ACCOUNT;

-- [sql.asof_join]
WITH a AS (SELECT 1 k, TO_TIMESTAMP_NTZ(0) t), b AS (SELECT 1 k, TO_TIMESTAMP_NTZ(0) t) SELECT COUNT(*) FROM a ASOF JOIN b MATCH_CONDITION(a.t >= b.t) ON a.k = b.k;

-- [sql.match_recognize]
SELECT COUNT(*) FROM (SELECT 1 id, 1 v UNION ALL SELECT 1, 2) MATCH_RECOGNIZE(PARTITION BY id ORDER BY v MEASURES COUNT(*) c ONE ROW PER MATCH PATTERN(x+) DEFINE x AS TRUE);

-- [sql.geography_st_distance]
SELECT ST_DISTANCE(TO_GEOGRAPHY('POINT(77.02 28.45)'), TO_GEOGRAPHY('POINT(77.03 28.46)'));

-- [sql.st_dwithin]
SELECT ST_DWITHIN(TO_GEOGRAPHY('POINT(77.02 28.45)'), TO_GEOGRAPHY('POINT(77.03 28.46)'), 5000);

-- [sql.h3_latlng_to_cell]
SELECT H3_LATLNG_TO_CELL(28.45, 77.02, 8);

-- [sql.h3_grid_disk]
SELECT ARRAY_SIZE(H3_GRID_DISK(H3_LATLNG_TO_CELL(28.45,77.02,8), 1));

-- [sql.h3_cell_to_boundary]
SELECT H3_CELL_TO_BOUNDARY(H3_LATLNG_TO_CELL(28.45,77.02,8));

-- [sql.vector_type]
SELECT [1,2,3]::VECTOR(FLOAT,3);

-- [sql.vector_cosine]
SELECT VECTOR_COSINE_SIMILARITY([1,2,3]::VECTOR(FLOAT,3), [1,2,4]::VECTOR(FLOAT,3));

-- [sql.qualify]
SELECT * FROM (SELECT 1 x) QUALIFY ROW_NUMBER() OVER (ORDER BY x) = 1;

-- [sql.generator_uniform]
SELECT COUNT(*) FROM (SELECT SEQ4() s, UNIFORM(0,1,RANDOM()) u FROM TABLE(GENERATOR(ROWCOUNT => 10)));

-- [sql.recursive_cte]
WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM t WHERE n < 3) SELECT COUNT(*) FROM t;

-- [sql.tablesample]
SELECT COUNT(*) FROM (SELECT SEQ4() s FROM TABLE(GENERATOR(ROWCOUNT=>100))) SAMPLE (10 ROWS);

-- [cortex.ai_complete]
SELECT LEFT(AI_COMPLETE('claude-4-sonnet', 'say ok'), 20);

-- [cortex.ai_classify]
SELECT AI_CLASSIFY('parcel arrived late', ['DELIVERY','QUALITY']);

-- [cortex.ai_filter]
SELECT AI_FILTER('is this about delivery: parcel late');

-- [cortex.ai_agg]
SELECT AI_AGG(c, 'summarise in five words') FROM (SELECT 'late parcel' c UNION ALL SELECT 'cold food');

-- [cortex.ai_summarize_agg]
SELECT AI_SUMMARIZE_AGG(c) FROM (SELECT 'late parcel' c UNION ALL SELECT 'cold food');

-- [cortex.ai_extract]
SELECT AI_EXTRACT(text => 'order 918273 was late', responseFormat => {'order_id': 'the order number'});

-- [cortex.ai_similarity]
SELECT AI_SIMILARITY('late parcel', 'parcel was late');

-- [cortex.ai_embed]
SELECT ARRAY_SIZE(AI_EMBED('snowflake-arctic-embed-m-v1.5', 'late')::ARRAY);

-- [cortex.sentiment]
SELECT SNOWFLAKE.CORTEX.SENTIMENT('the parcel was very late');

-- [cortex.embed_text_768]
SELECT ARRAY_SIZE(SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m', 'late')::ARRAY);

-- [cortex.complete_legacy]
SELECT LEFT(SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', 'say ok'), 20);

-- [meta.object_dependencies]
SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES LIMIT 1;

-- [meta.query_attribution_history]
SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY LIMIT 1;

-- [meta.warehouse_metering]
SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY LIMIT 1;

-- [meta.metering_history]
SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY LIMIT 1;

-- [meta.organization_usage]
SELECT COUNT(*) FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY LIMIT 1;

-- [meta.information_schema]
SELECT COUNT(*) FROM SNOWFLAKE.INFORMATION_SCHEMA.DATABASES;

-- [meta.access_history_absent_expected]
SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY LIMIT 1;

-- [gate.materialized_view_expect_fail]
SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY LIMIT 1;

-- [gate.data_metric_functions_expect_fail]
SHOW DATA METRIC FUNCTIONS IN ACCOUNT;


# Part 0 — feature probe

**Nothing is designed around a feature until it has a verdict here.** Fill every
`Verdict` cell before starting Part 1. Read-only metadata queries only — no DDL, no DML.

Verdict vocabulary: `GA` · `PuPr` (public preview) · `PrPr` (private preview) ·
`NOT AVAILABLE` · `ENTERPRISE-GATED` · `UNVERIFIED` (probe inconclusive).

Probed on: `<date>` · Account `AWTTGVH-OLB61128` · Standard trial · `AWS_US_WEST_2`

---

## A. Baseline — run these first

```sql
SELECT CURRENT_ACCOUNT(), CURRENT_ORGANIZATION_NAME(), CURRENT_REGION(),
       CURRENT_VERSION(), CURRENT_ROLE();
SELECT SYSTEM$BEHAVIOR_CHANGE_BUNDLE_STATUS('<bundle>');   -- per bundle, if needed
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN ACCOUNT;
SHOW REGIONS;
```

| Check | Expected | Actual | Verdict |
|---|---|---|---|
| Edition | Standard | | |
| Region | `AWS_US_WEST_2` | | |
| Snowflake version | ≥ 9.x post-Summit-2026 | | |
| Credit balance / days remaining | ~200 / 120 | | |
| `ORGANIZATION_USAGE` readable | yes on trial | | |

---

## B. Post-Summit-2026 features (brief §16)

Availability on a Standard trial is **UNVERIFIED** for all of these until probed.

| Feature | Value here | Priority | Probe | Verdict | Notes |
|---|---|---|---|---|---|
| **Semantic View Autopilot / Semantic Studio** | auto-generates the semantic view — saves an hour | **Try first** | Snowsight → AI & ML → Semantic; `SHOW SEMANTIC VIEWS`; check for an Autopilot/generate entry point | | |
| **Iceberg v3** (reported GA) | deletion vectors, row lineage. Document v2 vs v3 | Add if available | `SHOW PARAMETERS LIKE '%ICEBERG%'`; docs check on `CREATE ICEBERG TABLE … FORMAT_VERSION` | | |
| **Cortex Sense** | unifies data + business definitions + operational knowledge for agents; reported ~83% accuracy | Try | Snowsight nav; `SHOW ...` in `SNOWFLAKE.CORTEX`; docs check | | |
| **Snowflake CoWork** (GA, was Snowflake Intelligence) | full agent over the semantic view, beside Cortex Analyst in the Ask tab | Try | Snowsight left nav; `SHOW AGENTS`; account feature flag | | |
| **Horizon Context** | context layer in Horizon Catalog | Probe | Snowsight → Horizon / Catalog | | |
| **Streaming Feature Views** | real-time feature serving — upgrades the Feature Store work | Probe | `snowflake.ml.feature_store` version + docs | | |
| **Native A/B testing on model versions** | slots into Model Registry | Probe | `snowflake-ml-python` version; registry API surface | | |
| **Snowsight Pipeline Builder** | visual pipeline view, good screenshots | PrPr | Snowsight nav | | |
| **Observe by Snowflake** | cost governance — strengthens the credit report | Probe | Snowsight → Admin → Cost / Observability | | |
| **AI Agent Identity** (GA) | agent governance | Add if enabled | `SHOW ...` under account admin; docs check | | |
| **Horizon AI Guardrails** | agent governance | Add if enabled | Snowsight → Horizon | | |
| **Multi-Party Approval** | agent governance | Add if enabled | account policy surface | | |
| **Snowflake CoCo** (was Cortex Code) | — | **Unavailable** — excluded from trial accounts, needs its own separate trial | none | `NOT AVAILABLE` | pre-decided, do not spend probe time |
| **Adaptive Compute** | auto-sizing warehouses | **Skip** — wrong risk on a fixed balance | none | `SKIP` | pre-decided |
| **Cortex Training** (LLM fine-tuning) | — | **Skip** — unpredictable cost | none | `SKIP` | pre-decided |

---

## C. Capabilities the build already depends on — confirm, don't assume

A `NOT AVAILABLE` in this table forces a design change in the named part, so probe all
of them in Part 0.

| Capability | Needed by | Probe | Verdict | Notes |
|---|---|---|---|---|
| `AI_CLASSIFY`, `AI_EXTRACT`, `AI_FILTER`, `AI_AGG`, `AI_SUMMARIZE_AGG`, `SENTIMENT` | Part 10 | `SHOW FUNCTIONS LIKE 'AI\\_%' IN SCHEMA SNOWFLAKE.CORTEX;` then one call on `LIMIT 1` | | region-gated; `AWS_US_WEST_2` expected fine |
| `AI_PARSE_DOCUMENT` | Part 10 (mechanism 10) | function list + docs; needs a stage file to test | | |
| `AI_EMBED` / `EMBED_TEXT_768` + `VECTOR` type + `VECTOR_COSINE_SIMILARITY` | Part 10 | `SELECT [1,2,3]::VECTOR(FLOAT,3);` | | |
| **Cortex Search** service | Part 10 | `SHOW CORTEX SEARCH SERVICES;` (empty ≠ unavailable — check `CREATE` privilege + docs) | | serverless; watch the meter |
| **Cortex Analyst** | Parts 10, 11 | Snowsight → AI & ML → Analyst; semantic view support | | |
| **Snowflake Copilot** | Part 10 (screenshot) | Snowsight worksheet Copilot pane | | |
| `SNOWFLAKE.ML.FORECAST` / `ANOMALY_DETECTION` / `TOP_INSIGHTS` | Part 10 | `SHOW CLASSES IN SNOWFLAKE.ML;` | | on Standard as of last check — confirm |
| **Snowpark ML** (`OneHotEncoder`, `StandardScaler`, `Pipeline`) | Part 9 | `pip show snowflake-ml-python` locally + a no-op fit in-warehouse | | |
| **Model Registry** | Part 9 | `snowflake.ml.registry.Registry` against `LAB` | | |
| **Feature Store** | Part 9 | `snowflake.ml.feature_store.FeatureStore` init in `LAB` | | |
| **Vectorized (pandas) UDF** | Part 9 | `SHOW FUNCTIONS`; a trivial vectorized UDF | | |
| **Snowpark pandas (Modin)** | Part 9 | `import modin.pandas` in the venv | | |
| **Dynamic tables** (max 2, lag ≥ 60 min) | Part 8 | `SHOW DYNAMIC TABLES;` + `CREATE` privilege | | Standard-supported, confirm |
| **Iceberg tables + external volume** | Part 5 (mechanism 9) | `SYSTEM$VERIFY_EXTERNAL_VOLUME` after Part 1 | | hard gate |
| **External network access** (network rule + EAI + secret) | Part 5 (mechanism 11) | `SHOW INTEGRATIONS`; create privilege as `ACCOUNTADMIN` | | |
| **Snowpipe Streaming SDK / Kafka connector v4** | Part 3 | connector jar v4.x pinned; channel open against `RAW` | | v4 = high-performance architecture |
| **`ASOF JOIN`** | Part 8 | `SELECT … ASOF JOIN` on two 1-row CTEs | | |
| **`MATCH_RECOGNIZE`** | Part 8 | one-row pattern query | | |
| **`GEOGRAPHY`, `ST_DISTANCE`, `ST_DWITHIN`** | Part 8 | `SELECT ST_DISTANCE(TO_GEOGRAPHY('POINT(0 0)'), TO_GEOGRAPHY('POINT(1 1)'));` | | |
| **H3** (`H3_LATLNG_TO_CELL`, `H3_GRID_DISK`) | Parts 8, 11 | `SELECT H3_LATLNG_TO_CELL(28.45,77.02,8);` | | |
| **Streamlit in Snowflake** | Part 11 | Snowsight → Projects → Streamlit; `SHOW STREAMLITS` | | |
| **Email notification integration + `SYSTEM$SEND_EMAIL`** | Part 12 | `SHOW INTEGRATIONS`; verified email on the account | | recipient must be a verified account user |
| **Snowflake Alerts** | Part 12 | `SHOW ALERTS;` + `CREATE ALERT` privilege | | serverless |
| **`OBJECT_DEPENDENCIES`** | Part 12 | `SELECT … FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES LIMIT 1;` | | |
| **Object tags** | Part 12 | `SHOW TAGS IN ACCOUNT;` + `CREATE TAG` | | tags on Standard: **UNVERIFIED**, may be Enterprise |
| **Budgets** | Part 1 | Snowsight → Admin → Cost Management → Budgets | | required guardrail |
| **Resource monitors** | Part 1 | `SHOW RESOURCE MONITORS;` | | |
| **Reader account** | Part 13 | `SHOW MANAGED ACCOUNTS;` + create privilege | | trial accounts sometimes blocked — **UNVERIFIED** |
| **Private listing / Marketplace provider** | Parts 5, 13 | Snowsight → Data Products → Provider Studio | | |
| **Native App framework** | Part 13 | `SHOW APPLICATION PACKAGES;` | | |
| **SQL API** | Part 13 | `POST /api/v2/statements` with key-pair JWT | | |
| **Git integration + Workspaces** | Part 15 | `SHOW GIT REPOSITORIES;`; Snowsight → Workspaces | | |
| **`EXECUTE DBT PROJECT`** | Part 15 | `SHOW DBT PROJECTS;` | | bills outer session **and** target |
| **Hybrid tables** | Part 14 | `SHOW HYBRID TABLES;` / `CREATE HYBRID TABLE` privilege | | always-on cost — burst only |
| **Snowflake Postgres** | Part 14 | Snowsight nav | | always-on cost — burst only |
| **Snowflake Optima** | Part 8 (search-optimization substitute) | docs + `SYSTEM$CLUSTERING_INFORMATION` behaviour | | |

---

## D. Confirmed absent — Standard Edition (do not re-probe)

masking policies · row access policies · aggregation policies · projection policies ·
data metric functions · materialized views · search optimization · query acceleration ·
automatic classification · `ACCESS_HISTORY` · object-bound event tables · Time Travel
beyond 1 day · multi-cluster warehouses · differential privacy · creating clean rooms ·
synthetic data generation.

Substitutes are fixed in `CLAUDE.md` §2.2 and are a documented finding of this PoC.

---

## E. Decisions this probe forces

Fill in after Section B and C are complete.

| Decision | Depends on | Choice | Rationale |
|---|---|---|---|
| Semantic view: Autopilot vs hand-written YAML | B: Autopilot | | |
| Iceberg `FORMAT_VERSION` 2 vs 3 | B: Iceberg v3 | | |
| Ask tab: Cortex Analyst only, or Analyst + CoWork | B: CoWork | | |
| Feature Store: batch vs streaming feature views | B: Streaming Feature Views | | |
| Part 12 PII: object tags vs secure views only | C: object tags | | |
| Part 13: reader account vs listing-only | C: reader account | | |
| Part 14: which burst(s) actually run | C: hybrid tables, Snowflake Postgres | | |

---

## F. Screenshots to capture

| Shot | Where | File |
|---|---|---|
| Snowsight left nav (full, expanded) | any page | `docs/img/p0-nav.png` |
| AI & ML section | Snowsight → AI & ML | `docs/img/p0-aiml.png` |
| Cost Management → Budgets | Snowsight → Admin | `docs/img/p0-budgets.png` |
| Data Products / Provider Studio | Snowsight | `docs/img/p0-dataproducts.png` |
| Horizon / Catalog | Snowsight | `docs/img/p0-horizon.png` |

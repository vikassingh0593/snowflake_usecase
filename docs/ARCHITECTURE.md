# Snowflake Quick-Commerce PoC — Architecture

Single design document. Domain: quick commerce — dark stores, riders, orders carrying an
SLA `promised_ts`. Deliberately wide scope: touch as many Snowflake-native capabilities
as fit inside one coherent pipeline, plus dbt, Snowpark and Streamlit.

Throwaway build. Optimised for *working and demonstrable*, not durability. Small data on
purpose — if a step needs more than a few hundred MB, the design is wrong.

---

## 1. Account facts and the two findings that shaped this

| Item | Value |
|---|---|
| Snowflake org / locator | `AWTTGVH` / `OOB49311` (Snowsight URL says `olb61128` — that is the account *name*, the locator differs) |
| Region | `AWS_US_WEST_2` · version `10.31.103` |
| Account created | 2026-08-27 |
| Azure | subscription `d27ba827-26e0-419a-bc0b-2b1015e641bb`, tenant `vikassingh0593gmail.onmicrosoft.com`, region `westus2`, RG `rg-qcpoc` |
| Pre-existing SA `snowflakefreeedition` | in RG `databricksfreeedition`. **Not ours.** Reuse only if `location = westus2` **and** `isHnsEnabled = false` |

### Finding 1 — Cortex AI functions are unavailable

Both required grants are present (`USE AI FUNCTIONS` at account level, `SNOWFLAKE.CORTEX_USER`
database role) and calls still fail:

> `AI function AI_CLASSIFY is not available for trial accounts.`

`AI_COMPLETE`, `AI_CLASSIFY`, `AI_FILTER`, `AI_EXTRACT`, `AI_SIMILARITY`, `AI_EMBED`,
`SENTIMENT`, `EMBED_TEXT_768` and legacy `COMPLETE` all fail identically. The gate is the
**account type**, not the edition and not a privilege. Everything downstream of an LLM
goes with it: Cortex Search (needs embeddings), Cortex Analyst, CoWork, and Semantic View
Autopilot — Autopilot is GA and edition-independent but generates DDL with an LLM.

Only a conversion to a paid account lifts this.

### Finding 2 — the account is Enterprise-shaped, not Standard

`SHOW MASKING POLICIES`, `SHOW ROW ACCESS POLICIES`, `SHOW AGGREGATION POLICIES` and
`SHOW MATERIALIZED VIEWS` all resolve; `ACCOUNT_USAGE.ACCESS_HISTORY` reads. Confirm with
a `CREATE MASKING POLICY` in a throwaway database before relying on it — a `SHOW` that
returns an empty set is not proof.

**Net effect.** The AI layer left; the governance layer arrived. Section 12 is where this
project now does its most interesting work, and it is stronger than the AI layer would
have been: every control is built twice, the Enterprise way and the Standard way, and
compared.

---

## 2. Layers

Database `QCOMMERCE`. `PUBLIC` dropped.

| Schema | Shape | Written by | Read by |
|---|---|---|---|
| `LAND` | stages, pipes, file formats, external volume, network rules. **No tables** | — | pipes, `COPY` |
| `RAW` | 1:1 with source, append-only, `VARIANT` payload, never updated | pipes, `COPY`, procs | dbt only |
| `CORE` | conformed, deduped, typed, SCD2 history | dbt | dbt, Snowpark |
| `MART` | star schema, published and governed | dbt | analysts, Snowpark, Streamlit |
| `LAB` *(transient)* | features, training sets, model output. Ungoverned sandbox | Snowpark | **nothing downstream** |
| `SERVE` | scored output, aggregates, app write-back | dbt (promotes from `LAB`), Streamlit | Streamlit, Snowsight |
| `SEMANTIC` | semantic views | analysts, the app's Ask tab |
| `APP` | Streamlit artefacts | — | — |
| `OPS` | `PIPELINE_LOG`, `DQ_RESULTS`, credit snapshots, alert history | everything | operator |

**The rule that defines this architecture: `LAB` is a sandbox, `SERVE` is a contract.**
Nothing downstream may reference a `LAB` object. Model output reaches `SERVE` only via a
dbt model that applies tests. Streamlit never reads `RAW`, `CORE` or `LAB`.

`LAB` is `TRANSIENT` — no Fail-safe, cheaper, and its disposability is the point.

---

## 3. Ownership

| Technology | Owns | Does not own |
|---|---|---|
| Snowflake native (pipes, streams, tasks, dynamic tables) | `LAND` → `RAW`, all scheduling | any business logic |
| **dbt** | `RAW` → `CORE` → `MART`, and `LAB` → `SERVE` promotion | ingestion, training |
| **Snowpark** | `LAB` (features, training, scoring, UDFs) + dbt Python models in `MART` | anything expressible in SQL |
| **Streamlit in Snowflake** | `SERVE` only | `RAW`, `CORE`, `LAB` |

Boundary test: expressible in SQL → dbt owns it. Needs sklearn or row-wise Python state →
Snowpark owns it. Needs a schedule → a Snowflake task owns it, not cron, not Airflow.

---

## 4. Source system, volumes, contracts

Postgres 16 in Docker is the OLTP source: `dark_stores`, `customers`, `products`,
`riders`, `inventory`, `orders`, `order_items`. Debezium CDC via logical replication.
**`REPLICA IDENTITY FULL` on every replicated table** so the WAL carries full pre-images
and SCD2 can tell which attribute changed.

| Entity | Rows | Produced by |
|---|---|---|
| dark_stores / products / customers / riders | 8 / 200 / 500 / 60 | Python → Postgres |
| orders / order_items | 20,000 / ~55,000 | Python → Postgres |
| order status events | ~100,000 | Python → Kafka |
| rider GPS pings | ~200,000 | **in-Snowflake `GENERATOR`** |
| clickstream | ~50,000 | **in-Snowflake `GENERATOR`** → NDJSON.gz → Azure |
| complaints | 300 | dbt seed CSV |

Money is **integer paise** everywhere — never float, never `NUMERIC`. It survives JSON,
Kafka, `VARIANT` and Snowpark without a rounding argument.

### Event contracts

`qc.order_status`, one event per lifecycle transition:
```json
{ "event_id": "uuid", "order_id": 918273, "store_id": 12, "rider_id": 4471,
  "from_status": "PACKED", "to_status": "PICKED_UP",
  "event_ts": "2026-09-08T14:22:31.412Z", "source": "rider_app",
  "meta": { "app_version": "4.11.2", "network": "4G" } }
```

`qc.rider_ping`, GPS at ~1 per rider per 5s, **keyed by `rider_id`** so a rider's pings
stay ordered inside one partition:
```json
{ "ping_id": "uuid", "rider_id": 4471, "order_id": 918273,
  "lat": 28.4595, "lon": 77.0266, "speed_kmph": 23.4, "battery_pct": 61,
  "event_ts": "2026-09-08T14:22:33.001Z" }
```

Three rules baked into both:
1. `event_ts` is ISO-8601 UTC with milliseconds, stamped by the **producer**.
2. Every event carries its own idempotency key — Snowpipe Streaming is at-least-once, so
   dedupe is the consumer's job.
3. Open-ended detail lives in a nested `meta` object, so a new field never breaks the
   contract or the `COPY`.

---

## 5. Ingestion — 14 mechanisms

| # | Mechanism | Source | Notes |
|---|---|---|---|
| 1 | **Snowpipe Streaming** via **Kafka Connector v4** + Redpanda | `qc.rider_ping`, `qc.order_status` | v4.1.0, class `SnowflakeStreamingSinkConnector`. Rewrite on the Snowpipe Streaming High-Performance Architecture: up to 10 GB/s per table, 5–10 s end to end, exactly-once and ordered. Schematization **forced OFF** — v4 flipped that default to `true`, so it must be set explicitly to get `RECORD_METADATA` / `RECORD_CONTENT` |
| 2 | **Snowpipe Streaming SDK**, direct, no Kafka | order status events | demonstrates channels and offset tokens |
| 3 | **Kafka connector in Snowpipe file mode** | same topic, second sink | **Needs connector v3.5.4** (`SnowflakeSinkConnector`): v4 dropped file mode entirely and supports streaming only, so the two mechanisms are two connector generations running side by side in isolated plugin directories. `buffer.flush.time = 60s` against streaming's 5–10 s is the measurement. **The comparison is the deliverable, not the ingestion** |
| 4 | **Snowpipe auto-ingest** via Event Grid → Storage Queue | hourly gzipped NDJSON clickstream → `landing/` | |
| 5 | **Snowpipe REST** (`insertFiles`) | same clickstream, internal stage | auto-ingest does not work on internal stages — showing both is the point |
| 6 | **Bulk `COPY INTO`** from the Azure stage | Parquet order backfill | exercises `INFER_SCHEMA`, `MATCH_BY_COLUMN_NAME`, `ON_ERROR`, `VALIDATION_MODE` |
| 7 | **Schema evolution on `COPY`** | v2 file gains `coupon_code` mid-load | `ENABLE_SCHEMA_EVOLUTION = TRUE`. Deliberate and documented |
| 8 | **External table** over `external/` + insert-only stream | 3PL settlement CSVs | queried in place |
| 9 | **Iceberg table** on `EXVOL_QC` | archived order events | **create at `FORMAT_VERSION = 3`** (GA 2026-05-07). v2→v3 is irreversible and v2 readers cannot read v3, so do not create v2 and upgrade |
| 10 | **Directory table + unstructured** | complaint PDFs in `docs/` | feeds document parsing |
| 11 | **External network access** from a Python proc | Open-Meteo weather per store lat/lon | network rule + external access integration + secret. No external tool anywhere in the loop |
| 12 | **Marketplace share** | one free public dataset | zero-copy: ingestion with no ingestion |
| 13 | **`write_pandas`** | store→zone reference mapping | |
| 14 | **dbt seeds** | category hierarchy, SLA thresholds, complaints CSV | version-controlled business constants |

Every `RAW` table carries `METADATA$FILENAME`, `METADATA$FILE_ROW_NUMBER`,
`METADATA$FILE_LAST_MODIFIED` and `LOAD_TS` where the mechanism allows — this is what
makes a bad load reversible without a full reload. **Dedupe in `CORE`, never `RAW`.**

### Azure surface

| Container | Used by | Role granted to the Snowflake service principal |
|---|---|---|
| `landing` | Snowpipe auto-ingest | Storage Blob Data Reader |
| `archive` | Iceberg external volume `EXVOL_QC` | **Storage Blob Data Contributor** (writes) |
| `external` | external table | Storage Blob Data Reader |
| `docs` | directory table | Storage Blob Data Reader |
| `snowpipe-queue` | Event Grid → Snowpipe notification | Storage Queue Data Contributor |

Plain GPv2, **hierarchical namespace OFF**. With HNS on, the Iceberg `dfs` endpoint was
Preview as of March 2026 and `COPY … PURGE` fails because Azure only deletes empty
directories. Use `azure://`, never `https://`.

Three integration objects — external volume, storage integration, notification
integration — each requiring `DESC` → `AZURE_CONSENT_URL` → tenant-admin consent → RBAC
on the resulting enterprise application. RBAC propagation takes ~5 minutes.

**Hard gate:** `SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('EXVOL_QC');` must pass before any
Iceberg work.

**Not attempted:** Snowflake Datastream — Kafka wire protocol without Kafka underneath,
landing topics as governed Snowflake or Iceberg tables. Private preview, not obtainable
on this account. Covered as prose, not code.

---

## 6. Streams — five types, one each

| Type | Tracks | On | Why that one |
|---|---|---|---|
| Standard | inserts, updates, deletes with before-images | `CORE` SCD2 sources | SCD2 needs the before-image |
| **Append-only** | inserts only | `RAW.RIDER_PING` | cheaper; pings are never updated |
| **Insert-only** | new files | external table | the only mode external tables support |
| On a **directory table** | new files in a stage | complaint PDFs | triggers parsing on arrival |
| On a **view** | changes flowing through a view | `CORE` conformance layer | change tracking without materialising |

---

## 7. Orchestration

| Capability | Where it earns its place |
|---|---|
| **Serverless vs warehouse tasks** | one DAG branch each way, credits compared in `OPS` |
| **`FINALIZER` task** | runs after the DAG **regardless of outcome** — the correct place to write the run summary to `OPS.PIPELINE_LOG` |
| **`SYSTEM$SET_RETURN_VALUE` / `SYSTEM$GET_PREDECESSOR_RETURN_VALUE`** | pass row counts and watermarks between tasks |
| **`WHEN SYSTEM$STREAM_HAS_DATA(...)`** | gates every stream-fed task. Largest single credit saving in the design — a gated task that does not run costs nothing |
| **Snowflake Scripting** | the ingest error handler is a SQL procedure with a cursor and an `EXCEPTION` block, not Python |
| **`EXECUTE AS OWNER` vs `CALLER`** | the privilege model behind the secure-view layer |
| **Three stage types** | table stage `@%tbl`, user stage `@~`, named stage `@LAND.STG_X` |
| **`VALIDATE()` + `COPY_HISTORY`** | post-load inspection after a deliberate bad-file load |
| **Clustering + `SYSTEM$CLUSTERING_INFORMATION`** | on `FCT_RIDER_PING`, depth recorded before and after |
| **Query tags + `QUERY_ATTRIBUTION_HISTORY`** | per-component credit attribution. Costs nothing |
| **Zero-copy clone + `UNDROP`** | clone `MART` → `MART_DEV` for CI; recovery demo inside the retention window |

Resume child tasks before the root, and the root last. A suspended child in a resumed DAG
fails silently.

---

## 8. SQL capabilities used deliberately

| Capability | Where it earns its place |
|---|---|
| **`ASOF JOIN`** | attach each rider ping to the order-status event in force at that moment. The best natural fit in this dataset — the window-function version is 20 lines |
| **`MATCH_RECOGNIZE`** | funnel `PLACED → PACKED → PICKED_UP → DELIVERED`, flagging skipped or out-of-order transitions. Also rider dwell: a run of pings under 2 km/h |
| **`GEOGRAPHY` + `ST_DISTANCE` / `ST_DWITHIN`** | run **beside** the Snowpark haversine UDF; document the accuracy and cost difference |
| **H3** (`H3_LATLNG_TO_CELL`, `H3_GRID_DISK`) | dark-store catchment; ping-density heatmap for the app |
| **`VECTOR` + `VECTOR_COSINE_SIMILARITY`** | "complaints similar to this one" — embeddings come from Snowpark, not Cortex |
| **`QUALIFY`** | dedupe streaming events by `event_id` in one line |
| **`GENERATOR` + `SEQ4` + `UNIFORM`/`NORMAL`** | generate pings and clickstream *inside* Snowflake. Saves an hour and shows a technique most people never find |
| **`FLATTEN` / `LATERAL` / `PARSE_JSON` / `TRY_CAST` / `OBJECT_CONSTRUCT`** | every `RAW` → `CORE` model |
| **`MERGE` + multi-table `INSERT`** | SCD2 upserts where dbt snapshots do not fit |
| **`TABLESAMPLE`** | cost control before any expensive full-table pass |
| **Recursive CTE** | product category tree from the seed |

---

## 9. Dimensional model — `MART`

Built by dbt, surrogate keys via `dbt_utils`.

**Dimensions:** `DIM_DATE` (static, Indian holiday flags from a seed) · `DIM_CUSTOMER`
(**SCD2**: segment, home_pincode) · `DIM_PRODUCT` (**SCD2**: price, is_active) ·
`DIM_STORE` (SCD1, carries lat/lon) · `DIM_RIDER` (**SCD2**) · `DIM_WEATHER_HOUR` (SCD1) ·
`DIM_ORDER_STATUS` (static seed, canonical lifecycle order)

| Fact | Grain | Type |
|---|---|---|
| `FCT_ORDER` | one row per order | **accumulating snapshot** — milestone timestamps as columns, lags between them, SLA breach flag, weather and complaint attributes |
| `FCT_ORDER_ITEM` | one row per order line | transaction |
| `FCT_ORDER_STATUS_EVENT` | one row per transition | transaction, from streaming |
| `FCT_RIDER_PING` | one row per ping | transaction, high volume, clustered on `(event_date, rider_id)` |
| `FCT_INVENTORY_DAILY` | store × product × day | **periodic snapshot** |
| `FCT_COMPLAINT` | one row per complaint | transaction, ML-enriched |

**Three fact patterns in one model — transaction, periodic snapshot, accumulating
snapshot — is a deliberate design point.** `FCT_ORDER` is the accumulating snapshot
because an order's row is rewritten as it walks the lifecycle; `FCT_ORDER_STATUS_EVENT`
keeps the immutable transition log beside it. Both exist on purpose: the snapshot answers
"how long from PACKED to PICKED_UP", the event table answers "which transitions were
skipped".

Max **2 dynamic tables**, `TARGET_LAG >= 60 min`. First is `SERVE.SLA_BY_STORE_HOUR`.

---

## 10. Snowpark — promise-breach risk scoring

Predict, at order placement, whether the order will breach `promised_ts`.

Features in `LAB.FEAT_ORDER`: store load at order time · idle riders within 2 km ·
haversine store→customer distance · weather at placement hour · hour-of-week · basket
size and category mix · store trailing 7-day SLA rate.

| Step | Surface |
|---|---|
| Distance | **UDF** (Python), callable from SQL and Python |
| Rider path smoothing + dwell detection | **UDTF** |
| Preprocessing | Snowpark ML `OneHotEncoder`, `StandardScaler`, `Pipeline` — running *in* Snowflake, not in driver memory |
| Training | **stored procedure**, sklearn `HistGradientBoostingClassifier` on `LAB.TRAIN_SET` |
| Versioning | **Model Registry**, with metrics and signature |
| Features | **Feature Store** — `FEAT_ORDER` registered properly, not left as a bare table |
| Scoring | **vectorized UDF**, open orders every 30 min → `LAB.ORDER_RISK_SCORE` |
| Promotion | dbt model → `SERVE.ORDER_RISK`, with `not_null`, `accepted_range` on probability, and a relationship test to `FCT_ORDER` |

Plus one **Snowpark pandas (Modin)** notebook, showing pandas semantics on warehouse
compute.

---

## 11. ML and text — built without Cortex

| Capability | Implementation |
|---|---|
| Demand forecast, store × category × day | `SNOWFLAKE.ML.FORECAST` |
| Ping-volume anomalies per store | `SNOWFLAKE.ML.ANOMALY_DETECTION` |
| Why did SLA drop last Tuesday | `SNOWFLAKE.ML.TOP_INSIGHTS` |
| Complaint → reason code | sklearn classifier, Snowpark sproc, **Model Registry** |
| Sentiment | lexicon UDF, or a second head on the same classifier |
| Order id from free text | **regex UDF** — always the right tool for a numeric id |
| Complaint PDFs from the directory table | **`pypdf`** in a Snowpark UDF |
| "Complaints similar to this one" | feature-hashing vectoriser UDF → `VECTOR(FLOAT, 256)` → `VECTOR_COSINE_SIMILARITY` |
| PII discovery | **`SYSTEM$CLASSIFY`** — restores what Cortex's absence killed |
| Semantic view | hand-written; Autopilot needs an LLM |

`SNOWFLAKE.ML` functions are classical ML, not LLM inference, so the trial AI gate does
not apply — confirm by training one before building on them.

The vector search is **lexical, not semantic**, and the write-up should say so. The
upgrade path is staging `all-MiniLM-L6-v2` (~90 MB) and running it inside the UDF.

**Two ML approaches compared** was a stated goal of the project and survives intact:
SQL-native ML functions versus Snowpark sklearn, on the same data.

---

## 12. Governance — where this project does its most interesting work

Every control built twice, and compared.

| Concern | Enterprise mechanism | Standard substitute | Finding |
|---|---|---|---|
| Column protection | masking policy on `customer_email` | `SHA2()` in a secure view | policy travels with the column; the view protects one access path |
| Row protection | row access policy on `FCT_ORDER` | secure view filtered on `CURRENT_ROLE()` joined to an entitlements table | same shape of difference, one object vs one path |
| Tag-driven protection | **tag-based masking** | — | attach the policy to a tag, not a column; it applies everywhere the tag does. This is what object tags were missing |
| Data quality | **data metric function** | dbt test **and** a Snowpark check writing to `OPS.DQ_RESULTS` | one rule, three expressions, credits compared |
| Lineage | **`ACCESS_HISTORY`** column-level | `QUERY_HISTORY` + `OBJECT_DEPENDENCIES` | column-level vs object-level, and what each misses |
| PII discovery | `SYSTEM$CLASSIFY` | — | classification proposes, secure views enforce |
| Faster point lookup | **search optimization** | clustering key | measure both, then **drop** the search optimization |
| Precomputed aggregate | **materialized view** | dynamic table | measure both, then **drop** the materialized view |
| Alerting | Snowflake Alert on `OPS.DQ_RESULTS` + `SYSTEM$SEND_EMAIL` | — | fire it on a seeded failure |
| Cost | query tags → `QUERY_ATTRIBUTION_HISTORY` | — | per-component credit report |
| Metadata layers | one query each against `ACCOUNT_USAGE`, `INFORMATION_SCHEMA`, `ORGANIZATION_USAGE` | — | document the latency and retention differences |

**Materialized views and search optimization maintain themselves in the background.**
They are exactly the always-on serverless the cost rules exist to prevent: estimate first
(`SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS`), build, measure, drop — inside one sitting.

**Multi-cluster warehouses and query acceleration stay out** regardless of edition. No
workload here justifies either, and both are cost traps on a fixed balance.

---

## 13. Serving

| Surface | Note |
|---|---|
| **Reader account** | `CREATE MANAGED ACCOUNT`. Bills to the provider account — create, query, drop |
| **Private listing** | Snowsight → Data Products → Provider Studio |
| **Native App** | application package wrapping the Streamlit app |
| **SQL API** | `POST /api/v2/statements` with a key-pair JWT |

### Streamlit in Snowflake — four tabs

| Tab | Reads | Writes |
|---|---|---|
| **Ops** | `SERVE.SLA_BY_STORE_HOUR` (dynamic table, 60 min lag), H3 density map | — |
| **Risk queue** | `SERVE.ORDER_RISK` joined to `FCT_ORDER`; dispatcher picks reassign / extend promise / issue credit | `SERVE.ACTION_LOG` |
| **Ask** | semantic view through a constrained query builder — pick metric, dimension, filter; show the generated SQL | logged questions |
| **Data health** | `OPS.DQ_RESULTS`, `OPS.PIPELINE_LOG` | — |

A dbt model joins `ACTION_LOG` back to outcomes so the app's own actions become a feature
for the next model run. **That closed loop is the point of the app.**

`QC_ANALYST` sees `SERVE` through secure views, `customer_email` hashed and rows filtered
on `CURRENT_ROLE()`.

---

## 14. CI/CD

Snowflake **Git integration** + Workspaces. GitHub Actions runs `dbt build` against a
zero-copy clone of `MART` on PR, `EXECUTE DBT PROJECT` on merge, and
`EXECUTE IMMEDIATE FROM @git_stage/…` for SQL-file deploys.

The clone is free; `dbt build` on it is not.

---

## 15. Cost model

| Control | Setting |
|---|---|
| Warehouses | `WH_INGEST_XS`, `WH_TRANSFORM_XS`, `WH_APP_XS` — all XS, `AUTO_SUSPEND = 60`, `AUTO_RESUME = TRUE`. Never resized |
| Resource monitor | `RM_POC`, quota 60, `FREQUENCY = NEVER`, notify 50/75/90, suspend 100/110. **Sees warehouse credits only** |
| Account budget | **80 credits.** The only thing covering serverless — Snowpipe, Streaming, dynamic table refresh, serverless tasks |
| Account params | `STATEMENT_TIMEOUT_IN_SECONDS = 600`, `DATA_RETENTION_TIME_IN_DAYS = 1` |
| Attribution | `ALTER SESSION SET QUERY_TAG = '<part>:<component>'` on every session |
| Roles | `QC_ADMIN` > `QC_LOADER`, `QC_ENGINEER`, `QC_ANALYST`. Service users `SVC_KAFKA`, `SVC_CI`, both `TYPE = SERVICE`, key-pair only |

**Nothing runs 24/7.** Anything always-on — materialized views, search optimization,
hybrid tables, Snowflake Postgres — is a deliberate short burst, built and dropped in one
sitting. 3.78 credits were already consumed before the build began.

Key-pair auth only; no password in any file. `rsa_key*` and `.env` stay out of git;
`dbt_packages/` goes in.

---

## 16. As built — real identifiers and what differed from the design

Everything below is verified, not planned. Design sections above describe intent;
this section is the account as it actually stands on 2026-09-09.

### Identifiers

| | |
|---|---|
| Snowflake account | `AWTTGVH-OLB61128`, locator `OOB49311`, `AWS_US_WEST_2`, version 10.31.103 |
| Connection | `snow -c qcpoc`, `authenticator = OAUTH_AUTHORIZATION_CODE` in `~/.snowflake/connections.toml` |
| Azure subscription | `d27ba827-26e0-419a-bc0b-2b1015e641bb` |
| Azure tenant | `985bb39b-768f-4cc6-ba0f-0f544b826143` |
| Storage account | `snowflakeqcpoc25056`, RG `rg-qcpoc`, `westus2`, GPv2, HNS off |
| Blob principal | `n1fam5snowflakepacint`, object id `5dec4f6c-0618-4fc6-a045-f7549a299115` |
| Queue principal | `14bjnhsnowflakepacint`, object id `a23e7398-bca1-439f-aa8d-7148bae08ea2` |

**Two service principals, not one.** The external volume and the storage
integration share `n1fam5snowflakepacint`; the notification integration gets its
own app with a different client id. Two consent URLs, not three, and not one.

### Deltas from the design

| Designed | As built | Why |
|---|---|---|
| Reuse `snowflakefreeedition` if suitable | Fresh account `snowflakeqcpoc25056` | The existing account is in `eastus2`, not `westus2`. Its HNS flag was unset, which means off — the region alone disqualified it |
| Warehouses as created | `GENERATION = '1'` set explicitly | Gen2 became the default in behaviour-change bundle 2026_03. It accelerates large scans and DML; at 200k rows the bottleneck is warehouse resume and cloud services, so the rate would apply and the benefit would not. Multiplier UNVERIFIED, commonly quoted ~1.35× |
| Warehouses as created | `ENABLE_QUERY_ACCELERATION = FALSE` | On by default. Bills as serverless credits `RM_POC` cannot see |
| `RM_POC` triggers | `NOTIFY_USERS` added | Triggers at 50/75/90% existed with no recipients, so the first real signal would have been the 100% suspend |
| Container-scoped RBAC only | Plus `Storage Blob Delegator` at **account** scope | `generateUserDelegationKey` is an account-scope operation. Without it `SYSTEM$VERIFY_EXTERNAL_VOLUME` returns `success:false` with read, write, list and delete all `PASSED` — a distinctive failure worth recognising |
| `RESOURCE_CONSTRAINT` to set generation | `GENERATION` property | Snowflake rejects the former: *"Use the GENERATION property to set warehouse hardware generation."* |

### Verified

**Enterprise, confirmed by `CREATE` on 2026-09-10.** `CREATE MASKING POLICY`
succeeded in a throwaway database and `SHOW` returned the row. The earlier
`SHOW`-based evidence is no longer the basis for §12 — the feature demonstrably
works. Governance builds every control twice, the policy way and the view way.

`SVC_KAFKA` has `HAS_KEYPAIR = true`, fingerprint
`SHA256:9Z3+0YfSMK7BR5XdA1rZG0ixJBIodMcCMcSMiLZIuOc=`.

```
SYSTEM$VERIFY_EXTERNAL_VOLUME('EXVOL_QC')
  success        true
  write/read/list/delete       PASSED
  azureGetUserDelegationKey    PASSED
  region         westus2
```

`LIST @STG_LANDING` returns zero rows. That is the success case: an empty
container listed without an authorisation error proves the credential works.

### Not yet done

- **Account budget** — the only control covering serverless spend. `RM_POC` sees
  virtual-warehouse credits only, and Snowpipe, Snowpipe Streaming, dynamic table
  refresh and search optimization are all invisible to it. Set in Snowsight →
  Admin → Cost Management → Budgets, 80 credits.
- **Service user keys** — `SVC_KAFKA` and `SVC_CI` exist with `TYPE = SERVICE` and
  no `RSA_PUBLIC_KEY`. Browser auth cannot work for a headless connector, so both
  need a key pair before Part 3.
- **All 14 ingestion mechanisms.** Zero rows in `RAW`.

---

## 17. Out of scope

Snowpark Container Services · Notebooks on Container Runtime · ML Jobs · Openflow ·
replication / failover / client redirect · clean rooms · Cortex fine-tuning · Warehouse
Gen2 · Adaptive Compute · Snowflake CoCo (not enabled on this account) · Snowflake
Datastream (private preview) · multi-cluster warehouses · query acceleration.

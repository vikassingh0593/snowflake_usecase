# Build guide — the whole project, stage by stage

Self-build manual. `docs/RUNBOOK.md` is the checklist, `docs/ARCHITECTURE.md` is the
design, `docs/OPERATOR.md` is the setup. **This is the how.**

Reflects the Part 0 findings, which changed two things from the original brief:

| Finding | Effect |
|---|---|
| **Cortex AI functions blocked** — trial accounts, categorical, grants are fine | Part 10 rebuilt around classical ML and Snowpark NLP. Part 11's Ask tab loses natural language |
| **Account is Enterprise-shaped, not Standard** | Part 8 and Part 12 gain masking policies, row access policies, DMFs, `ACCESS_HISTORY`, materialized views, search optimization. Substitutes become a deliberate comparison |

---

## 1. Tool matrix — what you need, and when it first appears

| Tool | First needed | Used in | Notes |
|---|---|---|---|
| Snowsight worksheet | Part 0 | all | fine for DDL, cannot `PUT` a local file |
| **Snowflake CLI** (`snow`) | Part 1 | 1, 4, 5, 10, 13, 15 | `PUT` to stages, `EXECUTE IMMEDIATE FROM`, `-f file.sql` |
| **Azure CLI** (or Cloud Shell) | Part 1 | 1, 4, 5, 17 | Cloud Shell avoids installing anything |
| **Docker + compose** | Part 2 | 2, 3 | Postgres 16, Redpanda, Kafka Connect |
| **Python 3.11 venv** | Part 2 | 2, 3, 5, 9, 10, 13 | generators, Streaming SDK, Snowpark, `write_pandas` |
| **dbt-snowflake** | Part 7 | 7, 8, 9, 11, 15 | `dbt-core` comes with it |
| `snowflake-ml-python` | Part 9 | 9, 10 | install late, heavy dependency tree |
| `pypdf`, `scikit-learn` | Part 10 | 10 | inside Snowpark UDFs, from the Snowflake Anaconda channel |
| GitHub Actions | Part 15 | 15 | `dbt build` against a zero-copy clone |

Everything Snowflake-side is driven by `snow -c qcpoc -f <file>.sql` or pasted into a
worksheet. Pick one and stay consistent — mixing them makes `QUERY_HISTORY` harder to
read at credit-attribution time.

---

## 2. Stage map

| Part | Build | Primary tool | Snowflake surface | Hours |
|---|---|---|---|---|
| 0 ✅ | feature probe | Snowsight | `SHOW`, `ACCOUNT_USAGE` | 0.5 |
| 1 | Azure + Snowflake bootstrap | `az`, `snow` | integrations, RBAC, monitors | 2.0 |
| 2 | Docker stack + data generation | Docker, Python | `GENERATOR`, `write_pandas` | 1.5 |
| 3 | Streaming ingestion ×3 | Kafka Connect, SDK | Snowpipe Streaming | 1.5 |
| 4 | File ingestion ×4 | `snow`, `az` | Snowpipe, `COPY` | 1.5 |
| 5 | Lake + API ingestion ×7 | `snow`, Python | Iceberg, external tables, EAI | 2.0 |
| 6 | Streams + task DAG | SQL | 5 stream types, tasks | 1.0 |
| 7 | dbt `RAW` → `CORE` | dbt | snapshots, tests | 1.0 |
| 8 | dbt `CORE` → `MART` | dbt | star schema, `ASOF`, H3, policies | 2.0 |
| 9 | Snowpark ML | Python | UDF/UDTF, Registry, Feature Store | 2.0 |
| 10 | ML functions + Snowpark NLP | SQL, Python | `SNOWFLAKE.ML`, `VECTOR` | 1.5 |
| 11 | Streamlit | Streamlit in Snowflake | `SERVE`, write-back | 1.5 |
| 12 | Governance | SQL | policies, tags, alerts, lineage | 1.5 |
| 13 | Serving | SQL, REST | share, listing, Native App, SQL API | 1.0 |
| 14 | Bursts | Snowsight | Postgres, hybrid table | 0.5 |
| 15 | CI/CD | GitHub Actions | Git integration, `EXECUTE DBT PROJECT` | 1.0 |
| 16 | Write-ups | — | `QUERY_ATTRIBUTION_HISTORY` | 1.0 |
| 17 | Teardown | `snow`, `az` | — | 0.5 |

**Total 23.5 h against a 16 h budget.** It does not fit as written. Cut order is in §6.

---

## 3. Part playbooks

### Part 1 — bootstrap

**Goal:** every object the rest of the build assumes, and a green external volume.

**Azure first**, because the consent flow takes wall-clock time you can spend elsewhere.

1. `az account show` → capture `tenantId`
2. `az storage account show -n snowflakefreeedition -g databricksfreeedition` → if
   `location != westus2` or `isHnsEnabled = true`, create fresh:
   ```bash
   SA=snowflakeqcpoc$RANDOM
   az group create -n rg-qcpoc -l westus2
   az storage account create -n $SA -g rg-qcpoc -l westus2 \
     --sku Standard_LRS --kind StorageV2 --access-tier Hot \
     --allow-blob-public-access false --min-tls-version TLS1_2
   ```
   **Do not pass `--enable-hierarchical-namespace`.** With HNS on, the Iceberg `dfs`
   endpoint was Preview as of March 2026 and `COPY … PURGE` fails, because Azure only
   deletes empty directories.
3. Four containers: `landing`, `archive`, `external`, `docs`
4. Queue `snowpipe-queue` + Event Grid system topic + subscription filtered to
   `/blobServices/default/containers/landing/`
5. Lifecycle rule: delete `landing` blobs after 14 days

**Snowflake second.**

| Object | Detail |
|---|---|
| Account params | `STATEMENT_TIMEOUT_IN_SECONDS = 600`, `DATA_RETENTION_TIME_IN_DAYS = 1` |
| Warehouses | `WH_INGEST_XS`, `WH_TRANSFORM_XS`, `WH_APP_XS` — all XS, `AUTO_SUSPEND = 60` |
| Database | `QCOMMERCE`, drop `PUBLIC`, create the 9 schemas. `LAB` is `TRANSIENT` |
| Roles | `QC_ADMIN` > `QC_LOADER`, `QC_ENGINEER`, `QC_ANALYST` |
| Service users | `SVC_KAFKA` → `QC_LOADER`, `SVC_CI` → `QC_ENGINEER`, both `TYPE = SERVICE`, key-pair |
| Resource monitor | `RM_POC`, quota 60, `FREQUENCY = NEVER`, notify 50/75/90, suspend 100/110 |
| Budget | **80 credits, set in Snowsight → Admin → Cost Management.** The monitor sees warehouse credits only; the budget is the only thing covering serverless |

**Three integrations, each with the same four-step dance:**

1. `CREATE EXTERNAL VOLUME EXVOL_QC` on `archive/`, `ALLOW_WRITES = TRUE`
2. `CREATE STORAGE INTEGRATION` covering `landing/`, `external/`, `docs/`
3. `CREATE NOTIFICATION INTEGRATION TYPE = QUEUE NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE`

For each: `DESC` it → open `AZURE_CONSENT_URL` → consent as tenant admin → find the
service principal in Azure → Enterprise applications (name starts with the
`AZURE_MULTI_TENANT_APP_NAME` prefix before the underscore) → assign RBAC.

| Container | Role |
|---|---|
| `archive` | **Storage Blob Data Contributor** — Iceberg writes |
| `landing`, `external`, `docs` | Storage Blob Data Reader |
| `snowpipe-queue` | Storage Queue Data Contributor |

Use `azure://`, never `https://`. **RBAC takes ~5 minutes to propagate — do not debug
before waiting.**

**Exit:** `SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('EXVOL_QC');` returns success. Do not
proceed past a failure; every Iceberg step depends on it.

**Gotchas:** consent must be done by a tenant admin, which on a personal Azure account
is you but the flow still redirects oddly. The SP name is not obvious — match on the
prefix, not the whole string.

---

### Part 2 — Docker stack and data

**Goal:** an OLTP source that produces CDC, and enough events to make the rest real.

`docker-compose.yml` services:

| Service | Image | Config that matters |
|---|---|---|
| `postgres` | `postgres:16` | `wal_level=logical`, `max_replication_slots=4` |
| `redpanda` | `redpandadata/redpanda` | single node, `--overprovisioned` |
| `connect` | Kafka Connect + Debezium + **Snowflake sink v4** | mount both connector jars |

Postgres schema: `dark_stores`, `customers`, `products`, `riders`, `inventory`,
`orders`, `order_items`. **`ALTER TABLE … REPLICA IDENTITY FULL` on every replicated
table** — without it the WAL carries no pre-image and SCD2 cannot tell which attribute
changed.

Volumes, in integer paise everywhere:

| Entity | Rows | Generated by |
|---|---|---|
| dark_stores / products / customers / riders | 8 / 200 / 500 / 60 | Python → Postgres |
| orders / order_items | 20,000 / ~55,000 | Python → Postgres |
| order status events | ~100,000 | Python → Kafka |
| rider GPS pings | ~200,000 | **in-Snowflake `GENERATOR`** |
| clickstream | ~50,000 | **in-Snowflake `GENERATOR`** → NDJSON.gz → Azure |

The `GENERATOR` variant is worth doing for its own sake:
`TABLE(GENERATOR(ROWCOUNT => 200000))` with `SEQ4()`, `UNIFORM()`, `NORMAL()` produces
200k pings in seconds without a producer process. Saves an hour and demonstrates a
technique most people never find.

**Exit:** `rpk topic consume qc.order_status` shows events; Postgres has 20k orders.

**Gotchas:** Debezium needs the replication slot to exist before the connector starts —
if the connector 500s on registration, check `pg_replication_slots`. Kafka Connect in
Docker behind a proxy needs `-Dhttps.proxyHost` in `JVM_OPTS` or the Snowflake sink
cannot reach the account.

---

### Part 3 — streaming ingestion, three ways

**Goal:** the same topic landed three ways, with the differences measured. **The
comparison is the deliverable, not the ingestion.**

| # | Mechanism | Config |
|---|---|---|
| 1 | Kafka connector **v4**, Snowpipe Streaming | `snowflake.ingestion.method=SNOWPIPE_STREAMING`, schematization **OFF** — let it create `RECORD_METADATA` / `RECORD_CONTENT` |
| 2 | Snowpipe Streaming **SDK**, direct, no Kafka | Python. Open a channel, write rows, set offset tokens, reopen and prove the offset resumed |
| 3 | Kafka connector in **Snowpipe file mode** | second sink on the same topic, different `snowflake.topic2table.map` target |

Pin **v4.0+** (GA 2026-04-20). It is a rewrite on the Snowpipe Streaming
High-Performance Architecture — up to 10 GB/s per table, 5–10 s end to end,
exactly-once and ordered. Earlier majors use the Classic path, which now carries a
published deprecation notice.

Record in `OPS.PIPELINE_LOG`: rows landed, wall-clock from producer stamp to
`LOAD_TS`, and credits from `METERING_HISTORY` split by service type.

**Exit:** rows in `RAW` from all three; the latency and credit table written.

**Gotchas:** at-least-once means duplicates are expected. **Do not dedupe in `RAW`** —
that is Part 7's job, one `QUALIFY` line. Key `qc.rider_ping` by `rider_id` so one
rider's pings stay ordered inside a partition.

---

### Part 4 — file ingestion

| # | Mechanism | Exercises |
|---|---|---|
| 4 | Snowpipe **auto-ingest** via Event Grid | notification integration end to end |
| 5 | Snowpipe **REST** `insertFiles` on an internal stage | auto-ingest does not work on internal stages — showing both is the point |
| 6 | Bulk `COPY INTO` from the Azure stage, Parquet | `INFER_SCHEMA`, `MATCH_BY_COLUMN_NAME`, `ON_ERROR`, `VALIDATION_MODE` |
| 7 | **Schema evolution** | v2 file gains `coupon_code` mid-load, `ENABLE_SCHEMA_EVOLUTION = TRUE` |

Do #7 deliberately: load v1, then a v2 file with an extra column, then show
`INFORMATION_SCHEMA.COLUMNS` before and after. Also load one **intentionally bad file**
and inspect it with `VALIDATE(TABLE_NAME, JOB_ID => '_last')` and `COPY_HISTORY`.

Three stage types, one line each: table stage `@%tbl`, user stage `@~`, named stage
`@LAND.STG_X`.

**Exit:** schema evolution demonstrated on a real bad file, `VALIDATE()` output captured.

**Gotchas:** `PUT` needs a client — Snowsight cannot upload to an internal stage from
your filesystem. Use `snow`. Auto-ingest silences failures; if nothing lands, check
`SYSTEM$PIPE_STATUS` before touching the queue.

---

### Part 5 — lake and API

| # | Mechanism | Key point |
|---|---|---|
| 8 | External table over `external/` + **insert-only** stream | insert-only is the only stream type external tables support |
| 9 | **Iceberg table** on `EXVOL_QC` | **create at `FORMAT_VERSION = 3`.** GA 2026-05-07. v2→v3 is irreversible and v2 readers cannot read v3, so do not create v2 and upgrade |
| 10 | Directory table on `docs/` + stream | `PUT` the complaint PDFs, then `ALTER STAGE … REFRESH` |
| 11 | **External network access** → Open-Meteo | network rule + external access integration + secret + Python proc. No external tool anywhere in the loop |
| 12 | Marketplace share | any free public dataset. Zero-copy: ingestion with no ingestion |
| 13 | `write_pandas` | store→zone reference mapping |
| 14 | dbt seeds | category hierarchy, SLA thresholds, complaints CSV |

Mechanism 11 is the one people get wrong. Order: `CREATE NETWORK RULE` →
`CREATE SECRET` (if the API needs one; Open-Meteo does not) →
`CREATE EXTERNAL ACCESS INTEGRATION` referencing both →
`CREATE PROCEDURE … EXTERNAL_ACCESS_INTEGRATIONS = (…)`. Missing the integration on the
procedure gives a misleading DNS error rather than a permission error.

**Exit:** all 14 mechanisms have landed data. Count them off explicitly.

---

### Part 6 — streams and orchestration

**Five stream types, one each:**

| Type | On | Why that one |
|---|---|---|
| Standard | `CORE` SCD2 sources | needs the before-image |
| Append-only | `RAW.RIDER_PING` | cheaper, pings are never updated |
| Insert-only | external table | only mode external tables support |
| Directory table | complaint stage | fires document parsing on arrival |
| On a view | `CORE` conformance view | change tracking without materialising |

**Task DAG.** Root task → children → `FINALIZER`. Run one branch **serverless**
(`USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE`) and one on `WH_INGEST_XS`, then compare
credits in `OPS`.

Three things that make the DAG worth showing:

- `WHEN SYSTEM$STREAM_HAS_DATA('<stream>')` on **every** stream-fed task. Largest single
  credit saving in the design — a gated task that does not run costs nothing
- `SYSTEM$SET_RETURN_VALUE` / `SYSTEM$GET_PREDECESSOR_RETURN_VALUE` to pass row counts
  and watermarks between tasks
- A `FINALIZER` task, which runs after the DAG **regardless of outcome** — the correct
  place to write the run summary to `OPS.PIPELINE_LOG`

The ingest error handler is **Snowflake Scripting**, not Python: a SQL procedure with a
cursor and an `EXCEPTION` block.

**Exit:** DAG runs end to end, `OPS.PIPELINE_LOG` has a row from the finalizer.

**Gotchas:** resume children before the root, and the root last. A suspended child in a
resumed DAG fails silently.

---

### Part 7 — dbt `RAW` → `CORE`

| Concern | Implementation |
|---|---|
| Dedupe | `QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY load_ts DESC) = 1` |
| SCD2 | dbt snapshots for `customers`, `products`, `riders` |
| Where snapshots do not fit | `MERGE` + multi-table `INSERT` |
| Typing | `TRY_CAST` everywhere. `PARSE_JSON` + `FLATTEN` + `LATERAL` on every `VARIANT` |
| Freshness | `dbt source freshness` on the streaming tables |

Both the outer session warehouse **and** `profiles.yml` target must be
`WH_TRANSFORM_XS` — `EXECUTE DBT PROJECT` bills them separately.

Run `dbt deps` **locally** and commit `dbt_packages/`.

**Exit:** `dbt build` green, snapshots produce a second version row after a source
update.

---

### Part 8 — dbt `CORE` → `MART`

Star schema per `docs/ARCHITECTURE.md` §8. Surrogate keys via `dbt_utils`.

**Three fact patterns on purpose:** `FCT_ORDER` accumulating snapshot,
`FCT_INVENTORY_DAILY` periodic snapshot, the rest transaction. Say so in the docs — it
is a design point, not an accident.

The four SQL features that earn their place here:

| Feature | Use |
|---|---|
| **`ASOF JOIN`** | attach each rider ping to the order-status event in force at that moment. Best natural fit in the dataset; the window-function version is 20 lines |
| **`MATCH_RECOGNIZE`** | funnel `PLACED → PACKED → PICKED_UP → DELIVERED`, flag skipped or out-of-order transitions. Also rider dwell: a run of pings under 2 km/h |
| **`GEOGRAPHY` + `ST_DISTANCE`** | run it **beside** the Snowpark haversine UDF and document the accuracy and cost difference |
| **H3** | `H3_LATLNG_TO_CELL` for store catchment, `H3_GRID_DISK` for the Streamlit heatmap |

Plus: clustering key on `FCT_RIDER_PING (event_date, rider_id)` with
`SYSTEM$CLUSTERING_INFORMATION` recorded before and after; **max 2 dynamic tables**,
`TARGET_LAG >= 60 min`.

**Enterprise additions, from the Part 0 finding:**

| Add | Cost | Discipline |
|---|---|---|
| Masking policy on `customer_email`, beside the `SHA2()` secure view | ~0 | keep both, compare |
| Row access policy on `FCT_ORDER`, beside the `CURRENT_ROLE()` view | ~0 | keep both, compare |
| **One** materialized view against the dynamic table doing the same job | **continuous background** | measure, then **drop** |
| **One** search-optimization build against the clustering key | **build + maintenance** | `SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS` **first**, measure, then **drop** |

**Exit:** all facts and dims populated and tested; clustering depth recorded; the MV and
search-optimization measurements taken and both objects dropped.

---

### Part 9 — Snowpark

**Goal:** promise-breach risk at order placement, end to end, with every Snowpark
surface exercised.

Features in `LAB.FEAT_ORDER`: store load at order time · idle riders within 2 km ·
haversine store→customer distance · weather at placement hour · hour-of-week · basket
size and category mix · store trailing 7-day SLA rate.

| Step | Surface |
|---|---|
| Distance | **UDF** (Python), callable from SQL and Python |
| Path smoothing + dwell | **UDTF** |
| Preprocessing | Snowpark ML `OneHotEncoder`, `StandardScaler`, `Pipeline` — *in* Snowflake, not driver memory |
| Training | **stored procedure**, sklearn `HistGradientBoostingClassifier` on `LAB.TRAIN_SET` |
| Versioning | **Model Registry**, with metrics and signature |
| Features | **Feature Store** — register `FEAT_ORDER` properly, not a bare table |
| Scoring | **vectorized UDF**, open orders every 30 min → `LAB.ORDER_RISK_SCORE` |
| Promotion | dbt model → `SERVE.ORDER_RISK` with `not_null`, `accepted_range` on probability, relationship test to `FCT_ORDER` |

Plus one **Snowpark pandas (Modin)** notebook, showing pandas semantics on warehouse
compute.

**The rule that governs this part:** nothing downstream may reference a `LAB` object.
`LAB` is a sandbox, `SERVE` is a contract. Model output reaches `SERVE` only through a
dbt model that applies tests.

**Exit:** `SERVE.ORDER_RISK` populated and tested; a model version visible in the
registry with metrics.

---

### Part 10 — ML functions and Snowpark NLP *(rebuilt: Cortex is blocked)*

| Capability | Implementation |
|---|---|
| Demand forecast, store × category × day | `SNOWFLAKE.ML.FORECAST` |
| Ping-volume anomalies per store | `SNOWFLAKE.ML.ANOMALY_DETECTION` |
| Why did SLA drop last Tuesday | `SNOWFLAKE.ML.TOP_INSIGHTS` |
| Complaint → reason code | sklearn classifier, Snowpark sproc, **Model Registry** |
| Sentiment | lexicon UDF, or a second head on the same classifier |
| Order id from free text | **regex UDF** — always the right tool for a numeric id |
| Complaint PDFs | **`pypdf`** in a Snowpark UDF reading the directory table |
| "Complaints similar to this" | feature-hashing vectoriser UDF → `VECTOR(FLOAT, 256)` → `VECTOR_COSINE_SIMILARITY` |
| PII classification | **`SYSTEM$CLASSIFY`** — Enterprise, and it restores what Cortex's absence killed |
| Semantic view | hand-written. Autopilot needs an LLM |

Say plainly in the write-up that the vector search is **lexical, not semantic**. The
upgrade path is staging `all-MiniLM-L6-v2` (~90 MB) and running it in the UDF — real
embeddings, ~20 minutes of setup.

`SNOWFLAKE.ML` functions are classical ML, not LLM inference, so the trial AI gate does
not apply. Confirm by training one before building on them.

**Exit:** forecast and anomaly output landed; classifier in the registry; vector search
returns ranked complaints.

---

### Part 11 — Streamlit in Snowflake

| Tab | Reads | Writes |
|---|---|---|
| **Ops** | `SERVE.SLA_BY_STORE_HOUR` (dynamic table, 60 min lag), H3 density map | — |
| **Risk queue** | `SERVE.ORDER_RISK` joined to `FCT_ORDER`; dispatcher picks reassign / extend promise / issue credit | `SERVE.ACTION_LOG` |
| **Ask** | semantic view through a **constrained query builder** — pick metric + dimension + filter, show the generated SQL | logged questions |
| **Data health** | `OPS.DQ_RESULTS`, `OPS.PIPELINE_LOG` | — |

**The closed loop is the point of the app.** A dbt model joins `ACTION_LOG` back to
outcomes so the app's own actions become a feature for the next model run. Build it.

`QC_ANALYST` sees `SERVE` through secure views with `customer_email` SHA2-hashed and
rows filtered on `CURRENT_ROLE()`. Streamlit never touches `RAW`, `CORE` or `LAB`.

---

### Part 12 — governance *(the part that grew)*

| Concern | Enterprise way | Standard substitute | Do |
|---|---|---|---|
| Column protection | masking policy | `SHA2()` secure view | **both**, compare |
| Row protection | row access policy | `CURRENT_ROLE()` secure view | **both**, compare |
| Tag-driven protection | tag-based masking | — | **add** — this is what object tags were missing |
| Data quality | **DMF** | dbt test + Snowpark check → `OPS.DQ_RESULTS` | **all three** on one rule, credits compared |
| Lineage | `ACCESS_HISTORY` column-level | `QUERY_HISTORY` + `OBJECT_DEPENDENCIES` | **both** |
| PII discovery | `SYSTEM$CLASSIFY` | — | **add** |
| Alerts | Snowflake Alert on `OPS.DQ_RESULTS` + `SYSTEM$SEND_EMAIL` | — | seed a failure and make it fire |
| Cost | query tags → `QUERY_ATTRIBUTION_HISTORY` | — | per-component credit report |
| Metadata layers | one query each against `ACCOUNT_USAGE`, `INFORMATION_SCHEMA`, `ORGANIZATION_USAGE` | — | document latency and retention differences |

`EXECUTE AS OWNER` vs `EXECUTE AS CALLER` is the privilege model behind the secure-view
substitute — show both and explain which one the analyst role actually needs.

**Exit:** the alert fires on a seeded DQ failure and the email arrives.

---

### Part 13 — serving

| Surface | Note |
|---|---|
| **Reader account** | `CREATE MANAGED ACCOUNT`. Confirmed available. Bills to your account — create, query, drop |
| **Private listing** | Snowsight → Data Products → Provider Studio |
| **Native App** | application package wrapping the Streamlit app |
| **SQL API** | `POST /api/v2/statements` with a key-pair JWT — the same key from `docs/OPERATOR.md` §2 |

**Exit:** an external consumer queries `MART` and gets rows.

---

### Part 14 — bursts, then immediate teardown

Both of these bill while they exist. Screenshot, then drop **in the same sitting**.

| Burst | Why it is here |
|---|---|
| **Snowflake Postgres** | GA 2026-02-24, and AWS us-west-2 is on the launch region list — co-located. Replaces Docker Postgres for one demo |
| **Hybrid table** for `ACTION_LOG` | point-lookup write-back, the one workload in this project that actually suits it |

**Exit:** screenshots taken, both objects dropped, `SHOW HYBRID TABLES` empty.

---

### Part 15 — CI/CD

1. Snowflake **Git integration** — `CREATE GIT REPOSITORY` pointing at this repo
2. **Workspaces** in Snowsight, browsing the same tree
3. GitHub Actions: on PR, zero-copy clone `MART` → `MART_DEV`, `dbt build` against the
   clone, drop it
4. On merge, `EXECUTE DBT PROJECT`
5. `EXECUTE IMMEDIATE FROM @git_stage/…` for SQL-file deploys

Zero-copy clone is free; `dbt build` on it is not. Budget it.

**Exit:** PR check green.

---

### Part 16 — write-ups

| Doc | Content |
|---|---|
| `docs/DEMO.md` | the walkthrough, in the order you would show someone |
| `docs/CREDITS.md` | final numbers from `QUERY_ATTRIBUTION_HISTORY`, per component, via the query tags |
| `docs/DATASTREAM.md` | Datastream vs Kafka connector v4: what changes when the broker disappears, and where the Kafka protocol still earns its place. Datastream is private preview — prose only, no code |

---

### Part 17 — teardown

`snow -c qcpoc -f teardown.sql` then `./teardown.sh`. Order matters: suspend tasks and
pipes before dropping, drop the reader account, drop integrations last.

**Exit:** `SHOW WAREHOUSES` / `TASKS` / `PIPES` / `MANAGED ACCOUNTS` all empty,
`az group delete -n rg-qcpoc --yes` done. Never touch `databricksfreeedition`.

---

## 4. Capability checklist

Tick these off as you go — this is the actual scope of the project.

**Ingestion (14):** Kafka v4 streaming · Streaming SDK direct · Kafka file mode ·
Snowpipe auto-ingest · Snowpipe REST · bulk `COPY` · schema evolution · external table ·
Iceberg v3 · directory table · external network access · marketplace share ·
`write_pandas` · dbt seeds

**Streams (5):** standard · append-only · insert-only · directory table · on a view

**SQL:** `ASOF JOIN` · `MATCH_RECOGNIZE` · `GEOGRAPHY`/`ST_DISTANCE`/`ST_DWITHIN` · H3 ·
`VECTOR` + cosine · `QUALIFY` · `GENERATOR`/`SEQ4`/`UNIFORM` · `FLATTEN`/`LATERAL`/
`PARSE_JSON`/`TRY_CAST`/`OBJECT_CONSTRUCT` · `MERGE` + multi-table `INSERT` ·
`TABLESAMPLE` · recursive CTE

**Pipeline:** serverless vs warehouse tasks · `FINALIZER` · return values ·
`SYSTEM$STREAM_HAS_DATA` gating · Snowflake Scripting · `EXECUTE AS OWNER`/`CALLER` ·
three stage types · `VALIDATE()` + `COPY_HISTORY` · clustering + `SYSTEM$CLUSTERING_INFORMATION` ·
query tags + `QUERY_ATTRIBUTION_HISTORY` · zero-copy clone + `UNDROP`

**Modelling:** SCD2 ×3 · SCD1 ×2 · transaction / periodic snapshot / accumulating
snapshot facts · 2 dynamic tables

**Snowpark:** UDF · UDTF · vectorized UDF · sproc · Snowpark ML pipeline · Model
Registry · Feature Store · Modin

**ML:** `FORECAST` · `ANOMALY_DETECTION` · `TOP_INSIGHTS` · sklearn classifier ·
vector search

**Governance:** masking policy · row access policy · tag-based masking · object tags ·
`SYSTEM$CLASSIFY` · DMF · `ACCESS_HISTORY` · `OBJECT_DEPENDENCIES` · alerts + email ·
secure views · materialized view (burst) · search optimization (burst)

**Serving:** reader account · private listing · Native App · SQL API · Streamlit

**Ops:** resource monitor · budget · Git integration · Workspaces · GitHub Actions ·
`EXECUTE DBT PROJECT` · `EXECUTE IMMEDIATE FROM`

---

## 5. Failure-mode index

| Symptom | Cause | Fix |
|---|---|---|
| `SYSTEM$VERIFY_EXTERNAL_VOLUME` fails right after granting RBAC | propagation | wait 5 min before debugging |
| Snowpipe lands nothing, no error | auto-ingest fails silently | `SYSTEM$PIPE_STATUS`, then the queue |
| `PUT` not recognised | Snowsight cannot `PUT` | use `snow` |
| Debezium connector 500s on registration | replication slot missing | check `pg_replication_slots`, `wal_level=logical` |
| Kafka sink cannot reach Snowflake from Docker | container ignores host proxy | `-Dhttps.proxyHost` in `JVM_OPTS` |
| SCD2 cannot tell which column changed | no pre-image in the WAL | `REPLICA IDENTITY FULL` |
| External access proc gives a DNS error | integration not attached to the procedure | `EXTERNAL_ACCESS_INTEGRATIONS = (…)` on `CREATE PROCEDURE` |
| Task DAG silently does nothing | child suspended | resume children first, root last |
| Credits climbing with nothing running | MV or search optimization left behind | drop them; check `SHOW MATERIALIZED VIEWS` |
| `AI function … not available for trial accounts` | the Part 0 finding | not fixable without converting to paid |

---

## 6. If the clock beats you

23.5 h of work against 16 h. Drop in this order — duplication before capability:

| Drop | Loses | Still proven by |
|---|---|---|
| Part 13 reader account + private listing | 2 of 4 sharing surfaces | Native App + SQL API |
| Part 14 Snowflake Postgres | one screenshot | hybrid table still shows the always-on trade-off |
| Mechanism 5 (REST pipe) | internal-stage contrast | auto-ingest still proves Snowpipe |
| Part 15 GitHub Actions | CI proof | Git integration + `EXECUTE IMMEDIATE FROM` |
| Part 10 vector search | lexical similarity | the classifier still shows Snowpark NLP |

**Never drop:** Part 1 (nothing works without it), the `LAB` → `SERVE` contract, the
closed loop in Part 11, or the three-way ingestion comparison in Part 3. Each is a
stated deliverable and each is the thing that makes the project look considered rather
than assembled.

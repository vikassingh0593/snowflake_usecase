# Architecture — Snowflake Quick-Commerce PoC

Throwaway 2-day breadth PoC. Domain: quick commerce — dark stores, riders, orders with
an SLA `promised_ts`. Optimised for *working and demonstrable*, not durability.

---

## 1. Layers

Database `QCOMMERCE`. `PUBLIC` dropped.

| Schema | Shape | Written by | Read by |
|---|---|---|---|
| `LAND` | stages, pipes, file formats, external volume, network rules. **No tables** | — | pipes, `COPY` |
| `RAW` | 1:1 with source, append-only, `VARIANT` payload, never updated | pipes, `COPY`, procs | dbt only |
| `CORE` | conformed, deduped, typed, SCD2 history | dbt | dbt, Snowpark |
| `MART` | star schema, published and governed | dbt | analysts, Snowpark, Streamlit, Cortex |
| `LAB` *(transient)* | features, training sets, model output. Ungoverned sandbox | Snowpark | **nothing downstream** |
| `SERVE` | scored output, aggregates, app write-back | dbt (promotes from `LAB`), Streamlit | Streamlit, Snowsight |
| `SEMANTIC` | semantic views for Cortex Analyst / CoWork | dbt / Autopilot | agents |
| `APP` | Streamlit artefacts | — | — |
| `OPS` | `PIPELINE_LOG`, `DQ_RESULTS`, credit snapshots, alert history | everything | operator |

**The rule that defines this architecture: `LAB` is a sandbox, `SERVE` is a contract.**
Nothing downstream may reference a `LAB` object. Model output reaches `SERVE` only via a
dbt model that applies tests. Streamlit never reads `RAW`, `CORE` or `LAB`.

`LAB` is `TRANSIENT` — no Fail-safe, cheaper, and its disposability is the point.

---

## 2. Ownership

| Technology | Owns | Does not own |
|---|---|---|
| Snowflake native (pipes, streams, tasks, dynamic tables) | `LAND` → `RAW`, all scheduling | any business logic |
| **dbt** | `RAW` → `CORE` → `MART`, and `LAB` → `SERVE` promotion | ingestion, training |
| **Snowpark** | `LAB` (features, training, scoring, UDFs) + dbt Python models in `MART` | anything expressible in SQL |
| **Streamlit in Snowflake** | `SERVE` only | `RAW`, `CORE`, `LAB` |
| **Cortex** | text enrichment in `CORE`, NL query over `MART` | — |

Boundary test: if a rule can be written in SQL, dbt owns it. If it needs sklearn or
row-wise Python state, Snowpark owns it. If it needs a schedule, a Snowflake task owns
it — not cron, not Airflow.

---

## 3. Source system and volumes

Postgres 16 in Docker is the OLTP source: `dark_stores`, `customers`, `products`,
`riders`, `inventory`, `orders`, `order_items`. Debezium CDC via logical replication.
`REPLICA IDENTITY FULL` on every replicated table so the WAL carries full pre-images and
SCD2 can tell which attribute changed.

| Entity | Rows |
|---|---|
| dark_stores | 8 |
| products | 200 |
| customers | 500 |
| riders | 60 |
| orders (last 60 days) | 20,000 |
| order_items | ~55,000 |
| order status events | ~100,000 |
| rider GPS pings | ~200,000 |
| clickstream | ~50,000 |
| complaints (seed CSV) | 300 |

Money is **integer paise** everywhere — survives JSON, Kafka, `VARIANT` and Snowpark
without a rounding argument.

### Event contracts

`qc.order_status` — one event per lifecycle transition:
```json
{ "event_id": "uuid", "order_id": 918273, "store_id": 12, "rider_id": 4471,
  "from_status": "PACKED", "to_status": "PICKED_UP",
  "event_ts": "2026-09-08T14:22:31.412Z", "source": "rider_app",
  "meta": { "app_version": "4.11.2", "network": "4G" } }
```

`qc.rider_ping` — GPS, ~1 per rider per 5s, **keyed by `rider_id`** so a rider's pings
stay ordered inside one partition:
```json
{ "ping_id": "uuid", "rider_id": 4471, "order_id": 918273,
  "lat": 28.4595, "lon": 77.0266, "speed_kmph": 23.4, "battery_pct": 61,
  "event_ts": "2026-09-08T14:22:33.001Z" }
```

Three rules baked into both contracts:
1. `event_ts` is ISO-8601 UTC with milliseconds, stamped by the **producer**.
2. Every event carries its own idempotency key (`event_id` / `ping_id`) — Snowpipe
   Streaming is at-least-once, so dedupe is the consumer's job (`QUALIFY` in `CORE`).
3. Open-ended detail lives in a nested `meta` object, so a new field never breaks the
   contract or the `COPY`.

---

## 4. Ingestion inventory — 14 mechanisms

| # | Mechanism | Source | Lands in | Notes |
|---|---|---|---|---|
| 1 | **Snowpipe Streaming** via **Snowflake Kafka Connector v4** + Redpanda | `qc.rider_ping`, `qc.order_status` | `RAW` | Pin **v4** — built on the high-performance Snowpipe Streaming architecture (up to 10 GB/s, 5–10 s end-to-end, exactly-once and ordered). Earlier majors use the previous path. Schematization **OFF**; connector creates tables with `RECORD_METADATA` / `RECORD_CONTENT` |
| 2 | **Snowpipe Streaming SDK**, direct, no Kafka | order status events | `RAW` | Demonstrates channels and offset tokens |
| 3 | **Kafka connector in Snowpipe file mode** | same topic, second sink | `RAW` | Runs beside #1; latency and credit difference documented in `OPS`. **This comparison is a deliverable** |
| 4 | **Snowpipe auto-ingest** via Event Grid → Storage Queue | hourly gzipped NDJSON clickstream → `landing/` | `RAW` | |
| 5 | **Snowpipe REST-triggered** (`insertFiles`) | same clickstream, internal stage | `RAW` | Auto-ingest is unavailable on internal stages — showing both is the point |
| 6 | **Bulk `COPY INTO`** from the Azure stage | Parquet order backfill | `RAW` | Exercises `INFER_SCHEMA`, `MATCH_BY_COLUMN_NAME`, `ON_ERROR`, `VALIDATION_MODE` |
| 7 | **Schema evolution on `COPY`** | v2 backfill file gains `coupon_code` mid-load | `RAW` | `ENABLE_SCHEMA_EVOLUTION = TRUE`. Deliberate and documented |
| 8 | **External table** over `external/` + insert-only stream on it | 3PL settlement CSVs | queried in place | |
| 9 | **Iceberg table** on `EXVOL_QC` | archived order events | `archive/` | Snowflake-managed. **v3** if available, else v2 — document the difference |
| 10 | **Directory table + unstructured** | complaint PDFs/images in `docs/` | `LAND` stage | Feeds `AI_PARSE_DOCUMENT` |
| 11 | **External network access** from a Python proc | Open-Meteo weather per store lat/lon | `RAW` | Network rule + external access integration + secret. No external tool anywhere |
| 12 | **Marketplace / data sharing** | one free public dataset | shared DB | Zero-copy — ingestion with no ingestion |
| 13 | **`write_pandas`** | store→zone reference mapping | `RAW` | |
| 14 | **dbt seeds** | category hierarchy, SLA thresholds, complaints CSV | `RAW`/`CORE` | Version-controlled business constants |
| — | **Snowflake Postgres** | short burst, Part 14 | — | Replaces Docker Postgres for a demo only, then torn down |

Every `RAW` table carries `METADATA$FILENAME`, `METADATA$FILE_ROW_NUMBER`,
`METADATA$FILE_LAST_MODIFIED` and `LOAD_TS` where the mechanism allows — this is what
makes a bad load reversible without a full reload. **Dedupe in `CORE`, never `RAW`.**

### Azure containers → Snowflake objects

| Container | Used by | Role granted to the Snowflake SP |
|---|---|---|
| `landing` | Snowpipe auto-ingest (clickstream NDJSON.gz) | Storage Blob Data Reader |
| `archive` | Iceberg external volume `EXVOL_QC` | **Storage Blob Data Contributor** (writes) |
| `external` | External table (3PL settlement CSV) | Storage Blob Data Reader |
| `docs` | Directory table (complaint PDFs) | Storage Blob Data Reader |
| `snowpipe-queue` (queue, not container) | Event Grid → Snowpipe notification | Storage Queue Data Contributor |

Three Snowflake integration objects: `EXTERNAL VOLUME EXVOL_QC` (`ALLOW_WRITES = TRUE`),
one `STORAGE INTEGRATION` covering `landing/` + `external/` + `docs/`, one
`NOTIFICATION INTEGRATION TYPE = QUEUE NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE`.
Each needs `DESC` → `AZURE_CONSENT_URL` → tenant-admin consent → RBAC on the resulting
enterprise application. RBAC propagation ~5 min; do not debug before waiting.

**Gate:** `SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('EXVOL_QC');` must pass before any
Iceberg work.

### Not attempted: Snowflake Datastream
Announced at Summit 2026 — a Snowflake-native service speaking the full Kafka wire
protocol without Kafka underneath, landing topics as governed Snowflake or Iceberg
tables. **Private preview behind an interest form.** Not available on a trial, not
obtainable in two days. Covered in `docs/DATASTREAM.md` as prose, not code.

---

## 5. Streams — all five types

| Type | Tracks | Where | Why this one |
|---|---|---|---|
| Standard | inserts, updates, deletes with before-images | `CORE` SCD2 sources | SCD2 needs the before-image |
| **Append-only** | inserts only | `RAW.RIDER_PING` | Cheaper; pings are never updated |
| **Insert-only** | new files in an external table | 3PL settlement container | Only supported mode on external tables |
| On **directory table** | new files in a stage | complaint PDFs | Triggers `AI_PARSE_DOCUMENT` on arrival |
| On **view** | changes flowing through a view | `CORE` conformance layer | Change tracking without materialising the view |

---

## 6. SQL capabilities used deliberately

| Capability | Where it earns its place |
|---|---|
| **`ASOF JOIN`** | Attach each rider ping to the order-status event in force at that moment. Best natural fit in this dataset — the window-function version is 20 lines |
| **`MATCH_RECOGNIZE`** | Funnel `PLACED → PACKED → PICKED_UP → DELIVERED`; flag skipped or out-of-order transitions. Also rider dwell: a run of pings under 2 km/h |
| **`GEOGRAPHY` + `ST_DISTANCE` / `ST_DWITHIN`** | Run **alongside** the Snowpark haversine UDF; document the accuracy/cost difference |
| **H3** (`H3_LATLNG_TO_CELL`, `H3_GRID_DISK`) | Dark-store catchment; ping-density heatmap for Streamlit |
| **`VECTOR` + `EMBED_TEXT_768` + `VECTOR_COSINE_SIMILARITY`** | "Complaints similar to this one" — then compared honestly against Cortex Search |
| **`QUALIFY`** | Dedupe streaming events by `event_id` in one line |
| **`GENERATOR` + `SEQ4` + `UNIFORM`/`NORMAL`/`RANDOM`** | Generate pings and clickstream *inside* Snowflake. Saves an hour and shows a technique most people don't know exists |
| **`FLATTEN` / `LATERAL` / `PARSE_JSON` / `TRY_CAST` / `OBJECT_CONSTRUCT`** | Every `RAW → CORE` model |
| **`MERGE` + multi-table `INSERT`** | SCD2 upserts where dbt snapshots don't fit |
| **`TABLESAMPLE`** | Cortex cost control before any full-table AISQL call |
| **Recursive CTE** | Product category tree from the seed |

## 7. Pipeline mechanics used deliberately

| Capability | Notes |
|---|---|
| **Serverless vs warehouse tasks** | One DAG branch each way; credits compared in `OPS` |
| **`FINALIZER` task** | Runs after the DAG regardless of outcome — writes the run summary to `OPS.PIPELINE_LOG`. The correct way to log a DAG |
| **`SYSTEM$SET_RETURN_VALUE` / `SYSTEM$GET_PREDECESSOR_RETURN_VALUE`** | Pass row counts and watermarks between tasks |
| **`WHEN SYSTEM$STREAM_HAS_DATA(...)`** | Gates every task with a stream. Largest single credit saving in the design |
| **Snowflake Scripting** | The ingest error handler is a SQL proc with a cursor and `EXCEPTION` block, not Python |
| **`EXECUTE AS OWNER` vs `CALLER`** | The privilege model behind the secure-view substitute |
| **Table stage / user stage / named stage** | One line each — three stage types demonstrated |
| **`VALIDATE()` + `COPY_HISTORY`** | Post-load inspection after the deliberate bad-file test |
| **Clustering key + `SYSTEM$CLUSTERING_INFORMATION`** | On `FCT_RIDER_PING`. Record depth before and after |
| **Query tags + `QUERY_ATTRIBUTION_HISTORY`** | Credit attribution per component. Costs nothing |
| **Zero-copy clone + `UNDROP`** | Clone `MART` → `MART_DEV` for CI; recovery demo inside the 1-day window |

---

## 8. Dimensional model — `MART`

Built by dbt, surrogate keys via `dbt_utils`.

### Dimensions
| Dim | Type | Notes |
|---|---|---|
| `DIM_DATE` | static | Indian holiday flags from a seed |
| `DIM_CUSTOMER` | **SCD2** | segment, home_pincode |
| `DIM_PRODUCT` | **SCD2** | price, is_active |
| `DIM_STORE` | SCD1 | carries lat/lon |
| `DIM_RIDER` | **SCD2** | |
| `DIM_WEATHER_HOUR` | SCD1 | from mechanism 11 |
| `DIM_ORDER_STATUS` | static seed | canonical lifecycle order |

### Facts
| Fact | Grain | Type |
|---|---|---|
| `FCT_ORDER` | one row per order | **accumulating snapshot** — milestone timestamps as columns, lags between them, SLA breach flag, weather and Cortex complaint attributes |
| `FCT_ORDER_ITEM` | one row per order line | transaction |
| `FCT_ORDER_STATUS_EVENT` | one row per transition | transaction, from streaming |
| `FCT_RIDER_PING` | one row per ping | transaction, high volume, clustered on `(event_date, rider_id)` |
| `FCT_INVENTORY_DAILY` | store × product × day | **periodic snapshot** |
| `FCT_COMPLAINT` | one row per complaint | transaction, Cortex-enriched |

**Three fact patterns in one model — transaction, periodic snapshot, accumulating
snapshot — is a deliberate design point.** `FCT_ORDER` is the accumulating snapshot
because an order's row is rewritten as it walks the lifecycle; `FCT_ORDER_STATUS_EVENT`
keeps the immutable transition log beside it. Both exist on purpose: the snapshot answers
"how long from PACKED to PICKED_UP", the event table answers "which transitions were
skipped".

Max **2 dynamic tables** total, `TARGET_LAG >= 60 min`. First is
`SERVE.SLA_BY_STORE_HOUR`; the second is held for `MART` reserve.

---

## 9. Snowpark — promise-breach risk scoring

Predict, at order placement, whether the order will breach `promised_ts`.

Features in `LAB.FEAT_ORDER`: store load at order time · idle riders within 2 km ·
haversine store→customer distance · weather at placement hour · hour-of-week · basket
size and category mix · store trailing 7-day SLA rate.

| Step | Surface |
|---|---|
| Distance | Snowpark **UDF** (Python), callable from SQL and Python |
| Rider path smoothing + dwell detection | Snowpark **UDTF** |
| Preprocessing | Snowpark ML `OneHotEncoder`, `StandardScaler`, `Pipeline` — running *in* Snowflake, not in driver memory |
| Training | Snowpark **stored procedure**, sklearn `HistGradientBoostingClassifier` on `LAB.TRAIN_SET` |
| Versioning | **Model Registry**, with metrics and signature |
| Features | **Feature Store** — `FEAT_ORDER` registered properly, not left as a bare table |
| Scoring | **Vectorized UDF**, open orders every 30 min → `LAB.ORDER_RISK_SCORE` |
| Promotion | dbt model → `SERVE.ORDER_RISK` with `not_null`, `accepted_range` on probability, relationship test to `FCT_ORDER` |

Plus one **Snowpark pandas (Modin)** notebook, showing pandas semantics on warehouse
compute.

---

## 10. Cortex and ML Functions

| Feature | Use |
|---|---|
| `AI_CLASSIFY` | complaint text → reason code |
| `SENTIMENT` | complaint score |
| `AI_EXTRACT` | pull order id out of free text so complaints join to `FCT_ORDER` |
| `AI_PARSE_DOCUMENT` | complaint PDFs from the directory table — without this, mechanism #10 lands files nobody reads |
| `AI_FILTER` / `AI_AGG` / `AI_SUMMARIZE_AGG` | `AI_AGG` over a store's week of complaints → manager summary in the Streamlit app |
| `AI_SIMILARITY` / `AI_EMBED` | pairs with the `VECTOR` work |
| `SNOWFLAKE.ML.FORECAST` | store × category × day demand — no Python, so the two ML approaches can be compared |
| `SNOWFLAKE.ML.ANOMALY_DETECTION` | ping-volume anomalies per store |
| `SNOWFLAKE.ML.TOP_INSIGHTS` | automatic driver analysis: *why* did SLA drop last Tuesday |
| **Cortex Search** service | over complaint text — compared honestly against the hand-rolled `VECTOR` search |
| **Cortex Analyst** | over the `SEMANTIC` view |
| **Snowflake Copilot** | screenshot beside Cortex Analyst for comparison |

**Always sample first.** Cortex is the one meter that can run away. `LIMIT 200` or
`TABLESAMPLE` before every full-table AISQL call.

Post-Summit candidates (Semantic View Autopilot, Cortex Sense, Snowflake CoWork,
Horizon Context, Streaming Feature Views, model-version A/B, Observe by Snowflake) are
**UNVERIFIED** until `docs/AVAILABLE.md` is filled in by Part 0.

---

## 11. Streamlit in Snowflake — 4 tabs

| Tab | Reads | Writes |
|---|---|---|
| **Ops** | `SERVE.SLA_BY_STORE_HOUR` (dynamic table, 60 min lag), H3 density map | — |
| **Risk queue** | `SERVE.ORDER_RISK` joined to `FCT_ORDER`; dispatcher picks reassign / extend promise / issue credit | `SERVE.ACTION_LOG` |
| **Ask** | `SEMANTIC` view via Cortex Analyst (and CoWork if available) | logged questions |
| **Data health** | `OPS.DQ_RESULTS`, `OPS.PIPELINE_LOG` | — |

A dbt model joins `ACTION_LOG` back to outcomes so the app's own actions become a feature
for the next model run. **That closed loop is the point of the app — build it, don't
skip it.**

`QC_ANALYST` sees `SERVE` through secure views with `customer_email` SHA2-hashed and rows
filtered on `CURRENT_ROLE()` joined to an entitlements table.

---

## 12. Governance, ops and serving

| Concern | Mechanism |
|---|---|
| Alerts | Email notification integration + `SYSTEM$SEND_EMAIL`, fired from a Snowflake Alert on `OPS.DQ_RESULTS` failures |
| Lineage | `OBJECT_DEPENDENCIES` + Snowsight, compared against dbt's own graph |
| Cost | Query tags → `QUERY_ATTRIBUTION_HISTORY` → per-component credit report |
| Metadata layers | One query each against `ACCOUNT_USAGE`, `INFORMATION_SCHEMA`, `ORGANIZATION_USAGE`, documenting latency and retention differences |
| PII | Object tags applied by a Cortex-assisted classification proc, then secure views |
| Discovery | Horizon / Universal Search |
| Serving | **Reader account** — share `MART`, query as an external consumer; **private listing**; **Native App** wrapping the Streamlit app; **SQL API** |
| CI/CD | Snowflake Git integration + Workspaces; GitHub Actions runs `dbt build` against a clone on PR, `EXECUTE DBT PROJECT` on merge; `EXECUTE IMMEDIATE FROM` for SQL-file deploys |

Substitutions forced by Standard Edition are listed in `CLAUDE.md` §2.2 and are a
documented finding of this PoC, not a workaround to hide.

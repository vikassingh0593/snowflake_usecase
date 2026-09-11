# Quick-Commerce Analytics Platform — Architecture

Companion to `docs/ARCHITECTURE.md` (engineering detail) and `docs/PROGRESS.md`
(build log). This document states what the platform is and what has been built.
Technology is named generically, with the specific product in brackets.

**Status: ingestion complete at 13 of 14 routes. Cleaning and conformance complete.**

---

## 1. Purpose

An analytics platform for a quick-commerce operator — dark stores fulfilling
grocery orders against a delivery promise of 10 to 25 minutes.

| Question | Consumer |
|---|---|
| Which orders in flight will breach their promise? | Dispatcher |
| Which stores miss their promise, at which hours? | Operations |
| Why did the on-time rate move? | Regional management |
| How much stock will each store need? | Supply planning |
| What are customers complaining about? | Customer experience |
| Who may see customer contact details? | Compliance |

Operator decisions on at-risk orders are captured as data and become training
input for later model versions.

---

## 2. Domain and scale

| Entity | Volume |
|---|---|
| Dark stores | 8 (Delhi NCR) |
| Riders | 60 |
| Customers | 500 |
| Products | 200 across 4 categories, 3-level hierarchy |
| Orders | 20,000 over 60 days |
| Order lines | 54,635 |
| Stock snapshots | 96,000 |
| Order status events | 79,663 |
| SLA breach rate | 16.4% |

**Monetary values are stored as integer paise.** No decimal currency anywhere in
the pipeline.

**Deliberate data defects**, injected at generation so downstream handling is
exercised rather than assumed: 1% duplicate events (at-least-once delivery), 2%
skipped or out-of-order status transitions.

---

## 3. Layer architecture

| Layer | Schema | Contents | Rule |
|---|---|---|---|
| Landing | `LAND` | Stages, file formats, pipes, integrations | No data at rest |
| Raw | `RAW` | Data exactly as it arrived | Append-only. No dedupe, no casting, no joins |
| Core | `CORE` | Deduplicated, conformed, SCD2 history | Single place where duplicates are resolved |
| Mart | `MART` | Dimensional model in business vocabulary | Star schema |
| Lab | `LAB` | Experiments, feature engineering, model training | Transient. Unpoliced |
| Serve | `SERVE` | Governed, quality-gated published output | Nothing reaches a consumer without passing tests |
| Semantic | `SEMANTIC` | Metric definitions | |
| App | `APP` | Embedded application objects | |
| Ops | `OPS` | Benchmarks, cost attribution, quality results | |

`LAB` is a sandbox; `SERVE` is a contract. Promotion between them is gated on
automated quality tests.

---

## 4. Component inventory

| Role | Generic technology | Product used |
|---|---|---|
| Operational database | Relational OLTP | PostgreSQL 16 (logical replication) |
| Change data capture | CDC connector | Debezium (`pgoutput`) |
| Event broker | Kafka | Redpanda (Kafka API compatible) |
| Broker → warehouse | Kafka sink connector | Snowflake Kafka Connector v4.1.0 and v3.5.4 |
| Streaming client | Row-level streaming SDK | Snowpipe Streaming SDK |
| Object storage | Cloud blob storage | Azure Blob Storage (GPv2, hierarchical namespace off) |
| Storage event notification | Event bus → queue | Azure Event Grid → Azure Storage Queue |
| Managed file ingestion | Continuous file loader | Snowpipe (auto-ingest and REST) |
| Open table format | Open columnar table format | Apache Iceberg v3 |
| Data warehouse | Cloud data warehouse | Snowflake (AWS `us-west-2`) |
| Transformation framework | SQL transformation + testing | dbt |
| In-warehouse compute | DataFrame / UDF runtime | Snowpark (Python) |
| Machine learning | Classical ML | `SNOWFLAKE.ML` functions and scikit-learn in Snowpark |
| Document parsing | PDF text extraction | `pypdf` in a Python UDF |
| Application layer | Embedded data app | Streamlit in Snowflake |
| CI/CD | Pipeline automation | GitHub Actions + Snowflake Git integration |
| Container runtime | Local containers | Docker Compose |

Three components run in containers rather than on the workstation — the
streaming SDK, the DataFrame loader and dbt — because their dependencies have no
wheels for the workstation's CPU architecture.

---

## 5. Object storage layout

| Container | Purpose | Access granted to the warehouse |
|---|---|---|
| `landing` | Files awaiting continuous ingestion | Read |
| `archive` | Open-format table storage | **Read and write** |
| `external` | Partner files queried in place | Read |
| `docs` | Unstructured documents | Read |
| `snowpipe-queue` | Storage event notifications | Queue contributor |

Least privilege by container. The warehouse can write to exactly one of them.
Two separate service principals: one for blob access, one for queue access.

---

## 6. Ingestion routes

Thirteen distinct paths carry data into the platform. Each exists because a
different constraint makes the others wrong.

| # | Route | Implementation | Target | Rows |
|---|---|---|---|---|
| 1 | Kafka → warehouse, streaming | Kafka connector v4, row-level streaming | `RAW.ORDER_STATUS_KAFKA_V4` | 79,663 |
| 2 | Direct streaming, no broker | Streaming SDK, channels and offset tokens | `RAW.ORDER_STATUS_SDK` | 79,663 |
| 3 | Kafka → warehouse, micro-batch files | Kafka connector v3, file mode | `RAW.ORDER_STATUS_KAFKA_V3FILE` | 79,663 |
| 4 | Storage notifies the warehouse | Snowpipe auto-ingest via Event Grid queue | `RAW.CLICKSTREAM_AUTO` | 10,051 |
| 5 | Client notifies the warehouse | Snowpipe REST `insertFiles`, internal stage | `RAW.CLICKSTREAM_REST` | 8,097 |
| 6 | Bulk historical load | `COPY` with schema inference | `RAW.ORDER_BACKFILL` | 40,000 |
| 7 | Source schema change absorbed | Schema evolution on `COPY` | same table | +1 column |
| 8 | Query files without loading | External table + insert-only stream | `RAW.EXT_SETTLEMENT` | 2,800 |
| 9 | Open-format archive | Iceberg v3 on an external volume | `RAW.ORDER_EVENTS_ICEBERG` | 79,038 |
| 10 | Unstructured documents | Directory table + PDF extraction UDF | `RAW.COMPLAINT_DOC` | 300 |
| 11 | Outbound API call from the warehouse | External access integration | — | **not available** |
| 12 | Shared dataset, zero copy | Marketplace share, queried live | `RAW.V_FX_INR_USD` | 15,683 |
| 13 | DataFrame to table | `write_pandas`, table created from dtypes | `RAW.DIM_STORE_SEED` | 8 |
| 14 | Version-controlled constants | dbt seeds with tests | 4 tables | 125 |

Routes 1, 2 and 3 carry **identical input** so their latency and cost can be
compared with the data held constant. That comparison is the deliverable, not
the ingestion.

Route 11 is refused by the account tier. See §10.

---

## 7. Data currently in the platform

| Layer | Rows | Contents |
|---|---|---|
| `RAW` | ~548,000 | 21 tables, exactly as arrived. Includes 171,403 CDC rows |
| `CORE` | 270,497 | 12 tables, typed, deduplicated, versioned |
| Queried in place | 2,800 | Partner files, never copied |
| Read live from a publisher | 15,683 | Marketplace share, never stored |
| `MART`, `SERVE`, `LAB` | **0** | Not started |

`CORE` in detail:

| Table | Rows | Note |
|---|---|---|
| `INVENTORY_DAILY` | 96,000 | store × product × day |
| `ORDER_STATUS_EVENT` | 78,874 | deduplicated from 79,663 |
| `ORDER_ITEM` | 54,635 | |
| `ORDER_HEADER` | 20,000 | |
| `ORDER_FUNNEL` | 19,029 | complete lifecycles |
| `ORDER_CANCELLED` | 623 | |
| `ORDER_LIFECYCLE_ANOMALY` | 348 | defective sequences, classified |
| `DIM_PRODUCT` | 220 | 200 current + 20 historical versions |
| `CUSTOMER` / `PRODUCT` / `RIDER` / `STORE` | 500 / 200 / 60 / 8 | |

Every order appears in exactly one of funnel, cancelled or anomaly:
**19,029 + 623 + 348 = 20,000**.

The three order-status tables in `RAW` still hold the same events three times
over. That is deliberate — it is what makes the ingestion comparison valid — and
`CORE` resolves it by taking one as canonical, which is defensible because all
three were proved to carry identical event sets.

---

## 8. Access model

| Role | Grants |
|---|---|
| `QC_ADMIN` | Owns the database |
| `QC_LOADER` | Writes `LAND` and `RAW` only |
| `QC_ENGINEER` | Full access to transformation and lab schemas |
| `QC_ANALYST` | `SERVE` and `SEMANTIC` views only. No base-table access anywhere |

Two service accounts, both typed as service accounts and both **key-pair
authentication only**. No password exists in any file or configuration. Private
keys are excluded from version control.

Planned governance builds each control two ways — attached to the data (column
and row policies) and approximated through restricted views — and compares them.

---

## 9. Cost controls

| Control | Setting |
|---|---|
| Compute clusters | 3 × extra-small, never resized |
| Idle shutdown | 60 seconds |
| Resource monitor | 60 credits, notify at 50/75/90%, suspend at 100% |
| Data retention | 1 day |
| Statement timeout | 600 seconds |
| Attribution | Every session tagged; every route's spend separable |
| Account budget | **Not configured** |

The resource monitor covers warehouse compute only. Continuous ingestion,
serverless refresh and search optimization are invisible to it; an account
budget is the only control that sees them.

Confirmed spend: 3.78 credits. That figure predates all ingestion work.

---

## 10. Platform constraints

Three properties of this account shaped the design. All three were established by
attempting the operation, not by reading a privileges listing.

| Constraint | Consequence |
|---|---|
| **Managed AI text functions unavailable** — account tier | Complaint classification, sentiment and embeddings are built as trained models running in the warehouse rather than called as a managed service |
| **Enterprise-grade governance available** | Protection attaches directly to columns and rows; the restricted-view approximation is built alongside for comparison rather than out of necessity |
| **Outbound network access unavailable** — account tier | Route 11 cannot be built. The network rule and the secret both create successfully; only the integration that binds them to a function is refused |

Route 11's payload was weather per store. Nothing downstream depends on it — the
risk model's features are distance, hour of day, store load, basket size and
rider assignment. The route is kept in the repository as design, not deleted.

---

## 11. Build status

| Stage | Status |
|---|---|
| Capability assessment | Complete |
| Source systems | Complete |
| Object storage and access | Complete |
| Warehouse foundation | Complete |
| **Ingestion** | **Complete — 13 of 14 routes** |
| **Cleaning and conformance** (`CORE`) | **Complete** |
| Dimensional model (`MART`) | Not started |
| Risk scoring | Not started |
| Forecasting and text analysis | Not started |
| Application layer | Not started |
| Governance | Not started |
| Outbound sharing | Not started |

---

## 12. Repository

| Path | Contents |
|---|---|
| `docs/OVERVIEW.md` | This document |
| `docs/ARCHITECTURE.md` | Engineering design and as-built identifiers |
| `docs/PROGRESS.md` | Build log |
| `source/` | Container stack, database schema, data generators, CDC configuration |
| `sql/` | Warehouse DDL and ingestion routes, by part |
| `scripts/` | Cloud resource provisioning, connector setup, container runners |
| `dbt/` | Transformation project and version-controlled seeds |

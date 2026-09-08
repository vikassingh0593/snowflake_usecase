# Runbook — build parts and exit criteria

**One part at a time. Finish it, verify it, report, then wait for the go-ahead on the
next.** Budget: 2 calendar days, ~16 working hours. Time is the binding constraint, not
cost. If a part runs >30 min over its share, say so immediately and propose a
**reordering** — never a cut.

Legend: ⬜ not started · 🟡 in progress · ✅ done · ⛔ blocked

| Part | Status | Contents | Exit criteria |
|---|---|---|---|
| **0** | ⬜ | **Feature probe.** Availability checks, Snowsight nav screenshots, write `docs/AVAILABLE.md`. **Before anything else** — it decides Parts 10, 12, 13 | `docs/AVAILABLE.md` committed with every verdict filled |
| **1** | ⬜ | Azure resources (RG, GPv2 SA, 4 containers, queue, Event Grid), Snowflake bootstrap (db, schemas, warehouses), RBAC, budget + resource monitor, query-tag convention, 3 integrations consented | `SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('EXVOL_QC')` green |
| **2** | ⬜ | Docker: Postgres 16, Redpanda, Kafka Connect + Debezium + Snowflake sink **v4**. Python data generator + the in-Snowflake `GENERATOR` variant | producers running, topics populated |
| **3** | ⬜ | Ingestion A — streaming: mechanisms 1, 2, 3 | rows in `RAW`; latency/credit comparison recorded in `OPS` |
| **4** | ⬜ | Ingestion B — files: mechanisms 4, 5, 6, 7, plus `VALIDATE()` and `COPY_HISTORY` | schema evolution demonstrated on a real bad file |
| **5** | ⬜ | Ingestion C — lake and API: mechanisms 8, 9, 10, 11, 12, 13, 14 | all 14 mechanisms have landed data |
| **6** | ⬜ | All five stream types; task DAG with serverless-vs-warehouse comparison, `FINALIZER`, return values, Snowflake Scripting error handler | DAG runs end to end |
| **7** | ⬜ | dbt `RAW` → `CORE`: `QUALIFY` dedupe, SCD2 snapshots, `MERGE` upserts, tests, source freshness | `dbt build` green |
| **8** | ⬜ | dbt `CORE` → `MART`: star schema, `ASOF JOIN`, `MATCH_RECOGNIZE`, `GEOGRAPHY` + H3, clustering, 2 dynamic tables | all facts and dims populated and tested |
| **9** | ⬜ | Snowpark: UDF, UDTF, vectorized UDF, ML preprocessing, training sproc, Model Registry, Feature Store, `LAB` → `SERVE` promotion | `SERVE.ORDER_RISK` populated and tested |
| **10** | ⬜ | Cortex: AISQL suite, `AI_PARSE_DOCUMENT`, `VECTOR` search, Cortex Search, FORECAST, ANOMALY_DETECTION, TOP_INSIGHTS, semantic view (Autopilot if available), Cortex Analyst, CoWork if available | Ask tab answers a real question |
| **11** | ⬜ | Streamlit: 4 tabs, H3 map, write-back loop, and the dbt model that turns actions into a feature | app usable end to end |
| **12** | ⬜ | Governance: secure views, tags, query attribution, alerts + email, `OBJECT_DEPENDENCIES`, metadata-layer comparison | alert fires on a seeded DQ failure |
| **13** | ⬜ | Serving: reader account, private listing, Native App, SQL API | external consumer queries `MART` |
| **14** | ⬜ | Bursts: Snowflake Postgres, hybrid table for `ACTION_LOG`. Tear both down **immediately** | screenshots taken, objects dropped |
| **15** | ⬜ | CI/CD: Git integration, GitHub Actions `dbt build` against a clone | PR check green |
| **16** | ⬜ | Write-ups: `docs/DEMO.md` walkthrough, credit report from `QUERY_ATTRIBUTION_HISTORY`, `docs/DATASTREAM.md` — Datastream vs Kafka-connector-v4, what changes when the broker disappears, where the Kafka protocol still earns its place | all docs committed |
| **17** | ⬜ | Teardown: run `teardown.sql` and `teardown.sh`, confirm zero remaining spend | account and Azure RG empty |

---

## Per-part close-out checklist

Run these four before reporting a part done:

1. `docs/CREDITS.md` — append actual credits from `WAREHOUSE_METERING_HISTORY` and
   `METERING_HISTORY` for the part's window.
2. `teardown.sql` / `teardown.sh` — add every object created in this part.
3. `docs/RUNBOOK.md` — flip the status cell.
4. Commit with the part number in the subject: `part N: <what>`.

## Standing gates

| Gate | Blocks |
|---|---|
| `docs/AVAILABLE.md` complete | everything |
| `SYSTEM$VERIFY_EXTERNAL_VOLUME('EXVOL_QC')` green | all Iceberg work (mechanism 9) |
| Azure RBAC propagated (~5 min after grant) | integration verification — wait before debugging |
| Resource monitor `RM_POC` **and** account Budget both live | any warehouse resume beyond Part 1 |
| `RAW` populated for a mechanism | the dbt model that reads it |
| `SERVE` model tested | the Streamlit tab that reads it |

## Reordering options if time runs short

Priority is breadth of *distinct* capabilities, so drop duplication before dropping a
capability. In order of what to defer first:

| Defer | Loses | Keeps |
|---|---|---|
| Part 13 reader account + private listing | two sharing surfaces | Native App + SQL API still demonstrate serving |
| Part 14 Snowflake Postgres burst | one screenshot | hybrid table burst still shows the always-on trade-off |
| Mechanism 5 (REST-triggered pipe) | internal-stage contrast | auto-ingest still proves Snowpipe |
| Part 15 GitHub Actions | CI proof | Git integration + `EXECUTE IMMEDIATE FROM` still show deployment |

Never defer: Part 0, the `LAB` → `SERVE` contract, the closed loop in Part 11, or the
Kafka-v4-vs-file-mode comparison in Part 3 — each is a stated deliverable.

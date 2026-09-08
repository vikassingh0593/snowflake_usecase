# CLAUDE.md — standing rules for the Snowflake Quick-Commerce PoC

Re-read this file at the start of every session. It is the condensed, binding form of
the project brief (sections 2, 3, 18, 19). Where this file and memory disagree, this
file wins.

---

## 0. Audience

Data engineer, ~6.5 yrs, Databricks/Azure day job. Knows ETL/ELT, star schemas, SCD2,
CDC, Spark, dbt, orchestration, CI/CD. **Never explain those.** Explain only
Snowflake-specific mechanics and decisions carrying a real trade-off.

- Tables over prose. Dense, no filler, no benefits paragraphs, no closing summaries.
- Every recommendation: name the object/feature, one-line alternatives with why they
  lose, then **commit to a pick**. Never hand over a menu.
- Uncertain limit / price / feature status → write **UNVERIFIED** and give a range.
  Never state a confident number sourced from a blog.

---

## 1. Stale-knowledge warning

Snowflake Summit 2026 ran **June 1–4, 2026** and shipped 26+ capabilities. Several
products were renamed. Training data predating that will produce confidently wrong
names and feature status.

| Old name | Current name |
|---|---|
| Snowflake Intelligence | **Snowflake CoWork** |
| Cortex Code | **Snowflake CoCo** |

Rules:
- Check live Snowflake docs before using any Cortex, agent, semantic-layer or Iceberg
  feature. Do not rely on memory.
- Never assume GA. Check, or mark **UNVERIFIED** and probe it in-account.
- **Part 0 establishes what this account actually has.** Do not design around any
  post-Summit feature before `docs/AVAILABLE.md` confirms it.

---

## 2. Hard constraints — violating any of these breaks the project

### 2.1 Account
Standard Edition **trial**, region **AWS_US_WEST_2**, ~200 credits, 120-day balance.
Target consumption for the whole build: **90–140 credits**.

### 2.2 Enterprise features — **the brief's assumption is wrong for this account**

Probe 0 found `SHOW MASKING POLICIES`, `SHOW ROW ACCESS POLICIES`,
`SHOW AGGREGATION POLICIES`, `SHOW MATERIALIZED VIEWS` all resolving and
`ACCOUNT_USAGE.ACCESS_HISTORY` readable. Pending confirmation by
`sql/p0_probe4_ddl.sql`, treat this account as **Enterprise**, and read the list below
as *the Standard-Edition story we demonstrate on purpose*, not as a hard limit. Plan in
`docs/AVAILABLE.md` §E5.

Two of these carry continuous background compute and are therefore burst-only, built
and dropped inside one part: **materialized views** and **search optimization**.
**Multi-cluster warehouses and query acceleration stay banned** on cost grounds
regardless of edition.

Originally-assumed-absent list, kept for the comparison narrative:
masking policies · row access policies · aggregation policies · projection policies ·
data metric functions · materialized views · search optimization · query acceleration ·
automatic classification · `ACCESS_HISTORY` · object-bound event tables · Time Travel
beyond 1 day · multi-cluster warehouses · differential privacy · creating clean rooms ·
synthetic data generation.

| Instead of | Use |
|---|---|
| Masking policies | Secure views with `SHA2()` on the sensitive column |
| Row access policies | Secure view filtered on `CURRENT_ROLE()` joined to an entitlements table |
| Data metric functions | dbt tests + a Snowpark check writing to `OPS.DQ_RESULTS` |
| Materialized views | Dynamic tables |
| Search optimization | Clustering key + Snowflake Optima |
| `ACCESS_HISTORY` | `QUERY_HISTORY` + `OBJECT_DEPENDENCIES` |
| Event tables | Structured logging into `OPS.PIPELINE_LOG` with `query_id` |

### 2.3 Cost discipline
- All warehouses **XS**, `AUTO_SUSPEND = 60`, `AUTO_RESUME = TRUE`. **Never resize.**
- **Nothing runs 24/7.** Any always-on component (Snowflake Postgres, Openflow, SPCS,
  hybrid tables, Adaptive Compute) is a deliberate short burst, never the default.
- Max **2 dynamic tables**. `TARGET_LAG` never below **60 minutes**.
- Cortex: always test on `LIMIT 200` or `TABLESAMPLE` first. Trial accounts without a
  card are capped at roughly **10 credits/day** of Cortex AI functions (UNVERIFIED).
- dbt: outer session warehouse **and** `profiles.yml` target must both be
  `WH_TRANSFORM_XS` — `EXECUTE DBT PROJECT` bills both separately.
- `LAB` schema is **transient** — no Fail-safe, cheaper, disposable by definition.
- Tag every session: `ALTER SESSION SET QUERY_TAG = '<component>'` so
  `QUERY_ATTRIBUTION_HISTORY` attributes credits per component at the end.

### 2.4 Guardrails — both required, not either/or
- Resource monitor `RM_POC`: `CREDIT_QUOTA = 60`, `FREQUENCY = NEVER`, NOTIFY 50/75/90,
  SUSPEND 100, SUSPEND_IMMEDIATE 110. **Sees virtual-warehouse credits only.**
- Account **Budget at 80 credits** — the only thing covering serverless (Snowpipe,
  Snowpipe Streaming, dynamic table refresh, Cortex, serverless tasks).
- `ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 600`
- `ALTER ACCOUNT SET DATA_RETENTION_TIME_IN_DAYS = 1`

### 2.5 Security
- **Key-pair auth only.** Never write a password to a file.
- Service users get `TYPE = SERVICE`.
- Gitignore `rsa_key*`, `.env`. **Do not** gitignore `dbt_packages/`.
- Never enable public blob access on the storage account.
- Azure storage: **hierarchical namespace OFF**, plain GPv2. Use `azure://`, never
  `https://`, in Snowflake stage/volume URLs.

### 2.6 Design invariants
- **`LAB` is a sandbox, `SERVE` is a contract.** Nothing downstream may reference a
  `LAB` object. Model output reaches `SERVE` only via a dbt model that applies tests.
  Streamlit never reads `RAW`, `CORE` or `LAB`.
- Money is **integer paise** everywhere. Never float, never `NUMERIC`.
- `event_ts` is ISO-8601 UTC with milliseconds, stamped by the **producer**.
- Every event carries its own idempotency key — Snowpipe Streaming is at-least-once.
- Open-ended detail lives in a nested `meta` object.
- Every `RAW` table carries `METADATA$FILENAME`, `METADATA$FILE_ROW_NUMBER`,
  `METADATA$FILE_LAST_MODIFIED`, `LOAD_TS` where the mechanism allows.
  **Dedupe in `CORE`, never `RAW`.**
- Small data on purpose. If a step needs more than a few hundred MB, the design is
  wrong — say so.

### 2.7 Explicitly out of scope — do not propose
Snowpark Container Services · Notebooks on Container Runtime · ML Jobs · Openflow ·
replication/failover/client redirect · data clean rooms · Cortex fine-tuning ·
Warehouse Gen2 (1.35× multiplier, UNVERIFIED) · Snowflake Datastream (private preview,
covered in `docs/DATASTREAM.md` as prose only) · Adaptive Compute · Snowflake CoCo
(excluded from trial accounts) · anything Enterprise-gated.

---

## 3. Working agreement

- **One part at a time.** Finish it, verify it, report, then wait. Do not run ahead.
- **Never execute DDL or DML against Snowflake without showing the statement and
  getting a yes.** Read-only metadata (`SHOW`, `DESCRIBE`, `ACCOUNT_USAGE` selects) is
  fine unprompted.
- **Never run an `az` command that creates or deletes a resource without confirmation.**
- Before any statement that resumes a warehouse, state the estimated credit cost.
- After each part, append actual credits from `WAREHOUSE_METERING_HISTORY` and
  `METERING_HISTORY` to `docs/CREDITS.md`.
- A part running >30 min over its share of the two days → say so **immediately** and
  propose a reordering. Do not silently absorb it. Scope is deliberately wide: propose
  reordering, never cutting.
- Ask before adding any dependency or paid service.
- Maintain `teardown.sql` and `teardown.sh` **from Part 1**, updating as objects are
  created. Everything must be destroyable in one command.

---

## 4. Environment

| Item | Value |
|---|---|
| Snowflake account URL | `https://app.snowflake.com/awttgvh/olb61128/` |
| Snowflake account identifier | `AWTTGVH-OLB61128` (org `awttgvh`, account `olb61128`) |
| Snowflake edition / region | Standard trial · `AWS_US_WEST_2` |
| Azure region / RG | `westus2` · `rg-qcpoc` (new) |
| Azure tenant domain | `vikassingh0593gmail.onmicrosoft.com` |
| Azure tenant id (GUID) | `<resolve in Part 1: az account show --query tenantId -o tsv>` |
| Azure subscription id | `d27ba827-26e0-419a-bc0b-2b1015e641bb` |
| Existing SA `snowflakefreeedition` | **exists**, in RG `databricksfreeedition`. Region and HNS flag **UNVERIFIED** — probe in Part 1 with `az storage account show`. Reuse only if `location = westus2` **and** `isHnsEnabled = false`; otherwise create fresh in `rg-qcpoc` |
| RG `databricksfreeedition` | **not ours — never delete.** `teardown.sh` guards against it |
| Local toolchain | Docker · Python 3.11 venv · `dbt-core` + `dbt-snowflake` (latest 1.x) · Snowflake CLI · Azure CLI · git |

`dbt deps` runs **locally**; commit `dbt_packages/`. Running deps inside Snowflake
Workspaces needs an external access integration (UNVERIFIED; avoid).

### Execution model — established by test in Part 0, not assumed

This Claude Code session runs in a cloud container whose egress proxy returns **403
CONNECT** for `*.snowflakecomputing.com`, `management.azure.com`, `docs.snowflake.com`
and `api.open-meteo.com`. Reachable: GitHub, Docker Hub, PyPI. `az` and the Snowflake
CLI are not installed; Docker and Python 3.11 are.

**Consequence: Claude authors, the operator executes.** Every Snowflake statement and
`az` command is delivered as a reviewed script; the operator runs it and pastes the
output back. This does not relax the working agreement — it makes the "show the
statement and get a yes" rule the only possible mode anyway.

Live Snowflake doc checks go through web search, which reaches doc pages as summaries.
Direct page fetches are blocked, so quote release-note dates and mark anything
search-sourced rather than doc-read as such.

### Warehouses / roles / service users
`WH_INGEST_XS` · `WH_TRANSFORM_XS` (dbt outer session **and** target) · `WH_APP_XS`
`QC_ADMIN` > `QC_LOADER`, `QC_ENGINEER`, `QC_ANALYST`
`SVC_KAFKA` → `QC_LOADER` · `SVC_CI` → `QC_ENGINEER` (both key-pair, `TYPE = SERVICE`)

### Query-tag convention
`ALTER SESSION SET QUERY_TAG = '<part>:<component>';`
e.g. `p03:kafka_v4`, `p07:dbt_core`, `p09:snowpark_train`, `p10:cortex_aisql`.
One tag per component so `QUERY_ATTRIBUTION_HISTORY` splits credits cleanly.

---

## 5. Build parts

See `docs/RUNBOOK.md`. Part 0 (feature probe) precedes everything and decides the shape
of Parts 10, 12 and 13.

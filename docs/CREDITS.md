# Credit ledger

Budget: **90–140 credits** of a ~200-credit, 120-day trial balance.
Guardrails: resource monitor `RM_POC` at 60 credits (warehouse credits only) + account
Budget at 80 credits (the only thing covering serverless).

Append one row per part **after** it completes. Sources:

```sql
-- warehouse credits for the part window
SELECT warehouse_name, SUM(credits_used) AS credits
FROM   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE  start_time >= '<part start>' AND start_time < '<part end>'
GROUP  BY 1 ORDER BY 2 DESC;

-- serverless + cloud services (Snowpipe, streaming, DT refresh, Cortex, tasks)
SELECT service_type, SUM(credits_used) AS credits
FROM   SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE  start_time >= '<part start>' AND start_time < '<part end>'
GROUP  BY 1 ORDER BY 2 DESC;

-- per-component attribution, via the query tags
SELECT query_tag, SUM(credits_attributed_compute) AS credits
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE  start_time >= '<part start>'
GROUP  BY 1 ORDER BY 2 DESC;
```

`ACCOUNT_USAGE` latency is up to ~3 h for metering views — record the reading time, and
re-read at the end of the build for the Part 16 report.

## Ledger

| Part | Budgeted | Actual WH | Actual serverless | Total | Delta | Notes |
|---|---|---|---|---|---|---|
| 0 — feature probe | 1 | | | | | authoring + doc checks: **0 consumed so far** (no account access from the build container). `sql/p0_probe.sql` estimated 0.03–0.07 WH credits + ~11 single-row AI calls |
| 1 — bootstrap | 3 | | | | | |
| 2 — docker + generators | 2 | | | | | local compute; Snowflake side is `GENERATOR` only |
| 3 — streaming ingest | 12 | | | | | serverless-heavy: Snowpipe Streaming + file mode side by side |
| 4 — file ingest | 6 | | | | | |
| 5 — lake + API ingest | 8 | | | | | Iceberg writes + external network access |
| 6 — streams + task DAG | 8 | | | | | serverless vs warehouse task comparison |
| 7 — dbt RAW→CORE | 10 | | | | | outer session **and** dbt target both billed |
| 8 — dbt CORE→MART | 14 | | | | | includes 2 dynamic table refreshes |
| 9 — Snowpark ML | 18 | | | | | training sproc is the single largest warehouse item |
| 10 — Cortex | 20 | | | | | trial AISQL cap ~10 credits/day (UNVERIFIED) — sample first |
| 11 — Streamlit | 6 | | | | | `WH_APP_XS`, interactive |
| 12 — governance | 3 | | | | | |
| 13 — serving | 5 | | | | | reader account bills to this account |
| 14 — bursts | 6 | | | | | Snowflake Postgres + hybrid table, always-on while up |
| 15 — CI/CD | 4 | | | | | clone is zero-copy; `dbt build` on it is not |
| 16 — write-ups | 1 | | | | | |
| 17 — teardown | 1 | | | | | |
| **Total** | **128** | | | | | headroom to 140 = 12 credits |

## Running total

| Checkpoint | Credits consumed | Balance remaining | Date |
|---|---|---|---|
| Start | 0 | ~200 | |

## Overruns and their cause

| Part | Over by | Cause | Action taken |
|---|---|---|---|

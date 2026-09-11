# Build log

Newest first. Each entry records what was built, what broke, and what that cost —
because the mistakes are the part worth carrying forward.

---

## Session 1 — 2026-09-09

Foundation complete on all three sides. No data has moved into Snowflake.

### Built

| | |
|---|---|
| Source system | Postgres 16 + Debezium + Redpanda + Console, running in Docker on the Mac |
| Data | 20,000 orders · 54,635 lines · 96,000 stock snapshots · 79,663 events · 16.4% breach |
| Azure | `snowflakeqcpoc25056` in `rg-qcpoc`/`westus2` · 4 containers · queue · Event Grid · lifecycle |
| Snowflake | `QCOMMERCE` · 9 schemas · 3 XS Gen1 warehouses · 4 roles · 2 service users · `RM_POC` at 60 |
| Integrations | External volume, storage integration, notification integration — all consented and verified |

### Two findings that reshaped the plan

**Cortex AI functions are unavailable on this account.** Both required grants are
present — `USE AI FUNCTIONS` at account level and the `SNOWFLAKE.CORTEX_USER`
database role — and the calls still fail with *"AI function AI_CLASSIFY is not
available for trial accounts."* Nine of eleven AISQL functions fail identically.
Everything downstream of an LLM goes with it: Cortex Search, Cortex Analyst,
CoWork, and Semantic View Autopilot. Only converting to a paid account lifts it.

Part 10 was rebuilt around `SNOWFLAKE.ML` classical functions, an sklearn
classifier trained in Snowpark and versioned in Model Registry, `pypdf` for
documents, and a feature-hashing vectoriser feeding `VECTOR` search.

**The account is Enterprise-shaped, not Standard**, which the brief assumed.
Masking policies, row access policies, aggregation policies and materialized
views all resolve; `ACCESS_HISTORY` reads. Governance now builds every control
twice — the policy way and the view way — and compares them. Still unproven by a
`CREATE`; see the open items.

### Mistakes made, and what each cost

| What | Cost | Lesson |
|---|---|---|
| Edition probed with `SHOW DATA METRIC FUNCTIONS` and an `ACCOUNT_USAGE` view that exist on every edition | One wrong conclusion, corrected | A `SHOW` that returns an empty set proves nothing. Probe with something that rejects |
| Generator named the ride-duration variable `total`, shadowing the money `total` | A failed `COPY` and a reload | Verified CSV headers matched the DDL and called it checked. `\copy` loads positionally and ignores header names, so a header check says nothing about content. The generator now validates every value against its column type |
| Money as `BIGINT` paise | — | Caught the bug immediately. `NUMERIC` would have loaded `11.94` silently and surfaced as nonsense revenue in Part 8 |
| `ENABLE_DEBEZIUM_SCRIPTING` with a read-only plugin mount | Kafka Connect exited before its API started | `docker compose ps` showing a blank STATUS was the signal; the empty plugin list looked like slow boot |
| Azure script minted `snowflakeqcpoc$RANDOM` per run | Nearly created a second storage account | Now reuses any `snowflakeqcpoc*` already in the resource group |
| `az provider register` treated as synchronous | Event Grid topic failed with "Couldn't verify the source resource" | Reads like permissions, is not. Now polls `registrationState` |
| RBAC scoped only to containers | `VERIFY_EXTERNAL_VOLUME` failed on the delegation key alone | `generateUserDelegationKey` is account-scope. `Storage Blob Delegator` at account scope fixes it and grants no data access of its own |

### Environment friction worth remembering

- The Claude session container cannot reach `*.snowflakecomputing.com` or
  `management.azure.com` — organisation egress policy, 403 at CONNECT. All
  Snowflake and Azure work is authored here and executed by the operator.
- `python3` on the Mac is an **Intel build under Rosetta** (pyenv), while the
  machine is arm64. `cryptography` 50.x ships arm64 macOS wheels only, so pip
  compiles from source. Homebrew at `/usr/local` is also Intel and will build
  everything from source. Neither is fixed; both were worked around.
- `snow` reads `~/.snowflake/connections.toml`. If that file exists, the
  `[connections.*]` sections of `config.toml` are **ignored entirely** — the CLI
  says so in its output, which is easy to miss.
- `externalbrowser` fails on this account with a SAML IdP error. It uses
  `OAUTH_AUTHORIZATION_CODE`.
- zsh expands `$VERIFY_EXTERNAL_VOLUME` inside double quotes. Escape the `$` in
  every `SYSTEM$` call, or run it in VS Code.

---

## Session 2 — 2026-09-10

### Enterprise confirmed, by CREATE rather than SHOW

`CREATE MASKING POLICY` succeeded. This was the last open question from Part 0
and the only one that could not be settled by reading: `SHOW` returning rows
proved nothing, because `SHOW` returns an empty set rather than an error for a
feature the edition does not have. Governance now builds both the policy path
and the secure-view path and compares them, as designed.

### Also done

- `SVC_KAFKA` key pair registered, `HAS_KEYPAIR = true`
- `CREATE STAGE` and `CREATE PIPE` granted on `RAW` — file mode creates both in
  the target table's schema, and the bootstrap only granted them on `LAND`
- `RAW.ORDER_STATUS_SDK` created for the direct-SDK mechanism
- `OPS.PIPELINE_LOG`, `OPS.DQ_RESULTS`, `OPS.INGEST_BENCHMARK` created

The `GRANT ... ON FUTURE TABLES IN SCHEMA RAW` from the bootstrap fired as
intended: `ORDER_STATUS_SDK` picked up `INSERT` and `SELECT` for `QC_LOADER` at
creation with no extra statement.

### Note on reading output

`snow sql` renders wide `SHOW` results one character per column, which is
unreadable. Use `--format json` for those, or run them in the VS Code extension,
which gives a grid.

### Mechanisms 1, 2 and 3 complete

79,663 rows on each path, exactly. Same events, three unrelated routes into
Snowflake, no duplicates and no loss on any of them.

| Mechanism | How | Table |
|---|---|---|
| 1 | Kafka Connector **v4.1.0** `SnowflakeStreamingSinkConnector`, 3 tasks | `RAW.ORDER_STATUS_KAFKA_V4` |
| 2 | Python **Snowpipe Streaming SDK 1.8.0**, one channel, no broker | `RAW.ORDER_STATUS_SDK` |
| 3 | Kafka Connector **v3.5.4** `SnowflakeSinkConnector`, `SNOWPIPE`, 60s flush | `RAW.ORDER_STATUS_KAFKA_V3FILE` |

### What this part actually taught

**v4 is not v3 with a flag.** It is a different connector class, streaming
only, with file mode removed. Comparing streaming against file mode means
running two connector majors side by side in isolated plugin directories -
which states the change more clearly than any config toggle would have.

**Snowpipe Streaming is pipe-implicit, not pipe-less.** Both v4 and the SDK
created a pipe behind the target table (`ORDER_STATUS_KAFKA_V4-STREAMING`,
`ORDER_STATUS_SDK-STREAMING`) without either being declared. That is what lets
offset tokens live server-side, and it gives per-mechanism credit attribution
for free through `PIPE_USAGE_HISTORY`.

**Offset tokens are the SDK's whole argument.** Running `sdk_stream.py` twice
appends nothing the second time, because the channel reports a token Snowflake
committed rather than one the client tracked. Kafka Connect hides that; the SDK
makes it the interface.

### Five failures, in order

| Failure | Cause |
|---|---|
| v4 registration HTTP 500 | v4 does not bundle BouncyCastle FIPS; v3 does. Needed `bc-fips` + `bcpkix-fips` in the v4 plugin dir |
| v4 FAILED on config validation, twice | A compatibility validator demanding v3 naming, then v3-style client-side validation. Disabled it: table names are explicit and schematization is off, so it guarded nothing while costing server-side validation |
| Both connectors green, zero rows | `qc.order_status` was empty. It had been produced by hand and a `docker compose down -v` destroyed it. Named volumes added |
| v4 stuck at 26,058 rows | Partitions added under a running connector are stranded: the sink opens a channel per partition at task open. Restarting the tasks fixed it |
| SDK `ConfigError: missing host` | The Rust core does not derive a host from the account identifier the way the Python connector does |

**The pattern across all five: a green status field never once told the truth.**
Container "Started" but exited; connector `RUNNING` on an empty topic; group
`Stable` with two partitions uncommitted. Every diagnosis came from a count or
a lag number.

---

### Part 4 complete — mechanisms 4, 5, 6, 7

| # | Mechanism | Result |
|---|---|---|
| 4 | Snowpipe auto-ingest, Event Grid | 10,051 rows, 5 files, one LOAD_TS each |
| 5 | Snowpipe REST `insertFiles`, internal stage | 8,097 rows, 4 files LOADED |
| 6 | Bulk `COPY`, `INFER_SCHEMA` + `MATCH_BY_COLUMN_NAME` | 40,000 rows |
| 7 | Schema evolution | 8 → 9 columns, `COUPON_CODE` added by a load |
| — | Bad-file test | 203 parsed, 200 loaded, 3 rejected, all three named by `VALIDATE()` |

Push versus pull is the point of running 4 and 5 together: storage tells
Snowflake, or the client does. Auto-ingest is impossible on an internal stage
because there is no event source, which is why `AUTO_INGEST` is absent from
that pipe rather than set false.

### Four more traps

| Trap | What happened |
|---|---|
| Control plane vs data plane | Owning the subscription lets you create a storage account but grants no blob access. `--auth-mode login` needs Storage Blob Data Contributor on your own identity — the same split that broke `generateUserDelegationKey` in Part 2 |
| `VALIDATION_MODE` + `MATCH_BY_COLUMN_NAME` | Mutually exclusive: Snowflake treats the column match as a transform. Its real home is a genuinely malformed file |
| CSV unload quotes its own delimiters | Pre-formatted CSV text in one column came back as `"800000,42,3,50000"` — one field, not four — so all 200 good rows failed on column count. Needs `FIELD_OPTIONALLY_ENCLOSED_BY = NONE` |
| `VALIDATE(JOB_ID => '_last')` is session-scoped | `_last` means the last `COPY` in the *current* session, and the CLI opens a new one per invocation. `COPY` and `VALIDATE` must share a session |

`snow sql` reserved-word aliases hit twice: `rows` and `check`. Use `n`, `val`,
`item`, `label`.

---

### Part 5 in progress — mechanisms 8 and 9 done

| # | Mechanism | Result |
|---|---|---|
| 8 | External table + insert-only stream | 2,800 settlement rows queried in place, 7 daily files, partitioned on the filename date |
| 9 | **Iceberg v3**, Snowflake-managed on `EXVOL_QC` | 79,663 rows written to Azure, 625 deleted into a deletion vector, 79,038 remain |

`SHOW ICEBERG TABLES` reports `iceberg_table_format_version = 3` and the
metadata sits at
`archive/order_events.n8eaHZIc/metadata/00002-*.metadata.json` — readable by
any Iceberg engine with Snowflake uninvolved, which is the whole argument for
the format over a normal table.

`ICEBERG_VERSION = 3` was set at creation rather than upgrading from v2: the
upgrade is irreversible and v2 readers cannot read v3. The `DELETE` is what
produces the deletion vector — v2 would have written positional delete files
merged at O(log n) on every read, v3 writes a bitmap applied at O(1) per row.

---

### Part 6 — mechanisms 12, 13 and 14 done

| # | Mechanism | Result |
|---|---|---|
| 14 | dbt seeds | 4 seeds, 125 rows, 14 tests, `PASS=19 ERROR=0` |
| 13 | `write_pandas` | `RAW.DIM_STORE_SEED`, 8 rows, table created from the dtypes |
| 12 | Marketplace share | `FINANCE__ECONOMICS` mounted, 15,683 rate days, **0 bytes copied** |

**A seed is ingestion, not transformation.** dbt appears twice in this project
and only its second appearance is modelling. `dbt build` reported *"Found 4
seeds, 1 operation, 14 data tests"* and no models, because none exist. The seed
is the source: nothing upstream knows what a T1 store's evening promise is, so
that fact enters the platform from git and nowhere else.

**Marketplace: the free tier lags 91 days.** Rates run 1973-01-02 to
2026-06-11 against an order window ending 2026-09-10, so every order in the
window is converted at June's rate. `ASOF JOIN` is what makes that legible --
`RATE_TAKEN_FROM` comes back `2026-06-11` on every row. An equi-join would have
returned zero rows and been indistinguishable from a broken join. The USD column
is therefore a demonstration, not a number to bank.

**Shared tables report `ROW_COUNT` and `BYTES` as NULL**, not as the provider's
figures. There is no way to size a shared table before querying it, which turns
"never `SELECT *` on a share" from advice into the only rule available. A `LIMIT`
with no `ORDER BY` is the safe probe -- it stops after one micro-partition
however large the table is.

### Six traps in this part

| Trap | What happened |
|---|---|
| `auto_create_table` quotes identifiers exactly as given | A lower-case pandas frame produces a quoted lower-case table that no unquoted SQL can reach. Upper-casing the frame first is the whole fix -- and `dbt_project.yml` needs `+quote_columns: false` for the same reason |
| Key format flips between clients | `snowflake-ingest` 1.0.x wants a PEM string; `snowflake-connector-python` wants DER bytes. Same key pair, same account |
| zsh `%` in a copied public key | `tr -d '\n'` prints no trailing newline, so zsh appends `%` to mark it. Copied in, the key is 393 chars and no longer valid base64. Pipe to `pbcopy` |
| Cybersyn rebrand moved the schema | Tables are under `PUBLIC_DATA_FREE`, not `CYBERSYN`. The table and column names were unchanged |
| `INFORMATION_SCHEMA.TABLES` includes views | The zero-copy assertion counted `V_FX_INR_USD` and returned 1 -- it counted the object proving nothing was copied. Needs `TABLE_TYPE = 'BASE TABLE'` |
| `python:3.12-slim` has no git | `dbt debug` checks for it unconditionally because `dbt deps` clones packages. Harmless with no packages, fatal once Part 6 adds `dbt_utils` |

Type inference is worth watching in both directions. `write_pandas` gave every
string `VARCHAR(16777216)` -- a pandas `object` dtype carries no length, so the
connector takes the maximum -- and typed `PINCODE` as `NUMBER(38,0)`, which is
wrong for an identifier and only harmless because no Indian pincode starts with
zero. dbt seeds declare `column_types` explicitly and get `varchar(8)`. Same
class of data, two mechanisms, two levels of care.

---

## Session 3 — 2026-09-11

### Mechanism 10 done, mechanism 11 blocked. 13 of 14 is the ceiling.

| # | Mechanism | Result |
|---|---|---|
| 10 | Directory table + `pypdf` UDF | `RAW.COMPLAINT_DOC`, 300 docs, 0 failures, avg 320 chars |
| 11 | External access to Open-Meteo | **refused**: `509009 External access is not supported for trial accounts` |

### The Anaconda gate never existed

Two sessions of planning said mechanisms 10 and 11 were blocked on accepting the
Anaconda Terms of Service. There is no such section on this account's Billing &
Terms page. `sql/p6_pkg_probe.sql` settled it the way Part 2 settled the
Enterprise question -- by attempting the `CREATE` rather than reading a
catalogue: `pypdf 6.18.0` and `requests 2.34.2` both compiled **and executed**.

`INFORMATION_SCHEMA.PACKAGES` listing a package is necessary and not sufficient;
it says what the channel carries, not what the account may compile against. The
only conclusive test is a function that runs.

Runtimes 3.8 through 3.14 are all available. The UDFs pin 3.11 anyway, because
that is the one an execution proved -- swapping in an unverified variable
immediately before the run that depends on it trades a known-good for nothing.

### Finding 3: external access is a trial gate, not an edition limit

The shape of the failure is the useful part:

| Object | Result |
|---|---|
| `CREATE NETWORK RULE` | created |
| `CREATE SECRET` | created |
| `CREATE EXTERNAL ACCESS INTEGRATION` | **refused** |

Both building blocks work. What is gated is the object that binds a rule and a
secret to a function -- the only one that actually opens egress. **On a trial
account `SHOW GRANTS` will never explain why something does not work.**

Weather was mechanism 11's payload, not a dependency: the risk features in §10
are distance, hour, store load, basket size and rider. Nothing downstream is
blocked. `sql/p6_external_access.sql` runs as far as the wall and stops, kept as
design rather than dead code -- the same treatment Snowflake Datastream gets.

### Four bugs in one mechanism, all mine

| Bug | What happened |
|---|---|
| `FILE_MODIFIED TIMESTAMP_LTZ` | `DIRECTORY()` returns `LAST_MODIFIED` as `TIMESTAMP_TZ(3)` and Snowflake will not implicitly convert. Matching the source type is also right: that offset is Azure's, and `RAW` holds what arrived |
| A stream used as a backfill | `CREATE OR REPLACE STREAM` starts at the current offset. With all 300 files already registered, `REFRESH` -- idempotent -- had nothing to announce, so the fresh stream was empty and the load silently inserted 0 rows. **A stream is the delta, never the backfill** |
| `missing_header = 0` on an empty table | The check counted rows NOT matching, so emptiness scored perfectly. Now asserts `docs = with_header AND docs > 0` |
| `REGEXP_LIKE(BODY, '.*Order [0-9]+.*')` = 0 | `REGEXP_LIKE` is implicitly anchored to the whole string -- a match, not a search -- and `.` does not cross a newline without the `s` parameter. Every body is multi-line. `REGEXP_SUBSTR` searches, and now extracts the id so the check is falsifiable against the 1..20000 range |

Two of those four were false greens in my own verification SQL. The standing
rule of this project -- *a green status field has been wrong every time* -- now
extends to a count of zero, which is a status field wearing a number's clothes.

The backfill is now an anti-join on `(RELATIVE_PATH, MD5)`. MD5 rather than path
alone, so a file the partner **replaces** is reprocessed and an unchanged one is
skipped: content addressing the directory table hands over for free.

### Also

`SAMPLE` is reserved -- it is the table-sampling clause. Third collision after
`rows` and `check`.

Azure Cloud Shell is ephemeral. The clone does not survive a session; re-clone
rather than pull.

---

## Part 7 — CORE, complete

### What CORE holds

| Table | Rows | Built by |
|---|---|---|
| `ORDER_STATUS_EVENT` | 78,874 | dedupe with `QUALIFY`, from 79,663 |
| `INVENTORY_DAILY` | 96,000 | CDC conformance |
| `ORDER_ITEM` | 54,635 | CDC conformance |
| `ORDER_HEADER` | 20,000 | CDC conformance |
| `ORDER_FUNNEL` | 19,029 | `MATCH_RECOGNIZE`, clean lifecycle |
| `ORDER_CANCELLED` | 623 | `MATCH_RECOGNIZE`, `PATTERN (P K? C)` |
| `ORDER_LIFECYCLE_ANOMALY` | 348 | everything neither pattern claimed |
| `CUSTOMER` / `PRODUCT` / `RIDER` / `STORE` | 500 / 200 / 60 / 8 | CDC conformance |
| `DIM_PRODUCT` | 220 | SCD2 `MERGE` — 200 current, 20 closed |

**19,029 + 623 + 348 = 20,000.** Three tables partition every order exactly
once, which is the check that makes the pattern matching trustworthy rather
than merely plausible.

### The prerequisite nobody planned for

`RAW` had no customers, products, riders, orders, order items or inventory.
Part 3 consumed one topic, `qc.order_status`, and that topic is hand-produced
rather than captured — the seven Debezium topics carrying the operational
database's actual tables had been sitting unconsumed since then. CORE cannot
conform a customer dimension that does not exist, so Part 7 began by landing
them: a second sink connector, its own consumer group, 171,403 rows.

The envelope stays whole. No `ExtractNewRecordState` transform is configured, so
every record carries `before`, `after`, `op`, `source` and `ts_ms`. That
before-image is the entire reason CDC beats a nightly extract for SCD2.

### Types that do not arrive as written

Measured, not assumed, and two of the three are counter-intuitive:

| Postgres type | Arrives as | Cast |
|---|---|---|
| `TIMESTAMP` | VARCHAR, ISO-8601 | `TO_TIMESTAMP_NTZ(x::STRING)` |
| `DATE` | **INTEGER, days since epoch** | `DATEADD(day, x::INT, '1970-01-01')` |
| `INT`, money in paise | INTEGER | `::NUMBER` |

Same connector, same settings, and `20353` is `2025-09-22`. A `::DATE` on either
column is wrong, and on the date column it silently yields 1970.

### Numbers that fell out rather than being asserted

| Observed | Source truth |
|---|---|
| 0.99% duplicates removed | generator's `DUP_RATE = 0.01` |
| 1.8% lifecycle anomalies | `ANOMALY_RATE = 0.02`, minus short cancellations |
| 19,377 delivered + 623 cancelled = 20,000 | timestamp nulls agree with the status column |
| 0 money mismatches over 20,000 orders | paise as integers, through six hops |
| `PICKED_UP` 19,281 < `DELIVERED` 19,377 | 96 skipped transitions, visible in a `GROUP BY` |

### All five stream types now exist

| Type | Object | Why that one |
|---|---|---|
| Standard | `CORE.STR_PRODUCT_CHANGES` | SCD2 needs the before-image |
| Append-only | `CORE.STR_EVENTS_APPEND` | events are never updated; no reason to pay for before-images |
| Insert-only | `RAW.STR_SETTLEMENT_NEWFILES` | the only mode an external table supports |
| Directory table | `RAW.STR_DOCS_NEWFILES` | arrival triggers parsing |
| On a view | `CORE.STR_ORDER_ENRICHED` | change tracking without materialising |

A stream on a view needs `CHANGE_TRACKING` set explicitly on every underlying
table. A stream on a table enables it implicitly; a stream on a view does not.

### Six failures, and what each one looked like

| Failure | Why it was hard to see |
|---|---|
| Seven empty topics beside seven full ones | Debezium writes `qc.qc.orders`, not `qc.orders`. Subscribing to a topic that does not exist is not an error — the broker auto-creates it and the connector reports RUNNING with nothing to read |
| `depth()` reported MISSING for full topics | rpk v24 names the column `HIGH-WATERMARK`, not `LOG-END-OFFSET`. Three versions of that function collapsed "empty" and "absent" into the same answer |
| `no_before_image = 0` with `"before": null` visible | A JSON null inside a VARIANT is a value whose type is null, not SQL NULL. `IS NULL` returns FALSE; `IS_NULL_VALUE` is the test |
| SCD2 produced 200 rows and 0 closed versions | The seed ran after the MERGE had already applied the new prices, so version 1 recorded the new value. Indistinguishable from a dimension that has not changed |
| `invalid identifier 'SECOND'` | Inside `MEASURES`, names resolve against pattern variables first, so the bare date part is read as a column. Quote it |
| The private key in terminal scrollback | Connect echoes the whole config back on a successful POST. The script piped it to stdout. Key rotated; output now redacted |

**The count of zero is a status field wearing a number's clothes.** Four of
those six reported a plausible number rather than an error, and two were false
greens in verification SQL rather than in the data.

---

## Pausing — 2026-09-10

Nothing in this project runs on a schedule, so there is nothing to switch off in
Snowflake. Warehouses auto-suspend after 60 s and the last statement ran hours
ago. Two things are worth knowing before walking away.

**`PIPE_CLICKSTREAM_AUTO` is still armed.** `AUTO_INGEST = TRUE` means it keeps
watching the Event Grid queue for blobs landing in `landing/`. Nothing will land
while paused, so it should cost nothing — but an idle pipe's polling cost is
UNVERIFIED and it is invisible to `RM_POC` either way. `SELECT
SYSTEM$PIPE_STATUS(...)` tomorrow will show whether anything moved.

**Stop the Docker stack with `stop`, not `down -v`.**

```bash
cd ~/Downloads/GIT/snowflake_usecase/source
docker compose stop
```

`docker compose down -v` destroyed `qc.order_status` once already, and that
topic was hand-produced with no way to re-snapshot it. Named volumes `pgdata`
and `rpdata` now survive a `down`, but `-v` deletes them by definition.

Azure keeps accruing a few rupees of hot blob. `landing/` expires after 14 days
by lifecycle rule; `archive/`, `external/` and `docs/` do not, and the Iceberg
metadata in `archive/` must not be deleted while `RAW.ORDER_EVENTS_ICEBERG`
exists.

**Still unset: the account budget.** Twelve routes have run against an account
whose only spending control cannot see Snowpipe, Snowpipe Streaming or the
Python UDFs that mechanisms 10 and 11 will add. 3.78 credits is the last
verified figure and it predates Parts 3 through 6 entirely. Snowsight -> Admin
-> Cost Management -> Budgets -> 80 credits. It takes a minute and it is the
only control that would catch a mistake made while nobody is watching.

---

## Resume here

### 1. Bring the source stack back up

```bash
cd ~/Downloads/GIT/snowflake_usecase/source
docker compose up -d              # no reseed needed, the volume persists
docker exec -i qc-redpanda rpk topic list
curl -s localhost:8083/connectors/qc-postgres-cdc/status | python3 -m json.tool
```

Console at http://localhost:8081. Only needed for routes that read Kafka.
Mechanisms 10-14 do not touch the source stack at all.

### 2. Two things still open

| | |
|---|---|
| **Account budget** | Snowsight -> Admin -> Cost Management -> Budgets -> Account Budget -> 80 credits + email. `RM_POC` caps virtual-warehouse credits only; Snowpipe, Snowpipe Streaming and dynamic-table refresh are invisible to it. Nine ingestion mechanisms have now run against an account with no serverless cap at all |
| **Credits backfill** | `sql/p3_credits_backfill.sql`, once `ACCOUNT_USAGE` has caught up. The ~3 h latency means Part 3-5 spend is still unmeasured. 3.78 credits is the last verified figure and it predates all of it |

The Session 1 foundation items are closed: `SVC_KAFKA` has a key pair
(`HAS_KEYPAIR = true`) and Enterprise was confirmed by `CREATE MASKING POLICY`
rather than by `SHOW`.

### 3. Ingestion is closed at 13 of 14

Nothing is left to run in the ingestion stage. Mechanism 11 is not deferred, it
is unavailable: external access is refused on a trial account and no rework
reaches it. `sql/p6_external_access.sql` stops at the wall by design.

Next is **Part 6 — `CORE`**: dedupe, SCD2, conformance. The first job is the one
`RAW` deliberately did not do. Three tables hold the same 79,663 events, and
within each there is a 1% duplicate rate and 2% out-of-order transitions the
generator injected on purpose.

Carry one lesson from mechanism 10 straight into it: **a stream is the delta,
never the backfill.** `CORE` gets streams over `RAW`, and the same split applies
-- backfill the history once from the table, then let the stream carry what
arrives after. `CREATE OR REPLACE STREAM` resets the offset and is how the 300
pending files were lost.

### Row counts as they stand

| Target | Rows | Mechanism |
|---|---|---|
| `RAW.ORDER_STATUS_KAFKA_V4` | 79,663 | 1 |
| `RAW.ORDER_STATUS_SDK` | 79,663 | 2 |
| `RAW.ORDER_STATUS_KAFKA_V3FILE` | 79,663 | 3 |
| `RAW.CLICKSTREAM_AUTO` | 10,051 | 4 |
| `RAW.CLICKSTREAM_REST` | 8,097 | 5 |
| `RAW.ORDER_BACKFILL` | 40,000 | 6, 7 |
| `RAW.ORDER_BADFILE_TEST` | 200 | 6 |
| `RAW.ORDER_EVENTS_ICEBERG` | 79,038 | 9 |
| `RAW.COMPLAINT_DOC` | 300 | 10 |
| `RAW.DIM_STORE_SEED` | 8 | 13 |
| `RAW.CATEGORY_HIERARCHY` | 23 | 14 |
| `RAW.SLA_THRESHOLD` | 32 | 14 |
| `RAW.COMPLAINT_REASON_CODE` | 10 | 14 |
| `RAW.COMPLAINT_LABEL` | 60 | 14 |
| | **376,808 stored** | |
| `RAW.EXT_SETTLEMENT` | 2,800 | 8 - read in place, not stored |
| `RAW.V_FX_INR_USD` | 15,683 | 12 - a view over a share, nothing copied |
| — | — | 11 - blocked, trial account |

`CORE`, `MART`, `SERVE` and `LAB` are empty. Nothing has been deduped: the three
order-status tables hold the same 79,663 events three times over by design, and
resolving that is what `CORE` is for.

---

## Repo map

| Path | What |
|---|---|
| `docs/OVERVIEW.md` | Business-facing. What this is and why |
| `docs/ARCHITECTURE.md` | Technical design, plus §16 as-built with real identifiers |
| `docs/PROGRESS.md` | This file |
| `source/` | Docker stack, Postgres schema, data generator, Debezium config |
| `sql/p1_bootstrap.sql` | Snowflake foundation. Teardown at the bottom |
| `sql/p1_fix.sql` | Query acceleration off, notify users, Gen1 |
| `sql/p2_integrations.sql` | External volume, integrations, stages, file formats |
| `scripts/p2_azure.sh` | Azure resources. Read-only unless `CREATE=1` |
| `scripts/p2_rbac.sh` | Role assignments for both service principals |

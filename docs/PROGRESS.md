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
| **16.45% SLA breach**, recomputed from the event stream | generator's target 16.4% |
| **0 orders** where event-derived delivery disagrees with the header | the application's own column, to the second |
| 0.99% duplicates removed | generator's `DUP_RATE = 0.01` |
| 1.8% lifecycle anomalies | `ANOMALY_RATE = 0.02`, minus short cancellations |
| 19,377 delivered + 623 cancelled = 20,000 | timestamp nulls agree with the status column |
| 0 money mismatches over 20,000 orders | paise as integers, through six hops |
| `PICKED_UP` 19,281 < `DELIVERED` 19,377 | 96 skipped transitions, visible in a `GROUP BY` |

### The anomaly split, and one that got away

188 `SKIPPED_TRANSITION` against 160 `OUT_OF_ORDER`. The generator chooses
between them on a fair coin, so the gap is worth a look rather than a shrug.

The likely cause is that the two defects are not equally detectable. A skipped
transition is always visible — the status is simply absent. An out-of-order
defect shifts one step's timestamp forward by nine minutes, and if the next step
was already more than nine minutes later, the sequence does not actually
reorder. Delivery legs run ten to twenty-five minutes, so some proportion of
those shifts leave a perfectly ordered lifecycle behind and nothing for a
pattern to catch.

**UNVERIFIED**, and settleable: compare the injected anomaly count from the
generator against 348. If the generator injected roughly 380, the missing ~30
are shifts that failed to reorder anything — which is a real limit of
sequence-based detection, not a bug in the pattern.

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

## Part 8 — MART, complete

`dbt build --select tag:mart` — 9 models, 32 tests, **PASS=42 ERROR=0**.

| Model | Rows | Pattern |
|---|---|---|
| `fct_inventory_daily` | 96,000 | periodic snapshot |
| `fct_order_status_event` | 78,874 | transaction, immutable |
| `fct_order_item` | 54,635 | transaction |
| `fct_order` | 20,000 | **accumulating snapshot** |
| `dim_date` | 213 | generated spine |
| `dim_customer` / `dim_product` / `dim_rider` / `dim_store` | 500 / 220 / 60 / 8 | SCD1, SCD2, SCD1, SCD1 |

**250,510 rows across nine tables.**

### Three fact patterns, and why all three

`fct_order` is an accumulating snapshot: one row per order, rewritten as it walks
its lifecycle, milestones as columns. It answers *how long from packed to picked
up*. It cannot represent a transition that never happened —
`fct_order_status_event` keeps the immutable log beside it and answers *which
transitions were skipped*, which is exactly what 348 orders are interesting for.

`fct_inventory_daily` is a periodic snapshot: store × product × day whether or
not anything moved. The absence of change is itself a measurement, and "stock
sat at zero for six days" cannot be derived from a table that records only
movements.

### The model that pays for SCD2

```sql
left join dim_product p
       on p.product_id = i.product_id
      and o.placed_ts >= p.valid_from
      and o.placed_ts <  p.valid_to
```

Twenty products changed price on 2026-09-11. Every order was placed on or before
09-08, so every line joins the pre-rise price. Joining on `product_id` alone
would restate historical revenue at today's price — the precise failure SCD2
exists to prevent. It also exposes `price_variance_paise`, the gap between what
the catalogue said and what was charged, which is invisible without a versioned
dimension.

### Two silent failures, and which test caught the second

| Attempt | `valid_from` on version 1 | What happened |
|---|---|---|
| 1 | read from `CORE.PRODUCT` after the MERGE | version 1 recorded the NEW price. 200 rows, 0 closed — indistinguishable from a dimension that has not changed |
| 2 | the snapshot's own `CDC_TS` | correct prices, wrong window. Every fact predates version 1, so `product_sk` was null on all 54,635 rows |
| 3 | open lower bound, `1900-01-01` | correct |

A snapshot says what the state **is**, not when it started being that. Those 200
products existed for months before Debezium captured them, and stamping version 1
with the capture time asserts that nothing existed beforehand.

**Only `not_null` caught the second one.** The `relationships` test passed —
relationship tests ignore nulls by design, so a foreign key that is null for
every row satisfies it completely. A dimension join that silently returns nothing
is how a fact table starts under-reporting with every referential check green.
The not-null test on a foreign key is not redundant with the relationships test;
it is the only one that sees this.

### A schema grant is not an object grant

Every model reading `CORE` failed with *"does not exist or not authorized"* —
one message covering two unrelated situations. The tables existed; `SVC_CI` could
not see them.

`p1_bootstrap.sql` granted `ALL ON SCHEMA QCOMMERCE.CORE` to `QC_ENGINEER`. That
is usage, create table, create view — privileges on the *schema*. A table created
later by a different role carries none of them, and every `CORE` table was created
by `ACCOUNTADMIN` running `snow sql`. The bootstrap did set `FUTURE TABLES` on
`RAW`, which is why nothing hit this until `MART`.

`ON ALL` and `ON FUTURE` are both required. Granting only `FUTURE` is the classic
half-fix: it repairs tomorrow and leaves today broken.

### dbt runs from a pinned image now

`pip install dbt-snowflake` on every invocation cost about ninety seconds — fine
for four seeds, unworkable once `MART` made dbt a write-run-read-fix loop.
`dbt/Dockerfile` pins dbt-core 1.12.4 and dbt-snowflake 1.12.0, the versions the
first unpinned run resolved. Startup is now about a second.

An image rather than a native install for a reason beyond speed: Part 14 runs
`dbt build` in a Linux container on GitHub Actions, so a pinned image makes local
and CI the same dbt against the same adapter. A macOS install would diverge from
CI on exactly the axis that matters.

`macros/generate_schema_name.sql` overrides dbt's default concatenation so models
land in `MART` rather than `RAW_MART`. The default exists so developers sharing a
warehouse do not collide; here the layer names are the architecture.

---

## Part 9 — `LAB`, the SLA-breach model

Predict at the moment an order is placed whether it will be delivered after its
`promised_ts`. Three files: `sql/p9_features.sql`, `sql/p9_train.sql`,
`sql/p9_score.sql`, plus `sql/p9_report.sql` which re-reads the results without
refitting.

### The Model Registry wall, and what actually cleared it

`log_model` failed on a two-feature toy model before any real work started:

```
391525 (42601): Cannot create a Python function with the specified packages.
'Packages not found: snowflake-ml-python[version='<3,>=2.0']'
```

This is **not** a fourth account-tier finding. The Registry imports, the
packages are present, and `log_model` runs far enough to begin creating the
model's inference function. That function declares `snowflake-ml-python
>=2.0,<3` as a runtime dependency and the Anaconda channel on this account
carries **1.9.2**. A version skew, not a permission.

Three fixes were tried at once rather than guessed between, because the four
preceding rounds had all been guesses:

| Variant | Result |
|---|---|
| A — `conda_dependencies=["scikit-learn==1.9.1"]` | **FAILED**, identical error |
| B — `options={"embed_local_ml_library": True}` | **OK** |
| C — both | OK, but pins scikit-learn to whatever the training runtime happened to have |
| Fallback — joblib → stage → `SnowflakeFile` reload | round trip IDENTICAL, held in reserve, not needed |

A failing alone is the informative result: the `>=2.0,<3` constraint comes from
the Registry's own dependency on `snowflake.ml`, not from the model's sklearn
version, so pinning sklearn cannot reach it. **B is the pick.** C works and was
rejected — pinning the runtime's incidental sklearn version breaks the moment
Snowflake bumps the runtime.

### Training runs inside the account

A Python stored procedure, not a local Snowpark session. The data never leaves,
the registry and the training runtime are the same environment so client/server
skew cannot recur, and it sidesteps the native arm64 interpreter outstanding
since Part 3.

### Leakage discipline

Every feature must be knowable at `PLACED_TS`. Excluded on those grounds:
`packed_ts`, `picked_up_ts`, `delivered_ts`, `pack_sec`, `pick_sec`, `ride_sec`,
`lifecycle_outcome` — each leaks the answer outright — and `rider_sk`, because
which rider was free is a consequence of the same congestion the model is trying
to predict.

**CANCELLED orders are excluded, not labelled false.** A cancelled order has no
delivery outcome. Calling it "not breached" would teach the model that
cancellation prevents lateness, which is a fact about the label definition and
not about the world. 19,377 delivered in, 623 cancelled out.

Store congestion is counted over the 60 minutes *strictly before* each order —
the window frame ends at `1 PRECEDING`, not `CURRENT ROW`, so orders sharing a
millisecond cannot see each other.

### Fitting in the source system's own scaling

The order generator decides lateness with a logit whose coefficients are in
`source/generate.py`:

```
-3.05 + 0.85*(dist_km/5) + 0.55*peak + 0.70*(min(load,15)/15) + 0.25*(items/5) + N(0, 0.50)
```

All four terms are observable at placement and reconstructible from `MART`, so
the features are built in exactly that scaling and the fitted weights land
beside the true ones in `OPS.MODEL_COEFFICIENTS`. That turns "the model scored
0.65" into "the model recovered the process" — a claim that can be wrong.

Two **placebo** features go into the fit alongside: `F_WEEKEND` and `F_COD`,
both with a true weight of zero. A fit that assigns them weight is finding
structure in noise, and a check fails on it. They came out **−0.0146** and
**−0.0509**.

`penalty=None` is set deliberately. L2 is sklearn's default and shrinks every
coefficient toward zero, which would be indistinguishable from the attenuation
the unobserved noise term causes. With the regulariser on, the comparison would
be measuring the regulariser.

### The marginal table lies, and it was worth catching before the fit

Breach rate by quartile, before any model:

| driver | q1 | q2 | q3 | q4 |
|---|---|---|---|---|
| `is_peak_hour` | 15.08 | 21.95 | — | — |
| `item_count` | 15.44 | 16.35 | 16.66 | 17.13 |
| **`store_load_60m`** | **17.09** | 16.35 | 16.41 | **15.73** |
| `is_weekend` [placebo] | 16.41 | 16.37 | — | — |
| `is_cod` [placebo] | 16.54 | 15.57 | — | — |

Store congestion has a true weight of **+0.70** and its marginal rate **falls**.
The proposed mechanism is distance: customers are routed to their nearest store,
so a store is busy precisely because its customers are close, and busy
store-hours are short-distance store-hours. Distance spans 0.176–22.378 km at
0.85 per 5 km — up to **3.8 in the logit** — while load is capped at
`min(load,15)/15` and sits at single digits in practice, worth at most ~0.2. The
larger term points the other way and buries the smaller one.

The multivariate fit conditions on distance and **did** recover `F_LOAD_15` as
positive. STEP 0 of `p9_train.sql` measures the mechanism directly rather than
asserting it — correlation between distance and load, and breach rate by load
quartile *within* each distance quartile.

A comment in `p9_features.sql` originally read a flat marginal rate as proof
there was nothing to find. That was wrong and is corrected: **a marginal
relationship can be flat or reversed while the conditional one is strong.**

### Numbers

| | |
|---|---|
| Delivered orders / cancelled | 19,377 / 623 |
| Train | 14,600 to 2026-08-24 23:57:43.555, 16.49% breached |
| Test | 4,777 from 2026-08-25 00:00:53.306, 16.12% breached |
| Split | strictly temporal, 45 days / 15 days |
| `HAVERSINE` vs `ST_DISTANCE` | max difference **0 m** across 19,377 rows |
| Test ROC AUC | **0.6479** |
| Calibration | predicted vs actual within **0.70 points** |
| Distinct scores | 2,867, range 0.0676–0.8135 |
| Top decile breach rate | **34.73%** vs 7.34% bottom — 4.73×, 2.15× over base |
| Checks | 12 across the three files, all passing |

Calibration by bucket, test split:

| score range | orders | predicted | actual | gap |
|---|---|---|---|---|
| 0.07–0.10 | 581 | 8.92 | 7.57 | −1.34 |
| 0.10–0.20 | 3,257 | 14.61 | 14.00 | −0.61 |
| 0.20–0.30 | 707 | 23.54 | 22.49 | −1.05 |
| 0.30–0.39 | 79 | 33.29 | 27.85 | −5.44 |
| 0.40–0.50 | 61 | 44.42 | 42.62 | −1.80 |
| 0.50–0.59 | 47 | 54.44 | 59.57 | +5.13 |
| 0.60–0.79 | 45 | 67.04 | 77.78 | +10.74 |

4,545 of 4,777 test orders sit in the first three buckets, every one within 1.4
points. The two positive gaps at the top are **not** established: at n=45 a
77.78% rate carries a standard error near 6.2 points, so +10.74 is about 1.7 sd.
If real, the mechanism is a linear logit fitted against an unobserved noise term
shrinking toward the base rate, which under-predicts exactly where risk is
highest. Confirming it needs more test days or a calibration layer; neither is
in Part 9's scope.

**0.6479 is close to this problem's ceiling, not a weak model.** The generator
adds unobserved `N(0, 0.50)` to the logit and then draws the outcome from a
Bernoulli, so a model that knew the true coefficients exactly would land in
roughly the same place. I predicted 0.66–0.74 beforehand and it came in below
that — the estimate was optimistic.

### The SQL model surface works, and it was the genuinely uncertain one

```sql
WITH sla AS MODEL QCOMMERCE.LAB.SLA_BREACH
SELECT sla!PREDICT_PROBA(F_DIST_5, F_PEAK, F_LOAD_15, F_ITEMS_5, F_WEEKEND, F_COD)
FROM   LAB.ORDER_FEATURES;
```

Returns an OBJECT keyed `output_feature_0` / `output_feature_1`. All ten sampled
rows matched the procedure's scores to full precision — Snowpark `mv.run()` and
the SQL surface hit the same generated function. That also confirmed the scoring
procedure's column-discovery logic, which takes the *second* added column
without assuming the name.

It was placed last in the file on purpose: `snow sql -f` aborts on error, so a
failure there would have left every deliverable already committed.

### Failures in this part

| | |
|---|---|
| Adjacent string literals across two lines in two `EXPECTED` arguments | Python's concatenation rule, not SQL's. Snowflake parsed the first literal as the argument and hit the second with no operator. Scoring had already finished and one check had passed; only the last two checks were lost. Joined with `\|\|` |
| `MAX(MODEL_VERSION)` to find the latest run | A string max — `'V9' > 'V10'`. Caught before running, but it would only have bitten on the second training run, which is when nobody looks |
| Scalar subqueries in the coefficient checks | `SELECT COEFFICIENT ... WHERE FEATURE = 'F_DIST_5'` returns one row today and two after a retrain. Caught before running, same reason |
| `X / 5.0 ::FLOAT` | Casts the literal, not the expression. It happened to yield FLOAT by numeric promotion, which is worse than failing. Parenthesised |
| `OBJECT_AGG(...) ... GROUP BY SPLIT` in a scalar slot | Returns one row per group. Collapsed the grouping first |
| Predicted test AUC 0.66–0.74 | Actual 0.6479. Below the stated range |

### What Part 9 did not need

`RANGE BETWEEN 3600000 PRECEDING AND 1 PRECEDING` was flagged UNVERIFIED with a
self-join fallback written beside it, on the grounds that Snowflake historically
allowed only `UNBOUNDED` and `CURRENT ROW` in a RANGE frame. **Numeric offsets
work.** The fallback stays in the file as a comment.

The joblib + stage round trip likewise works and is not needed, since the
Registry does.

---

## Part 10 — text and classification, without Cortex

300 complaint PDFs, ten reason codes, 60 hand labels. Classify the other 240.
Files: `p10_text_prep.sql`, `p10_classify.sql`, `p10_eval.sql`, `p10_vectors.sql`,
`p10_eval_compare.sql`, and `scripts/p10_truth.sh`.

### The answer key is kept where the model cannot reach it

`source/out/_truth.csv` was withheld from upload in Part 6 so the classifier
would have to earn the 240. Scoring still needs it, so it is regenerated rather
than recovered -- `gen_complaints.py` is seeded -- and loaded to a Snowflake
**internal stage** and a table in `OPS`, never to the Azure container holding
the documents and never into `RAW` or `CORE`.

The script proves the regeneration is faithful before uploading anything: it
diffs the regenerated dbt seeds against the committed ones and stops if they
differ, because a drifted generator would produce a key describing documents
other than the ones in the account.

The separation is greppable, not promised:

```
grep -v '^--' sql/p10_classify.sql | grep -c COMPLAINT_TRUTH    -> 0
```

Comment lines are excluded deliberately. The first version of that check
counted 2, both in the comment explaining the check — a verification its own
description defeats is worthless.

### A generator bug, corrected in CORE rather than at source

`gen_complaints.py:38` says "must match generate.py, so order ids resolve".
They do not. `generate.py` issues 900,000–919,999; `gen_complaints.py` draws
`randint(1, 20_000)`. **The ranges do not overlap at all** — every complaint
referenced an order that does not exist.

`CORE.COMPLAINT` adds 899,999, which maps the draw one-to-one onto the real id
space and preserves its distribution. Fixing the generator instead would change
every complaint body that interpolates an order id, three of the ten codes, and
require all 300 PDFs regenerated and re-uploaded. The correction lives in one
place where it cannot be applied twice.

### What the corpus actually is

Each reason code is generated from **three sentence templates**. The 60 labels
are a random 20% sample and not stratified, so template coverage is uneven:

| coverage | classes | held-out | on a template never seen |
|---|---|---|---|
| 3 of 3 | LATE_DELIVERY, MISSING_ITEM, PAYMENT_ISSUE, REFUND_DELAY | 145 | 0 |
| 2 of 3 | QUALITY_FRESH, WRONG_ITEM, DAMAGED_ITEM, RIDER_BEHAVIOUR | 80 | 26 |
| **1 of 3** | **APP_ISSUE, PACKAGING** | 15 | 11 |

203 of 240 held-out documents share a template with something in training. That
sets a floor of **84.6% accuracy from memorisation alone**, against a 29.6%
majority baseline.

### The result, and what it actually measures

| | |
|---|---|
| Held-out accuracy | **85.42%** (205 / 240) |
| Macro-F1 | **0.7489** |
| Macro-recall / macro-precision | 0.7373 / 0.8660 |
| Majority baseline | 29.58% |
| Memorisation floor | 84.58% |

Accuracy clears the floor by **0.84 points**. Split by template coverage, the
reason is not subtle:

| phrasing | complaints | correct | accuracy |
|---|---|---|---|
| template seen in training | 203 | **203** | **100.00%** |
| template never seen | 37 | **2** | **5.41%** |

**Nine of the ten classes got exactly the seen-phrasing documents right** —
exactly, not approximately. Only WRONG_ITEM beat that, by two.

On genuinely novel phrasings the model scores 5.41%, **below the 10% a uniform
guess over ten classes would score**, because its errors are systematic rather
than random: unseen phrasings route to whichever class shares surface
vocabulary, and MISSING_ITEM absorbs them at 57 predictions against a support
of 46.

The corpus makes this easy. Once digits are dropped by the tokeniser, 300
documents collapse to **266 distinct token sequences**; 64 complaints have an
exact duplicate somewhere, 10 of the held-out 240 are token-identical to a
training example, and the average complaint's nearest neighbour sits at
**0.908** cosine. The most isolated document in the corpus is still 0.4195 from
something else.

### The confidence score is the usable product

| fifth | confidence | correct | accuracy |
|---|---|---|---|
| 1–4 | 0.235–0.537 | 192 / 192 | **100.0%** |
| 5 | 0.119–0.235 | 13 / 48 | 27.1% |

**All 35 errors sit in the bottom fifth.** A threshold at 0.235 auto-routes 80%
of complaints with zero errors and sends 20% to a human. A model that cannot
generalise at all still yields an operational rule, because the score knows
what the classifier does not.

### Cross-validation overestimated, and the reason is the useful part

| | CV (2-fold) | held out |
|---|---|---|
| accuracy | 0.8500 | 0.8542 |
| macro-F1 | **0.7777** | **0.7489** |

I predicted CV would read **below** held-out, on the grounds that each fold
trains on 30 rows rather than 60. It read above. Sample size was not the
operative factor.

CV draws its test rows from the same 60 labelled documents, so **every CV test
row's template is present in the label pool by construction**. The 37 documents
phrased in a way that appears nowhere in the 60 are invisible to it. Accuracy
matched to half a point because head classes dominate it; macro-F1 diverged
because that is where the tail shows.

The general form: *k-fold cross-validation on a sample biased the same way as
the training set reports the bias back as success.*

### Two approaches, and why the agreement between them is worth less than it looks

Approach B shares nothing with A but the input text and the 60 labels: signed
feature hashing into a 256-dimensional unit vector, one nearest neighbour by
cosine. No training step, no model artefact, no Python at inference.

| | accuracy | macro-F1 | seen | unseen |
|---|---|---|---|---|
| A TF-IDF + logistic regression | 85.42% | 0.7489 | 203/203 | 2/37 |
| B hashed vector + 1-NN | 84.58% | 0.7446 | 202/203 | 1/37 |

**0.84 points apart, and identical per-class recall on 7 of 10 classes to three
decimals.** Two unrelated lexical methods hitting the same ceiling is the
evidence that the ceiling belongs to the corpus and the label sample. A third
lexical model would not move it; more labels covering the missing templates, or
a real embedding model in place of the hash, would.

| | n | A right | B right | accuracy |
|---|---|---|---|---|
| the two agree | 218 (90.8%) | 202 | 202 | 92.7% |
| the two disagree | 22 (9.2%) | 3 | 1 | 13.6% |

Both got **exactly 202** of the 218 agreements right, so where they agree and
are wrong they produce the same wrong label. Agreement is not independent
evidence — the two fail identically because they read the same surface
features. It is also the weaker router: confidence ≥ 0.235 gives 100% on 80% of
the corpus, agreement gives 92.7% on 90.8%.

### Sentiment is a lexicon, and it is labelled for what it measures

A scalar Python UDF counting words from a fixed list. Every complaint is
negative by construction, so this measures **intensity, not polarity**. The
per-class table shows the limit plainly: MISSING_ITEM scores 4.33 and
LATE_DELIVERY 2.41, which is an ordering of the word list rather than of
operational severity. Not something to put in front of a user as sentiment.

### Vectors are lexical, not semantic

`VECTOR(FLOAT, 256)` and `VECTOR_COSINE_SIMILARITY` are native. An embedding
model is not, because Cortex is unavailable, so the vectors come from signed
feature hashing in a UDF. Two complaints are close when they share words. "The
milk was warm" and "the cold chain failed" are unrelated to this UDF. The
upgrade is staging `all-MiniLM-L6-v2` inside the UDF, and any write-up has to
say which of the two it is doing.

Same-code pairs sit at 0.4029 cosine, different-code pairs at 0.1898 — enough
separation for nearest neighbour to work, which is why B lands where it does.

### Failures in this part

| | |
|---|---|
| Two adjacent string literals across lines | Python's concatenation rule, not SQL's. Killed `p10_eval.sql` after the scores were already written. Joined with `\|\|` |
| `NTILE(...) OVER (...)` in a select list grouped by its alias | A window function is evaluated **after** `GROUP BY`, so it cannot be grouped by: "CONFIDENCE is not a valid group by expression". Killed both scripts. Fixed by assigning the tile in a subquery. A sweep found four more apparent instances, all false positives — a window over an aggregate, `SUM(COUNT(*)) OVER ()`, is legal |
| A check that asserted no two complaints are token-identical | It failed, and **the assertion was wrong, not the data**. Digits are dropped by the tokeniser, so two complaints from one template differing only in a minute count are the same document. Rewritten to assert the hash is not degenerate, and the duplicate count is now reported rather than guarded against |
| Predicted accuracy 88–93%, macro-F1 0.78–0.88 | Actual 85.42% and 0.7489. **Both below the stated range**, and the second time in two parts that the magnitudes came in low while the mechanism prediction held |
| Predicted CV would read below held-out | It read above. See above — the reasoning was wrong, not just the number |

### What was UNVERIFIED and turned out to work

- **The Model Registry accepts a text pipeline.** `log_model` with
  `sample_input_data` as a one-column STRING frame infers the signature and
  registers. `COMPLAINT_REASON` V1 and V2 exist.
- **`pypdf` in a Snowpark UDF**, settled back in `p6_pkg_probe.sql`. The
  Anaconda ToS gate two sessions of planning assumed would block this does not
  exist on this account.

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

**Still unset: the account budget.** Sixteen routes have run against an account
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
| **Account budget** | Snowsight -> Admin -> Cost Management -> Budgets -> Account Budget -> 80 credits + email. `RM_POC` caps virtual-warehouse credits only; Snowpipe, Snowpipe Streaming and dynamic-table refresh are invisible to it. Thirteen ingestion mechanisms, two CORE builds, a MART build and three registered model versions have now run against an account with no serverless cap at all |
| **Credits backfill** | `sql/p3_credits_backfill.sql`, once `ACCOUNT_USAGE` has caught up. The ~3 h latency means Part 3-5 spend is still unmeasured. 3.78 credits is the last verified figure and it predates all of it |

The Session 1 foundation items are closed: `SVC_KAFKA` has a key pair
(`HAS_KEYPAIR = true`) and Enterprise was confirmed by `CREATE MASKING POLICY`
rather than by `SHOW`.

### 3. Where the build stands

| Stage | State |
|---|---|
| Ingestion | closed at 13 of 14. Mechanism 11 is not deferred, it is unavailable — external access is refused on a trial account and no rework reaches it. `sql/p6_external_access.sql` stops at the wall by design |
| `CORE` | complete — Parts 7 and 10 |
| `MART` | complete — Part 8, 9 dbt models, 42 tests passing |
| `LAB` | complete — Parts 9 and 10, three registered model versions across two models |

**Next is Part 11 — Streamlit in Snowflake.** Everything it would display now
exists: SLA risk scores per order, complaint classifications with a confidence
band, the funnel and anomaly split, the DQ results table, and the model metrics
across versions.

Two capability questions to settle by attempting them rather than by reading a
privileges list, as with the three findings in §1 of `ARCHITECTURE.md`: whether
Streamlit apps can be created on a trial account at all, and which package
versions the app runtime carries, which is a different channel from the UDF
runtime that `p6_pkg_probe.sql` measured.

Carry three lessons forward.

- From mechanism 10: **a stream is the delta, never the backfill.**
  `CREATE OR REPLACE STREAM` resets the offset and is how 300 pending files
  were lost.
- From Part 9: **a marginal relationship can be flat or reversed while the
  conditional one is strong**, so a quartile table is description, never
  evidence.
- From Part 10: **a check can encode a false belief about the data.** The one
  asserting no two complaints are token-identical failed, and the data was
  right. Before a red check is treated as a defect, establish which of the two
  is wrong.

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

Downstream of `RAW`, as built:

| Target | Rows | Part |
|---|---|---|
| `CORE.ORDER_HEADER` / `ORDER_ITEM` / `ORDER_STATUS_EVENT` | 20,000 / 54,635 / 78,874 | 7 |
| `CORE.INVENTORY_DAILY` | 96,000 | 7 |
| `CORE.CUSTOMER` / `PRODUCT` / `RIDER` / `STORE` | 500 / 200 / 60 / 8 | 7 |
| `CORE.DIM_PRODUCT` | 220 — 200 current, 20 closed | 7, SCD2 |
| `CORE.ORDER_FUNNEL` / `ORDER_CANCELLED` / `ORDER_LIFECYCLE_ANOMALY` | 19,029 / 623 / 348 | 7, partitions 20,000 exactly |
| `MART` — 9 models | `dim_date` 213, dims 500/220/60/8, `fct_order` 20,000, `fct_order_item` 54,635, `fct_order_status_event` 78,874, `fct_inventory_daily` 96,000 | 8 |
| `LAB.ORDER_FEATURES` | 19,377 | 9 |
| `LAB.ORDER_SCORES` | 19,377 | 9 |
| `LAB.SLA_BREACH` | model, V1 | 9 |
| `CORE.COMPLAINT` | 300 | 10 |
| `LAB.COMPLAINT_VECTOR` | 300, `VECTOR(FLOAT, 256)` | 10 |
| `LAB.COMPLAINT_PREDICTION` / `COMPLAINT_KNN_PREDICTION` | 300 / 300 | 10 |
| `LAB.COMPLAINT_REASON` | model, V1 and V2 | 10 |
| `OPS.COMPLAINT_TRUTH` | 300 — answer key, evaluation only | 10 |

`SERVE` is still empty — that is Part 13.

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
| `sql/p3_*` – `sql/p6_*` | Ingestion, mechanisms 1-14. `p6_external_access.sql` stops at the trial wall |
| `sql/p7_core_*.sql` | CORE — conformance, SCD2, `MATCH_RECOGNIZE` funnel |
| `sql/p8_grants.sql` | `ON ALL` + `ON FUTURE` for `QC_ENGINEER`. A schema grant is not an object grant |
| `sql/p9_features.sql` | `LAB.ORDER_FEATURES` — leakage-free, in the generator's own scaling |
| `sql/p9_train.sql` | Training sproc, Model Registry, `OPS.MODEL_METRICS` + `MODEL_COEFFICIENTS` |
| `sql/p9_score.sql` | Warehouse-side scoring, decile lift, calibration, SQL model surface |
| `sql/p9_report.sql` | Read-only reprint of the Part 9 results. No DDL, no DML, no refit |
| `sql/p9_ml_probe.sql`, `sql/p9_registry_fix.sql` | What ML this account permits, and the three registry variants |
| `sql/p10_text_prep.sql` | `CORE.COMPLAINT` — header split from prose, wrap undone, order id corrected |
| `sql/p10_classify.sql` | TF-IDF + logistic regression, registered. Reads no answer key |
| `sql/p10_vectors.sql` | Hashing UDF → `VECTOR(FLOAT, 256)`, cosine similarity, 1-NN, tone lexicon |
| `sql/p10_eval.sql`, `sql/p10_eval_compare.sql` | The only files that read the answer key |
| `scripts/p10_truth.sh` | Regenerates and loads the answer key. Dry-run unless `LOAD=1` |
| `dbt/` | Pinned image, 9 MART models, 42 tests, `dbt_utils` |
| `scripts/dbt.sh` | Builds `qc-dbt:1.12.4` once, forwards any dbt args |
| `scripts/sql.sh` | Runs a SQL file, prints result tables and errors only. `--full` for everything |
| `scripts/p7_cdc_sink.sh` | Second v4 sink for the CDC topics. `create` redacts the private key |
| `scripts/p7_source_reset.sh` | Full `down -v` rebuild. Dry-run unless `RESET=1` |
| `scripts/p7_mutate_source.sh` | Deterministic Postgres mutations. `APPLY=1` to run |

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

## Resume here

### 1. Bring the source stack back up

```bash
cd ~/Downloads/GIT/snowflake_usecase/source
docker compose up -d              # no reseed needed, the volume persists
docker exec -i qc-redpanda rpk topic list
curl -s localhost:8083/connectors/qc-postgres-cdc/status | python3 -m json.tool
```

Console at http://localhost:8081.

### 2. Three things left from the foundation

| | |
|---|---|
| **Account budget** | Snowsight → Admin → Cost Management → Budgets → Account Budget → 80 credits + email. The only control that sees Snowpipe spend |
| **Service user keys** | `SVC_KAFKA` and `SVC_CI` have no `RSA_PUBLIC_KEY`. The Kafka connector has no browser, so key-pair is the only option |
| **Enterprise confirmation** | `CREATE MASKING POLICY` in a throwaway database, then drop it |

Key generation, when you get to it:

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_kafka.p8 -nocrypt
openssl rsa -in rsa_kafka.p8 -pubout -out rsa_kafka.pub
chmod 600 rsa_kafka.p8
grep -v "^-----" rsa_kafka.pub | tr -d '\n'      # paste into ALTER USER
```

`rsa_key*` and `*.p8` are gitignored. Never commit or paste a private key.

### 3. Then: ingestion

Fourteen mechanisms, none built. Start with the three that share one source, so
the latency and credit comparison holds inputs constant:

1. Kafka Connector v4 on Snowpipe Streaming
2. Snowpipe Streaming SDK, direct, no Kafka
3. Kafka connector in Snowpipe file mode

The connector jar goes in `source/connectors/plugins/`, which is already mounted
writable into the Connect container.

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

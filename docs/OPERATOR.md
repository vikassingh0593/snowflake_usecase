# Operator guide — you execute, Claude authors

Decision recorded 2026-09-09: **the operator runs everything on their own machine.**
The Claude session's egress proxy denies `*.snowflakecomputing.com` and
`management.azure.com`, so no statement can be executed from there. Claude writes and
reviews; you run and paste back.

If you later widen the environment's network policy
([Custom access level](https://code.claude.com/docs/en/cloud-environments#access-levels)),
nothing in this guide changes — the same commands just get run by Claude instead.

---

## 0. One-time setup — about 20 minutes

Do all of Part A before Part 1. Parts B and C can wait until the part that needs them.

### A. Required now

| Tool | Why | Install |
|---|---|---|
| **Python 3.11** | Snowpark and `snowflake-ml-python` pin to ≤ 3.11. 3.12 will fail | `python3.11 --version` |
| **Snowflake CLI** (`snow`) | runs `.sql` files, `PUT` to stages, `EXECUTE IMMEDIATE FROM`. Snowsight cannot `PUT` a local file | `pip install -U snowflake-cli` |
| **git** | you already have it | — |

### B. Needed from Part 2

| Tool | Why |
|---|---|
| **Docker + compose** | Postgres 16, Redpanda, Kafka Connect, Debezium, Snowflake sink v4 |
| **dbt-snowflake** | Parts 7, 8, 9, 15. Pulls `dbt-core` |

### C. Needed from Part 1, but skippable

| Tool | Why | Skip by |
|---|---|---|
| **Azure CLI** | resource group, storage account, containers, Event Grid | using **[Azure Cloud Shell](https://shell.azure.com)** — browser, `az` preinstalled, nothing to install. The Part 1 script runs there unchanged |

---

## 1. Bootstrap — copy-paste block

Run from the repo root.

```bash
# clone if you have not already
git clone https://github.com/vikassingh0593/snowflake_usecase.git
cd snowflake_usecase
git checkout claude/snowflake-quickcommerce-poc-2kd9jy

python3.11 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate

pip install -U pip
pip install -U snowflake-cli
pip install "snowflake-connector-python[pandas]" snowflake-snowpark-python
pip install dbt-snowflake                       # pulls dbt-core

snow --version
dbt --version
python -c "import snowflake.snowpark, pandas; print('snowpark ok')"
```

`snowflake-ml-python` (Model Registry, Feature Store) is installed at **Part 9**, not
now — it drags a large dependency tree and pins hard.

---

## 2. Key-pair auth — do this before Part 1

Password auth is banned by `CLAUDE.md` §2.5. Generate an **unencrypted** key and
protect it with file permissions. A passphrase would have to live in `.env`, which is
the same rule violation in a different file.

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
chmod 600 rsa_key.p8

# strip header/footer and newlines — this is what Snowflake wants
grep -v "^-----" rsa_key.pub | tr -d '\n'; echo
```

`rsa_key*` is already gitignored. **Never paste the private key anywhere, including to
Claude.** The public key is safe to share.

Register it — this is DDL on your own user, so it is the first statement of Part 1:

```sql
ALTER USER <your_login_name> SET RSA_PUBLIC_KEY = '<the single-line public key>';
DESC USER <your_login_name>;   -- RSA_PUBLIC_KEY_FP should be populated
```

Then configure the connection:

```bash
snow connection add \
  --connection-name qcpoc \
  --account "<see section 3>" \
  --user "<your_login_name>" \
  --private-key-file ./rsa_key.p8 \
  --role ACCOUNTADMIN \
  --warehouse WH_TRANSFORM_XS \
  --database QCOMMERCE \
  --schema CORE

snow connection test -c qcpoc
```

`WH_TRANSFORM_XS` and `QCOMMERCE` do not exist until Part 1 creates them. Until then
point `--warehouse` at `SNOWFLAKE_LEARNING_WH` and drop `--database`/`--schema`.

---

## 3. Which account identifier

Unresolved, and it matters — `snow connection test` fails on the wrong one.

| Source | Value |
|---|---|
| Snowsight URL | `app.snowflake.com/awttgvh/olb61128` → suggests `AWTTGVH-OLB61128` |
| `CURRENT_ACCOUNT()` | `OOB49311` — this is the **locator**, not the name |

Try in this order, stopping at the first that connects:

1. `AWTTGVH-OLB61128`
2. `AWTTGVH-OOB49311`
3. `OOB49311.us-west-2.aws`

Record the winner in `.env` as `SNOWFLAKE_ACCOUNT` and tell Claude which one worked.

---

## 4. Azure

Use **[Cloud Shell](https://shell.azure.com)** unless you want `az` locally. Either way,
first command of Part 1:

```bash
az account show --query "{tenantId:tenantId, sub:name, subId:id}" -o table
az storage account show -n snowflakefreeedition -g databricksfreeedition \
   --query "{loc:location, hns:isHnsEnabled, kind:kind, sku:sku.name}" -o table
```

The second one decides whether the existing storage account is reusable. Per
`CLAUDE.md` §4: reuse **only** if `loc = westus2` **and** `hns = false`. Expect it to
fail both — a Databricks Free Edition account almost certainly has hierarchical
namespace on, which breaks Iceberg's `dfs` endpoint and `COPY … PURGE`.

**Never run an `az` create or delete command before Claude has shown it to you and you
have agreed.** Same rule in both directions.

---

## 5. How to hand results back

Raw paste. Do not reformat, do not summarise, do not trim error text — the error string
is usually the whole answer, as it was for the Cortex block.

| Kind of output | Paste |
|---|---|
| Scripting probe block | the single text cell, all lines |
| `SHOW` / `SELECT` | the grid as text, or a screenshot |
| A failure | the **full** error, including the code |
| `az` | the command's stdout |

If something errors halfway, say which statement it stopped on. Partial results are
still useful; a summary of them is not.

---

## 6. Standing rules for you, not Claude

| Rule | Why |
|---|---|
| Never paste `rsa_key.p8`, `.env`, or any password | `CLAUDE.md` §2.5 |
| Warehouses stay **XS**, `AUTO_SUSPEND = 60` | §2.3. Resizing is the fastest way to burn the balance |
| Check `docs/CREDITS.md` after each part | §3. `ACCOUNT_USAGE` lags up to ~3 h |
| Anything always-on gets torn down in the same part | materialized views, search optimization, hybrid tables, Snowflake Postgres |
| `teardown.sql` / `teardown.sh` stay current from Part 1 | one command must destroy everything |

---

## 7. Queue — what to do next, in order

| # | Action | Blocks |
|---|---|---|
| 1 | Run `sql/p0_probe4_ddl.sql` in Snowsight. Paste the text cell + confirm `QC_PROBE_TMP` is gone | closes Part 0; decides whether Parts 8 and 12 use real policies or substitutes |
| 2 | Section 1 of this guide — venv, `snow`, verify | everything |
| 3 | Section 2 — generate the key pair, keep the public key ready | Part 1 |
| 4 | Section 3 — find the working account identifier | Part 1 |
| 5 | Section 4 — the two read-only `az` commands | Part 1 storage decision |
| 6 | Read `docs/BUILD_GUIDE.md` — the stage-by-stage manual for the whole project | Parts 1-17 |
| 7 | Say **"Part 1"** when you want the reviewed scripts for that part |  |

Steps 2–5 are independent of step 1 — run them in parallel while the probe is open.

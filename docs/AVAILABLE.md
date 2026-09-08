# Part 0 — feature probe

Two independent columns, and they answer different questions:

- **Doc status** — what Snowflake's own docs/release notes say, checked live on
  2026-09-08. Filled in. Sources at the bottom.
- **Account verdict** — what `AWTTGVH-OLB61128` actually does when asked. **Empty until
  `sql/p0_probe.sql` is run in the account.** A GA feature can still be off on a
  Standard trial; doc status never substitutes for the probe.

Verdict vocabulary: `OK` · `FAIL` · `N/A` (not probeable read-only) ·
`ENTERPRISE` · `NOT AVAILABLE`.

Probed on: **2026-09-08 10:51 -0700** · org `AWTTGVH` · locator `OOB49311` ·
`AWS_US_WEST_2` · Snowflake `10.31.103` · role `ORGADMIN`

## Headline

| # | Finding | Blast radius |
|---|---|---|
| 1 | **Cortex AI functions are blocked on this account.** Not a privilege problem — the grants are correct. The error is categorical: *"AI function X is not available for trial accounts."* | **Part 10 as designed is dead.** Part 11's Ask tab loses Cortex Analyst. Redesign in §E |
| 2 | **Edition is not Standard, or the Standard gates are not where the brief assumes.** `ACCESS_HISTORY` was queryable and both "expect fail" gates passed | The whole substitution table in `CLAUDE.md` §2.2 may be unnecessary. `sql/p0_probe2.sql` settles it |
| 3 | Every SQL, geo, H3, VECTOR and metadata capability the build needs: **OK** | Parts 7, 8, 12 unaffected |
| 4 | **3.78 credits already consumed** before Part 1; account created 2026-08-27 (12 days old) | Budget rebased in `docs/CREDITS.md` |
| 5 | Account **locator is `OOB49311`**, but the Snowsight URL says `olb61128` | Connection strings in Part 1 need the real account name — probe 2 returns both |

---

## 0. Environment finding — this container cannot reach Snowflake or Azure

Established by direct test, not assumption. The session egress proxy returns
**403 CONNECT** (organisation policy denial) for:

| Host | Result | Consequence |
|---|---|---|
| `awttgvh-olb61128.snowflakecomputing.com` | 403 | no SQL can be executed from here, with any credential |
| `management.azure.com` | 403 | no `az` resource calls from here |
| `docs.snowflake.com`, `www.snowflake.com` | 403 | doc checks go through web search instead |
| `api.open-meteo.com` | 403 | mechanism 11 cannot be tested from here |

Reachable: `api.github.com`, `hub.docker.com`, PyPI. `az` and the Snowflake CLI are not
installed; Docker and Python 3.11 are.

**Working model this forces:** everything that touches Snowflake or Azure is authored
here as a reviewed script and executed by you, with output pasted back. That is
workable but it makes every part a round trip. See the note at the end of this file.

---

## A. Baseline — Section 1 result

| Check | Expected | Actual | Verdict |
|---|---|---|---|
| Organisation | `AWTTGVH` | `AWTTGVH` | OK |
| Account | `OLB61128` (from the URL) | **`OOB49311`** (`CURRENT_ACCOUNT()` returns the *locator*, the URL carries the *name*) | reconcile in probe 2 |
| Region | `AWS_US_WEST_2` | `AWS_US_WEST_2` | OK |
| Snowflake version | ≥ 9.x | `10.31.103` | OK, post-Summit |
| Current warehouse | — | `SNOWFLAKE_LEARNING_WH` | trial default, not one of ours |
| Edition | Standard | **not returned** | **pending probe 2 — see §E** |
| Credits consumed to date | ~0 | **3.782619** | rebase the budget |
| Account created | — | **2026-08-27** (databases `SNOWFLAKE_LEARNING_DB`, `SNOWFLAKE_SAMPLE_DATA`, `USER$VIKASSINGH0593`) | 12 days old |
| Trial expiry | brief says 120-day balance | **not returned** | pending probe 2 |

**Schedule risk downgraded.** If the 30-day trial clock is the binding one, sign-up on
2026-08-27 puts expiry near **2026-09-26** — 18 days of runway for a 2-day build. Not
urgent, but the balance-depletion clock now matters more than the calendar one, because
3.78 credits are already gone.

## B. Post-Summit-2026 features (brief §16)

| Feature | Doc status (checked 2026-09-08) | Account verdict | Decision |
|---|---|---|---|
| **Semantic View Autopilot** | **GA 2026-02-03, available to all accounts.** Generates semantic view DDL from existing tables; also imports a Power BI file (DAX measures, relationships) | | **Use it.** Part 10 writes no semantic YAML by hand unless the probe says otherwise |
| **Semantic Studio** | **Private preview** (Summit 2026). AI-assisted IDE for semantic views | | Skip — cannot be obtained in two days |
| **Iceberg v3** | **GA 2026-05-07** (preview 2026-03-04). Deletion vectors, row lineage, VARIANT, default column values, geometry/geography, nanosecond timestamps. External-engine reads via Horizon Iceberg REST Catalog also GA | | **Use v3.** Note: v2→v3 upgrade is **irreversible** on Snowflake-managed tables, and v2 readers cannot read v3. Create the archive table at v3 directly and document the delta |
| **Cortex Sense** | Announced Summit 2026. Runtime layer assembling data + business definitions + operational knowledge for agents at query time. Vendor benchmark **86%** on structured questions with full business context vs 24% for a generic frontier model (**the brief's 83% is the wrong figure**). Preview/GA status not established | | Probe. If absent, no design impact — Cortex Analyst covers the Ask tab |
| **Snowflake CoWork** (was Snowflake Intelligence) | Rename confirmed, June 2026. Expanded from chat-over-data to a work agent: Deep Research, MCP actions into Slack/Jira/Salesforce, file generation, reusable Skills. Docs page exists (`snowflake-cowork`) | | Probe via `SHOW AGENTS IN ACCOUNT`. Second seat in the Ask tab if present |
| **Horizon Context** | Announced Summit 2026 alongside Cortex Sense — shared business meaning/metadata/governance layer across humans and agents | | Probe |
| **Streaming Feature Views** | Not confirmed in this check | | Probe. Batch feature views are the fallback and cost nothing extra |
| **Native A/B testing on model versions** | Not confirmed in this check | | Probe via the `snowflake-ml-python` registry API |
| **Snowsight Pipeline Builder** | **Private preview.** Visually connects Notebooks and ML Jobs into a pipeline | | Screenshot only if the nav shows it. ML Jobs and Container Runtime are out of scope anyway |
| **Observe by Snowflake** | Not separately confirmed; Summit 2026 cost/observability track exists | | Probe the Snowsight cost surface |
| **AI Agent Identity** | Announced GA-track Summit 2026. Tags every agent action with a distinct signal; auditable, access restrictable in near real time | | Probe. Pairs with the Part 12 governance story if present |
| **Horizon AI Guardrails** | Related feature **Cortex AI Guardrails requires Enterprise Edition** | | Expect `ENTERPRISE`. Probe to confirm, then document as a Standard-Edition gap |
| **Multi-Party Approval** | Not confirmed in this check | | Probe |
| **Snowflake CoCo** (was Cortex Code) | Excluded from trial accounts; needs its own trial. Has its own daily credit-limit doc page | `NOT AVAILABLE` | **Confirmed by account owner: not enabled on this account.** Nothing depends on it |
| **Adaptive Compute** | Announced Summit 2026 | `SKIP` | Wrong risk on a fixed balance |
| **Cortex Training** (LLM fine-tuning) | Announced Summit 2026 | `SKIP` | Unpredictable cost |
| **Snowflake Datastream** | **Private preview.** Fully managed Kafka-protocol streaming service, lands topics as governed Snowflake or Iceberg tables | `NOT AVAILABLE` | Prose only, in `docs/DATASTREAM.md` (Part 16) |

---

## C. Capabilities the build already depends on

A `FAIL` here forces a design change in the named part. Probe all of them.

### C1 — SQL surface (`sql.*` probes)

| Capability | Needed by | Doc status | Account verdict |
|---|---|---|---|
| `ASOF JOIN` | Part 8 | GA | **OK** |
| `MATCH_RECOGNIZE` | Part 8 | GA | **OK** |
| `GEOGRAPHY` + `ST_DISTANCE` | Part 8 | GA | **OK** |
| `ST_DWITHIN` | Part 8 | GA | **OK** |
| `H3_LATLNG_TO_CELL` / `H3_GRID_DISK` / `H3_CELL_TO_BOUNDARY` | Parts 8, 11 | GA | **OK** |
| `VECTOR` type + `VECTOR_COSINE_SIMILARITY` | Part 10 | GA | **OK** |
| `QUALIFY` | Part 7 | GA | **OK** |
| `GENERATOR` + `SEQ4` + `UNIFORM` | Part 2 | GA | **OK** |
| Recursive CTE | Part 8 | GA | **OK** |
| `TABLESAMPLE` | Part 10 | GA | **OK** |

### C2 — Cortex — **BLOCKED**

Grants are correct and not the problem:

```
USE AI FUNCTIONS   ACCOUNT         OOB49311
USAGE              DATABASE_ROLE   SNOWFLAKE.CORTEX_USER
```

Both required grants are in place, and the call still fails. The error names the
account type, not the privilege:

> `AI function AI_CLASSIFY is not available for trial accounts.`

| Capability | Needed by | Account verdict | Error |
|---|---|---|---|
| `AI_COMPLETE` | Part 10 | **FAIL** | `_COMPLETE_WITH_PROMPT_HISTORY_LLM ... not available for trial accounts` |
| `AI_CLASSIFY` | Part 10 | **FAIL** | `AI_CLASSIFY ... not available for trial accounts` |
| `AI_FILTER` | Part 10 | **FAIL** | `_AI_FILTER_WITH_PROMPT ...` |
| `AI_EXTRACT` | Part 10 | **FAIL** | `_AI_EXTRACT ...` |
| `AI_SIMILARITY` | Part 10 | **FAIL** | `_AI_EMBED_WITH_PROMPT_1024 ...` |
| `AI_EMBED` | Part 10 | **FAIL** | `_AI_EMBED_WITH_PROMPT_768 ...` |
| `SENTIMENT` | Part 10 | **FAIL** | `SENTIMENT ...` |
| `EMBED_TEXT_768` | Part 10 | **FAIL** | `EMBED_TEXT_768 ...` |
| `COMPLETE` (legacy namespace) | Part 10 | **FAIL** | `COMPLETE ...` |
| `AI_AGG` | Parts 10, 11 | **OK — did not raise** | but "did not raise" ≠ "returned text". Probe 2 checks the actual value |
| `AI_SUMMARIZE_AGG` | Part 10 | **OK — did not raise** | same caveat |
| `AI_PARSE_DOCUMENT` | Part 10 | untested (needs a staged file) | expect FAIL by the same rule |
| **Cortex Analyst** | Parts 10, 11 | **expect FAIL** | needs an LLM. The Enterprise-edition rumour was a red herring; the real gate is *trial*, not *edition* |
| **Cortex Search** | Part 10 | **expect FAIL** | needs embeddings, which are blocked |
| **Snowflake CoWork** | Part 10 | **expect FAIL** | same |
| **Semantic View Autopilot** | Part 10 | **expect FAIL** | generates DDL with an LLM. GA and edition-independent, but that does not beat the trial gate |
| Trial AI cap (~10 credits/day) | Part 10 | **moot** | the cap describes accounts that can call these at all |

The ~10 credits/day figure from the docs describes trial accounts *with* AI access.
This account has none, so the cap never binds. `docs/CREDITS.md` line for Part 10 drops
from 20 credits to near zero.

### C3 — Platform objects (`SHOW` probes, Section 2)

| Capability | Needed by | Doc status | Account verdict |
|---|---|---|---|
| Dynamic tables | Part 8 | GA | OK |
| Iceberg tables + external volumes | Part 5 | GA | OK |
| Streamlit in Snowflake | Part 11 | GA | OK |
| Cortex Search services | Part 10 | GA | SHOW OK, service unusable (C2) |
| Semantic views | Part 10 | GA | SHOW OK, Autopilot expect FAIL (C2) |
| Agents (CoWork) | Part 10 | see §B | SHOW OK, agent unusable (C2) |
| Git repositories + Workspaces | Part 15 | GA | OK |
| `EXECUTE DBT PROJECT` / dbt projects | Part 15 | GA | OK |
| Application packages (Native App) | Part 13 | GA | OK |
| Managed accounts (reader) | Part 13 | GA, limit 20 per provider. **Trial support not stated in docs** — if `SHOW MANAGED ACCOUNTS` is rejected, sharing is not enabled and needs Snowflake Support | **OK — reader accounts are creatable** |
| Shares | Part 13 | GA | OK |
| **Object tags** | Part 12 | **Available on all editions since May 2025** for create/set. Enterprise only for tag *propagation*, tag-based masking policies, and the Snowsight Tags & policies UI. **The brief's Standard-Edition tag doubt is resolved: tagging works** | OK |
| Alerts | Part 12 | GA | OK |
| Resource monitors | Part 1 | GA | OK |
| Notebooks | Part 9 (Modin) | GA | OK |
| `SNOWFLAKE.ML` classes (FORECAST / ANOMALY_DETECTION / TOP_INSIGHTS) | Part 10 | GA (Top Insights GA 2024-11-04). **No edition gate found**; the Enterprise gate applies to *Data Quality Monitoring* anomaly detection, a different feature | **OK — classes present. Not LLM functions, so the trial AI gate should not apply. Confirm by actually training one in Part 10** |
| **Hybrid tables** | Part 14 | GA in all commercial AWS regions since 2024-11-13. Separate request billing removed 2026-03-01. Edition requirement not stated | **OK** |
| **Snowflake Postgres** | Part 14 | **GA 2026-02-24**, AWS + Azure. **AWS US West (Oregon) = `us-west-2` is on the launch list** — co-located with this account | not probeable via SHOW — Snowsight nav |
| **Kafka Connector v4** | Part 3 | **GA 2026-04-20.** Ground-up rewrite on Snowpipe Streaming High-Performance Architecture; up to 10 GB/s per table, 5–10 s end-to-end, exactly-once and ordered. Bundles Snowpipe Streaming SDK 1.6.0; migrates offset tokens from Classic channels on startup. **Snowpipe Streaming Classic has a published deprecation notice** — which is exactly why mechanism 3 (file mode) vs mechanism 1 (v4) is worth measuring | client-side, nothing to probe |

### C4 — Metadata layers (`meta.*` probes) — all OK

| View | Needed by | Account verdict |
|---|---|---|
| `ACCOUNT_USAGE.OBJECT_DEPENDENCIES` | Part 12 | OK |
| `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | Parts 12, 16 | OK |
| `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | every part | OK |
| `ACCOUNT_USAGE.METERING_HISTORY` | every part | OK |
| `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | Part 12 | OK |
| `INFORMATION_SCHEMA` | Part 12 | OK |
| `ACCOUNT_USAGE.ACCESS_HISTORY` | — | **OK — and it was expected to FAIL.** See C5 |

### C5 — the Enterprise gates did not gate. My probes were too weak.

Both "expect fail" probes returned OK, and so did `ACCESS_HISTORY`. Stated plainly:
**these three probes did not discriminate**, and the reason matters.

| Probe | Why the result is inconclusive |
|---|---|
| `gate.materialized_view_expect_fail` | queried `ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY`. That view exists on every edition and simply returns zero rows when the feature is unused. Wrong test |
| `gate.data_metric_functions_expect_fail` | `SHOW DATA METRIC FUNCTIONS` returns an empty set rather than erroring. Wrong test |
| `meta.access_history_absent_expected` | `SELECT COUNT(*)` on an empty view. **This one is real evidence** — on Standard the read should be rejected outright — but a single COUNT is thin ground for rewriting the architecture |

Two readings, and they lead to very different builds:

1. **The account is not Standard.** Snowflake trials commonly provision Enterprise. Then
   masking policies, row access policies, materialized views, search optimization, DMFs
   and 90-day Time Travel are all real, and `CLAUDE.md` §2.2's substitution table is
   solving a problem that does not exist.
2. **The account is Standard** and all three probes were simply badly chosen.

`sql/p0_probe2.sql` settles it with `SHOW ORGANIZATION ACCOUNTS` (the `edition` column,
definitive) plus `SHOW MASKING POLICIES` / `SHOW ROW ACCESS POLICIES`, which do reject
on Standard rather than returning empty.

## D. Confirmed absent — Standard Edition (do not re-probe)

masking policies · row access policies · aggregation policies · projection policies ·
data metric functions · materialized views · search optimization · query acceleration ·
automatic classification · `ACCESS_HISTORY` · object-bound event tables · Time Travel
beyond 1 day · multi-cluster warehouses · differential privacy · creating clean rooms ·
synthetic data generation · Cortex AI Guardrails.

---

## E. Decisions this probe forces

### E1 — settled on doc evidence, no account needed

| Decision | Choice | Rationale |
|---|---|---|
| Semantic view: Autopilot vs hand-written | **moot** — Autopilot needs an LLM, blocked | see E3 |
| Iceberg `FORMAT_VERSION` | **v3** | GA 2026-05-07. Create at v3; the v2→v3 upgrade is irreversible |
| Part 12 PII: tags vs secure views | **both** | tags classify, secure views enforce. Available regardless of edition |

### E2 — settled by probe 1

| Decision | Choice | Rationale |
|---|---|---|
| Part 13 reader account | **build it** | `SHOW MANAGED ACCOUNTS` accepted. Sharing is enabled |
| Part 14 hybrid table burst | **build it** | `SHOW HYBRID TABLES` accepted |
| Parts 7, 8 SQL surface | **unchanged** | `ASOF JOIN`, `MATCH_RECOGNIZE`, `GEOGRAPHY`, H3, `VECTOR`, `QUALIFY`, `GENERATOR` all OK |
| Part 12 metadata comparison | **unchanged** | all four metadata layers readable |

### E3 — Part 10 must be redesigned. Cortex is gone.

Every LLM-backed surface fails on the same rule. What survives, and what replaces what:

| Was | Status | Replacement | Honest cost of the swap |
|---|---|---|---|
| `AI_CLASSIFY` → complaint reason code | dead | sklearn classifier trained in a Snowpark sproc on the seeded complaint labels, versioned in **Model Registry** | more code, but it reuses Part 9's infrastructure and the model is *ours* — arguably a better artefact than a one-line function call |
| `SENTIMENT` | dead | lexicon UDF, or a second head on the same classifier | loses nuance; keeps the column |
| `AI_EXTRACT` → order id from free text | dead | regex UDF | **regex was always the right tool here.** AI_EXTRACT was overkill for a numeric id |
| `AI_PARSE_DOCUMENT` → complaint PDFs | expect dead | `pypdf` in a Snowpark UDF reading the directory table | mechanism 10 survives intact; text extraction only, no layout understanding |
| `EMBED_TEXT_768` / `AI_EMBED` → `VECTOR` search | dead | feature-hashing / TF-IDF vectoriser in a Snowpark UDF → `VECTOR(FLOAT, 256)`, then `VECTOR_COSINE_SIMILARITY` as designed | **lexical, not semantic.** Say so in the write-up. Upgrade path: stage `all-MiniLM-L6-v2` (~90 MB) and run it in the UDF — real embeddings, ~20 min of setup, needs a local download |
| **Cortex Search** vs hand-rolled vector search | dead | the hand-rolled side survives alone | the planned honest comparison becomes a documented gap, which is still a finding |
| **Cortex Analyst** / **CoWork** → Ask tab | dead | constrained query builder over the semantic view: pick metric + dimension + filter, show the generated SQL | loses NL. Keeps the semantic layer's point — that a governed metric definition is what makes any of this safe |
| `SNOWFLAKE.ML.FORECAST` / `ANOMALY_DETECTION` / `TOP_INSIGHTS` | **expected to survive** | unchanged | classical ML, not LLM inference. Classes are present. Confirm by training one |

**Net effect on the brief's goals:** the "two ML approaches compared" theme survives
(SQL ML functions vs Snowpark sklearn). The "AI over text" theme is reduced to
classical NLP. Part 10 shrinks from ~20 credits to ~4.

### E4 — open, needs a decision from the operator

| Question | Why it matters |
|---|---|
| **Convert the trial to paid?** Adding a card converts the account and unlocks Cortex. It also starts real billing once the free balance is gone. This is the only path to the AISQL suite | restores Part 10 as designed. **Money — your call, not mine** |
| **Edition** (probe 2) | if Enterprise, `CLAUDE.md` §2.2 is rewritten and Parts 8 and 12 gain masking policies, row access policies, materialized views and search optimization as *first-class* rather than substituted |
| Network policy widened for this session? | decides whether Parts 1–17 are scripts you paste or statements I run |

## F. Screenshots to capture

| Shot | Where | File |
|---|---|---|
| Snowsight left nav, fully expanded | any page | `docs/img/p0-nav.png` |
| AI & ML section | Snowsight → AI & ML | `docs/img/p0-aiml.png` |
| Cost Management → Budgets | Snowsight → Admin | `docs/img/p0-budgets.png` |
| Data Products / Provider Studio | Snowsight | `docs/img/p0-dataproducts.png` |
| Horizon / Catalog | Snowsight | `docs/img/p0-horizon.png` |
| Account edition + trial expiry | Snowsight → Admin → Accounts | `docs/img/p0-account.png` |

---

## G. Sources

Checked live 2026-09-08 via web search; `docs.snowflake.com` is not directly fetchable
from this session, so these are search-surfaced doc pages and release notes.

- [Semantic View Autopilot](https://docs.snowflake.com/en/user-guide/views-semantic/autopilot) · [Snowflake blog](https://www.snowflake.com/en/blog/semantic-view-autopilot/)
- [Iceberg v3 GA release note, 2026-05-07](https://docs.snowflake.com/en/release-notes/2026/other/2026-05-07-iceberg-v3-ga) · [v3 spec support](https://docs.snowflake.com/en/user-guide/tables-iceberg-v3-specification-support)
- [Kafka Connector v4.0 GA, 2026-04-20](https://docs.snowflake.com/en/release-notes/2026/other/2026-04-20-kafka-connector-v4-ga) · [Snowpipe Streaming classic deprecation notice](https://docs.snowflake.com/en/user-guide/snowpipe-streaming/snowpipe-streaming-classic-deprecation)
- [Snowflake Postgres GA, 2026-02-24](https://docs.snowflake.com/en/release-notes/2026/other/2026-02-24-snowflake-postgres-ga)
- [Hybrid tables Azure GA, 2025-10-06](https://docs.snowflake.com/en/release-notes/2025/other/2025-10-06-hybrid-tables-azure-ga) · [hybrid table pricing change, 2026-03-02](https://docs.snowflake.com/en/release-notes/2026/other/2026-03-02-hybrid-tables-pricing)
- [AISQL privileges and model access](https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-privileges-and-access) · [AISQL regional availability](https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-regional-availability)
- [Snowflake AI pricing](https://docs.snowflake.com/en/user-guide/snowflake-cortex/pricing) · [Cortex AI Guardrails (Enterprise)](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-ai-guardrails)
- [Trial accounts](https://docs.snowflake.com/en/user-guide/admin-trial-account) · [Overview of Snowflake CoWork](https://docs.snowflake.com/en/user-guide/snowflake-cortex/snowflake-cowork)
- [Object tagging introduction](https://docs.snowflake.com/en/user-guide/object-tagging/introduction) · [Data Governance release note, 2025-05-30](https://docs.snowflake.com/en/release-notes/2025/other/2025-05-30-tags)
- [CREATE MANAGED ACCOUNT](https://docs.snowflake.com/en/sql-reference/sql/create-managed-account) · [Manage reader accounts](https://docs.snowflake.com/en/user-guide/data-sharing-reader-create)
- [Top Insights GA, 2024-11-04](https://docs.snowflake.com/en/release-notes/2024/other/2024-11-04-top-insights-ga) · [ML Functions overview](https://docs.snowflake.com/en/guides-overview-ml-functions)
- Summit 2026 recaps (secondary, used only for preview status): [Aimpoint Digital](https://www.aimpointdigital.com/blog/for-data-leaders-snowflake-keynote-announcement-round-up-for-data-engineering) · [select.dev](https://select.dev/posts/snowflake-summit-2026-what-actually-shipped-and-what-it-means) · [Atlan](https://atlan.com/know/snowflake/summit-2026-announcements/)

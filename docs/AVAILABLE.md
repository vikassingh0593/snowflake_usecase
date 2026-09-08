# Part 0 — feature probe

Two independent columns, and they answer different questions:

- **Doc status** — what Snowflake's own docs/release notes say, checked live on
  2026-09-08. Filled in. Sources at the bottom.
- **Account verdict** — what `AWTTGVH-OLB61128` actually does when asked. **Empty until
  `sql/p0_probe.sql` is run in the account.** A GA feature can still be off on a
  Standard trial; doc status never substitutes for the probe.

Verdict vocabulary: `OK` · `FAIL` · `N/A` (not probeable read-only) ·
`ENTERPRISE` · `NOT AVAILABLE`.

Probed on: `<pending>` · Account `AWTTGVH-OLB61128` · Standard trial · `AWS_US_WEST_2`

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

## A. Baseline — Section 1 of `sql/p0_probe.sql`

| Check | Expected | Actual | Verdict |
|---|---|---|---|
| Organisation / account | `AWTTGVH` / `OLB61128` | | |
| Region | `AWS_US_WEST_2` | | |
| Snowflake version | ≥ 9.x post-Summit-2026 | | |
| Edition | Standard | | |
| Credits consumed to date | ~0 | | |
| **Trial expiry date** | brief says 120-day balance | | |
| `ORGADMIN` available | probably | | |

**Conflict to resolve on the first probe run.** Snowflake's trial docs state a trial
runs *30 days from sign-up or until the free balance is depleted, whichever comes
first*. The brief assumes a 120-day balance. If the account is on the 30-day clock and
was created more than ~28 days ago, the whole build has a hard deadline that has
nothing to do with credits. Read the actual expiry off Snowsight → Admin → Accounts
before Part 1. This is a schedule risk, not a cost risk.

---

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
| `ASOF JOIN` | Part 8 | GA | |
| `MATCH_RECOGNIZE` | Part 8 | GA | |
| `GEOGRAPHY` + `ST_DISTANCE` | Part 8 | GA | |
| `ST_DWITHIN` | Part 8 | GA | |
| `H3_LATLNG_TO_CELL` / `H3_GRID_DISK` / `H3_CELL_TO_BOUNDARY` | Parts 8, 11 | GA | |
| `VECTOR` type + `VECTOR_COSINE_SIMILARITY` | Part 10 | GA | |
| `QUALIFY` | Part 7 | GA | |
| `GENERATOR` + `SEQ4` + `UNIFORM` | Part 2 | GA | |
| Recursive CTE | Part 8 | GA | |
| `TABLESAMPLE` | Part 10 | GA | |

### C2 — Cortex (`cortex.*` probes)

AISQL needs **two** grants: the `USE AI FUNCTIONS` account privilege (granted to
`PUBLIC` by default) **plus** the `CORTEX_USER` or `AI_FUNCTIONS_USER` database role.
Section 2 of the probe checks both. AI Credits are priced flat **regardless of
edition** — which is the strongest available evidence that Cortex is not
Enterprise-gated, but it is not a statement about a Standard *trial*.

| Capability | Needed by | Doc status | Account verdict |
|---|---|---|---|
| `AI_COMPLETE` | Part 10 | GA, region-gated | |
| `AI_CLASSIFY` | Part 10 | GA | |
| `AI_FILTER` | Part 10 | GA | |
| `AI_AGG` | Parts 10, 11 | GA | |
| `AI_SUMMARIZE_AGG` | Part 10 | GA | |
| `AI_EXTRACT` | Part 10 | GA | |
| `AI_SIMILARITY` | Part 10 | GA | |
| `AI_EMBED` | Part 10 | GA | |
| `SENTIMENT` | Part 10 | GA | |
| `EMBED_TEXT_768` (legacy namespace) | Part 10 | GA | |
| `COMPLETE` (legacy `SNOWFLAKE.CORTEX`) | Part 10 | GA | |
| `AI_PARSE_DOCUMENT` | Part 10 | GA — needs a staged file, so existence only | |
| **Cortex Analyst** | Parts 10, 11 | **No edition gate found in the docs.** A widely-repeated blog claim that it needs Enterprise is not supported by the doc pages checked, and conflicts with flat edition-independent AI Credit pricing. **Treat as UNVERIFIED until the probe** | |
| **Cortex Search** | Part 10 | Edition requirement not stated in docs | |
| **Trial AI cap** | Part 10 | **Confirmed in docs:** trial accounts without a valid payment method are limited to roughly **10 credits/day** of Cortex AI Functions | |

### C3 — Platform objects (`SHOW` probes, Section 2)

| Capability | Needed by | Doc status | Account verdict |
|---|---|---|---|
| Dynamic tables | Part 8 | GA | |
| Iceberg tables + external volumes | Part 5 | GA | |
| Streamlit in Snowflake | Part 11 | GA | |
| Cortex Search services | Part 10 | GA | |
| Semantic views | Part 10 | GA | |
| Agents (CoWork) | Part 10 | see §B | |
| Git repositories + Workspaces | Part 15 | GA | |
| `EXECUTE DBT PROJECT` / dbt projects | Part 15 | GA | |
| Application packages (Native App) | Part 13 | GA | |
| Managed accounts (reader) | Part 13 | GA, limit 20 per provider. **Trial support not stated in docs** — if `SHOW MANAGED ACCOUNTS` is rejected, sharing is not enabled and needs Snowflake Support | |
| Shares | Part 13 | GA | |
| **Object tags** | Part 12 | **Available on all editions since May 2025** for create/set. Enterprise only for tag *propagation*, tag-based masking policies, and the Snowsight Tags & policies UI. **The brief's Standard-Edition tag doubt is resolved: tagging works** | |
| Alerts | Part 12 | GA | |
| Resource monitors | Part 1 | GA | |
| Notebooks | Part 9 (Modin) | GA | |
| `SNOWFLAKE.ML` classes (FORECAST / ANOMALY_DETECTION / TOP_INSIGHTS) | Part 10 | GA (Top Insights GA 2024-11-04). **No edition gate found**; the Enterprise gate applies to *Data Quality Monitoring* anomaly detection, a different feature | |
| **Hybrid tables** | Part 14 | GA in all commercial AWS regions since 2024-11-13. Separate request billing removed 2026-03-01. Edition requirement not stated | |
| **Snowflake Postgres** | Part 14 | **GA 2026-02-24**, AWS + Azure. **AWS US West (Oregon) = `us-west-2` is on the launch list** — co-located with this account | |
| **Kafka Connector v4** | Part 3 | **GA 2026-04-20.** Ground-up rewrite on Snowpipe Streaming High-Performance Architecture; up to 10 GB/s per table, 5–10 s end-to-end, exactly-once and ordered. Bundles Snowpipe Streaming SDK 1.6.0; migrates offset tokens from Classic channels on startup. **Snowpipe Streaming Classic has a published deprecation notice** — which is exactly why mechanism 3 (file mode) vs mechanism 1 (v4) is worth measuring | |

### C4 — Metadata layers (`meta.*` probes)

| View | Needed by | Expectation | Account verdict |
|---|---|---|---|
| `ACCOUNT_USAGE.OBJECT_DEPENDENCIES` | Part 12 | available | |
| `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` | Part 12, 16 | available | |
| `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` | every part | available | |
| `ACCOUNT_USAGE.METERING_HISTORY` | every part | available | |
| `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` | Part 12 | available on trial | |
| `INFORMATION_SCHEMA` | Part 12 | available | |
| `ACCOUNT_USAGE.ACCESS_HISTORY` | — | **expected FAIL** (Enterprise) — the probe confirms the substitution is necessary, not optional | |

### C5 — Enterprise gates, probed to prove the negative

`FAIL` is the expected and desired result. These two rows are evidence for the
substitution table in `CLAUDE.md` §2.2.

| Probe | Expectation | Account verdict |
|---|---|---|
| `MATERIALIZED_VIEW_REFRESH_HISTORY` | FAIL → dynamic tables instead | |
| `SHOW DATA METRIC FUNCTIONS` | FAIL → dbt tests + Snowpark DQ instead | |

---

## D. Confirmed absent — Standard Edition (do not re-probe)

masking policies · row access policies · aggregation policies · projection policies ·
data metric functions · materialized views · search optimization · query acceleration ·
automatic classification · `ACCESS_HISTORY` · object-bound event tables · Time Travel
beyond 1 day · multi-cluster warehouses · differential privacy · creating clean rooms ·
synthetic data generation · Cortex AI Guardrails.

---

## E. Decisions this probe forces

Three are already decided on doc evidence and do not need the account.

| Decision | Depends on | Choice | Rationale |
|---|---|---|---|
| Semantic view: Autopilot vs hand-written | B: Autopilot | **Autopilot** ✅ decided | GA since 2026-02-03, all accounts. Hand-writing the view costs an hour for no demo value |
| Iceberg `FORMAT_VERSION` | B: Iceberg v3 | **v3** ✅ decided | GA since 2026-05-07. Deletion vectors and row lineage are the whole reason to show Iceberg over a Snowflake table. Upgrade is irreversible, so create at v3 rather than v2-then-upgrade |
| Part 12 PII: tags vs secure views only | C3: object tags | **Both** ✅ decided | Tagging is available on all editions since May 2025. Tag-based masking is not — so tags classify, secure views enforce. That split is the finding |
| Ask tab: Analyst only, or Analyst + CoWork | B: CoWork, C2: Analyst | pending probe | |
| Feature Store: batch vs streaming feature views | B: Streaming Feature Views | pending probe | |
| Part 13: reader account vs listing-only | C3: managed accounts | pending probe | |
| Part 14: which burst(s) run | C3: hybrid tables, Snowflake Postgres | pending probe | Postgres is regionally co-located, so it is the stronger of the two |
| Cortex budget shape | C2: 10 credits/day cap | pending probe | If the cap is real, Part 10 needs **two calendar days**, which no amount of speed fixes |

---

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

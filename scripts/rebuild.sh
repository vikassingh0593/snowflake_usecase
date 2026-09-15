#!/usr/bin/env bash
# =============================================================================
# scripts/rebuild.sh — tear the account down and build it back from nothing.
#
#   scripts/rebuild.sh status      what exists in the account right now
#   scripts/rebuild.sh plan        the build order, numbered, nothing runs
#   scripts/rebuild.sh teardown    run sql/teardown.sql behind a confirm gate
#   scripts/rebuild.sh build       walk the plan, stopping at every manual gate
#   scripts/rebuild.sh build --from 12    resume at step 12
#   scripts/rebuild.sh build --to 6       stop after step 6
#   scripts/rebuild.sh build --dry-run    print each command instead of running
#
# THIS DOES NOT REBUILD THE ACCOUNT UNATTENDED, AND NOTHING COULD. Eleven of the
# forty-odd steps need a human somewhere that is not a terminal: an Azure tenant
# administrator granting consent to a service principal, a Marketplace listing
# accepted in Snowsight, a budget activated in a UI that has no SQL equivalent on
# this account. The honest shape for this file is therefore a guided runner, not
# a pipeline. It runs every step that can be run, halts at each gate with the
# exact instruction and the command to resume, and never pretends a gate was
# cleared. A script that claimed to do this in one pass would be lying in eleven
# places.
#
# COST OF A FULL BUILD: UNVERIFIED, estimated 1.5-3 credits. The measured cost of
# the original build was 5.869 credits, but that covered eight days of
# interactive iteration and 79.9% of warehouse time that was not execution. A
# straight-through run does the work once. Steps that resume a warehouse are
# marked WH in the plan; steps marked FREE use cloud services only.
#
# `status` and `plan` cost nothing. SHOW commands are cloud-services metadata
# reads and resume no warehouse.
# =============================================================================
. "$(dirname "$0")/lib.sh"

# -----------------------------------------------------------------------------
# The manifest. One line per step: kind | label | payload
#
#   sql    run this file through snow sql                        (may resume WH)
#   shell  run this script                                       (may resume WH)
#   dbt    run dbt through its pinned image                      (resumes WH)
#   gate   stop and print the payload; a human does it elsewhere (free)
#
# This array is also the answer to "which of the 58 files in sql/ are build
# steps". The rest are probes, diagnostics and verification reprints, which is
# invisible from a directory listing and is the reason this is a list and not a
# glob. They are named at the foot of `plan`.
# -----------------------------------------------------------------------------
MANIFEST=(
"gate|Azure foundation|SKIP THIS STEP IF THE STORAGE ACCOUNT ALREADY EXISTS. sql/teardown.sql
  removes nothing in Azure -- the resource group, the storage account, all four
  containers, the Event Grid topic and snowpipe-queue survive a teardown intact,
  and the blobs already in them are what the rebuild re-ingests.

  Nothing needs checking to continue: sql/teardown.sql contains no az command at
  all, and steps 2 and 3 are free DDL. The real check is gate 6's
  SYSTEM\$VERIFY_EXTERNAL_VOLUME, which fails loudly if the account or the
  containers are gone, and it comes before anything expensive. To confirm now
  anyway, do it in Azure Cloud Shell at shell.azure.com -- az is not installed
  on the Mac and no step in this project needs it there:
      az storage account show --name snowflakeqcpoc25056 -o table
  Either way, go to step 2.

  Only on a genuinely empty subscription, in Azure Cloud Shell, and read it
  first -- it creates billable Azure resources and asks before each one:
      bash scripts/p2_azure.sh
  Creates: resource group, GPv2 storage account with HIERARCHICAL NAMESPACE OFF
  (plain GPv2, never ADLS), four containers (landing, external, docs, archive),
  the Event Grid system topic and the snowpipe-queue it publishes to."
"sql|Snowflake foundation|sql/p1_bootstrap.sql"
"sql|Corrections found in the bootstrap output|sql/p1_fix.sql"
"gate|Register the service-user public keys|REUSE THE KEYS YOU ALREADY HAVE. DROP USER removes the registration,
  not the key pair. If rsa_kafka.p8 and rsa_ci.p8 are still in the repo root,
  generating new ones only invalidates dbt/profiles.yml and the connector
  config for nothing. Generate only if the .p8 files are missing:
      openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_kafka.p8 -nocrypt
      openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_ci.p8 -nocrypt

  Re-derive each public key from its private key before reading it. A missing
  .pub would otherwise leave K empty and the ALTER below would set a blank key
  without complaining. openssl writes the same bytes either way, so this is safe
  whether the .pub is there or not:
      openssl rsa -in rsa_kafka.p8 -pubout -out rsa_kafka.pub
      openssl rsa -in rsa_ci.p8 -pubout -out rsa_ci.pub

  Then re-register both on their TYPE = SERVICE users. The header and footer
  lines and every newline must come out, which is why this is a command and not
  a paste:
      K=\$(grep -v -- '-----' rsa_kafka.pub | tr -d '\\n')
      snow sql -c qcpoc -q \"ALTER USER SVC_KAFKA SET RSA_PUBLIC_KEY = '\$K'\"
      K=\$(grep -v -- '-----' rsa_ci.pub | tr -d '\\n')
      snow sql -c qcpoc -q \"ALTER USER SVC_CI SET RSA_PUBLIC_KEY = '\$K'\"

  Verify before going on -- RSA_PUBLIC_KEY_FP populated means registered:
      snow sql -c qcpoc -q 'DESC USER SVC_KAFKA' | grep RSA_PUBLIC_KEY_FP

  scripts/p2_rbac.sh is NOT this step. It grants Azure roles, and it belongs at
  step 6. rsa_key*, *.p8 and .env are gitignored; confirm before committing."
"sql|Azure integrations|sql/p2_integrations.sql"
"gate|Azure tenant-admin consent and RBAC|CHECK BEFORE DOING ANY OF THIS. On a rebuild in the same account it is
  almost certainly already done, and this was the longest gate in the project
  until a rebuild proved it a no-op:
      snow sql -c qcpoc -q \"SELECT SYSTEM\$VERIFY_EXTERNAL_VOLUME('EXVOL_QC')\"
  success:true with write, read, list, delete and azureGetUserDelegationKey all
  PASSED means consent and RBAC are intact. Go to step 7.

  WHY IT SURVIVES A TEARDOWN. Snowflake does not mint a service principal per
  integration object. The multi-tenant app is per account and storage account, so
  dropping EXVOL_QC, SI_QC_AZURE and NI_QC_SNOWPIPE and creating them again hands
  back the same two apps, and the tenant consent and the container role
  assignments granted to them still stand. Measured on this account, after a full
  teardown: n1fam5snowflakepacint_1788981137125 for blob and
  14bjnhsnowflakepacint_1788981138681 for the queue -- the same prefixes
  scripts/p2_rbac.sh has had hardcoded since the first build. UNVERIFIED as
  documented behaviour; verified here once.

  EVERYTHING BELOW IS FOR A FIRST BUILD, a different account, or a tenant where
  consent was revoked. Three objects, each with its own consent URL:

      DESC EXTERNAL VOLUME EXVOL_QC;      -- expand STORAGE_LOCATIONS for its URL
      DESC INTEGRATION SI_QC_AZURE;
      DESC INTEGRATION NI_QC_SNOWPIPE;

  The boxes wrap these badly. --format csv puts each property on one line:
      snow sql -c qcpoc -q \"DESC INTEGRATION SI_QC_AZURE\" --format csv | grep -i azure_

  For EACH of the three:
    1. Read AZURE_CONSENT_URL and AZURE_MULTI_TENANT_APP_NAME from the output.
    2. Open the consent URL signed in as a TENANT ADMINISTRATOR, accept.
    3. Azure portal -> Microsoft Entra ID -> Enterprise applications. Search the
       part of AZURE_MULTI_TENANT_APP_NAME BEFORE the underscore -- the suffix is
       a request id and will not match anything.
    4. Assign the role scoped to the CONTAINER, not the storage account:

         EXVOL_QC        archive          Storage Blob Data Contributor
         SI_QC_AZURE     landing          Storage Blob Data Reader
         SI_QC_AZURE     external         Storage Blob Data Reader
         SI_QC_AZURE     docs             Storage Blob Data Reader
         NI_QC_SNOWPIPE  snowpipe-queue   Storage Queue Data Contributor

       Reader on the three blob containers, never contributor: Snowflake reads
       them and never writes them. archive is the exception because Iceberg
       writes there. The queue needs contributor because Snowpipe dequeues.

  scripts/p2_rbac.sh automates step 4 and its two hardcoded app prefixes are
  correct for this account, for the reason above. On a different account, read
  AZURE_MULTI_TENANT_APP_NAME from the DESC outputs and put the prefixes in
  APP_BLOB and APP_QUEUE first. Run it in Cloud Shell; portal clicking is fine
  too, the script only exists because container-scoped grants are fiddly.

  RBAC PROPAGATION TAKES ABOUT FIVE MINUTES. Verification failing straight after
  a grant means wait, not debug.

  THE GATE, and do not go past a failure here -- every Iceberg step depends on it:
      SELECT SYSTEM\$VERIFY_EXTERNAL_VOLUME('EXVOL_QC');"
"sql|Stages, file formats, RAW tables|sql/p3_prep.sql"
"gate|Operational source and broker|On the machine with Docker. The subshell matters: cd source && docker
  compose up -d leaves the shell inside source/, where source/generate.py is
  source/source/generate.py and does not exist.
      (cd source && docker compose up -d)
      python3 source/generate.py
  Four services: Postgres 16 as the OLTP source, Kafka (Redpanda), its console,
  and Kafka Connect carrying Debezium. The generator resolves its output from
  its own path rather than the working directory, so it writes source/out/ from
  wherever it is invoked -- it is only the pair above that has to compose.

  docker compose up -d returns as soon as the containers are created, not when
  Connect is listening, and step 9 posts a connector to localhost:8083. Wait for
  it or that step fails on a connection refused that looks like a config error:
      until curl -sf localhost:8083/connectors >/dev/null; do sleep 3; done

  ON A REBUILD, THE BROKER IS NOT EMPTY. sql/teardown.sql removes Snowflake
  objects and nothing else, and the named volumes pgdata and rpdata survive
  docker compose down. Connect stores its connector configs in a Kafka topic, so
  the PREVIOUS build's connectors come back by themselves the moment Connect
  starts -- including Part 7's qc-postgres-cdc and qc-snowflake-cdc-v4, twenty
  steps early and pointed at tables this build has not created yet. Delete them
  and let steps 10 and 27 create what they own:
      curl -s "localhost:8083/connectors" | python3 -m json.tool
      curl -s -X DELETE localhost:8083/connectors/qc-snowflake-cdc-v4
      curl -s -X DELETE localhost:8083/connectors/qc-postgres-cdc

  THE TOPIC STEP 10 CONSUMES IS NOT PRODUCED BY ANYTHING IN THIS REPOSITORY.
  qc.order_status was produced by hand in Part 3 and never automated; every other
  topic is a Debezium snapshot that rebuilds itself, which is why only this one
  has ever gone missing. rpdata usually still holds it, so check before doing
  anything:
      docker exec qc-redpanda rpk topic describe -p qc.order_status
  A high watermark near 79,663 means it survived and step 10 will consume it. If
  the topic is gone, produce it from the generator output. Expect it to be gone
  on any account where Part 7 has run: p7_source_reset.sh deletes this topic and
  says so under WHAT IS NOT RECOVERED, so a teardown is not what loses it.
  Verified on rpk in this stack -- ten records first, then the rest:
      docker exec qc-redpanda rpk topic create qc.order_status -p 3
      docker exec -i qc-redpanda rpk topic produce qc.order_status \\
        < source/out/order_status.ndjson"
"shell|Kafka connector plugin|scripts/p3_connector.sh"
"shell|Sink connector, mechanisms 1 and 3|scripts/p3_sink.sh v4 && scripts/p3_sink.sh v3"
"shell|Snowpipe Streaming SDK, mechanism 2|scripts/run_in_container.sh stream"
"sql|Mechanisms 1 vs 2 vs 3 on identical input|sql/p3_benchmark.sql"
"gate|Clickstream upload|In Azure Cloud Shell. It is ephemeral -- no files survive the session -- so
  the repository has to be cloned each time. It is public, so no auth:
      git clone https://github.com/vikassingh0593/snowflake_usecase.git
      cd snowflake_usecase
      bash scripts/upload_source.sh clickstream
  One blob at a time, so Event Grid raises one notification per file and
  COPY_HISTORY shows N loads instead of one opaque one."
"sql|Snowpipe auto-ingest, mechanism 4|sql/p4_snowpipe_auto.sql"
"sql|Snowpipe REST, mechanism 5|sql/p4_snowpipe_rest.sql"
"shell|REST ingest driver|python3 scripts/p4_rest_ingest.py"
"sql|COPY and VALIDATE, mechanisms 6 and 7|sql/p4_copy_parquet.sql"
"gate|Settlement upload|In Azure Cloud Shell. It is ephemeral -- no files survive the session -- so
  the repository has to be cloned each time. It is public, so no auth:
      git clone https://github.com/vikassingh0593/snowflake_usecase.git
      cd snowflake_usecase
      bash scripts/upload_source.sh settlement

  ON A REBUILD THIS GATE IS OPTIONAL, unlike gate 13. Its consumer reads the
  container when it is queried rather than reacting to a blob-created event, so
  whatever the previous build uploaded is enough and nothing has to arrive
  again. Gate 13 is the exception: Snowpipe auto-ingest fires on Event Grid
  notifications, and a blob already sitting in landing/ raises none."
"sql|External table and Iceberg, mechanisms 8 and 9|sql/p5_external_iceberg.sql"
"gate|Complaint PDF upload|In Azure Cloud Shell. It is ephemeral -- no files survive the session -- so
  the repository has to be cloned each time. It is public, so no auth:
      git clone https://github.com/vikassingh0593/snowflake_usecase.git
      cd snowflake_usecase
      bash scripts/upload_source.sh complaints
  _truth.csv stays behind. It is the answer key for Part 10 and a label sitting
  in RAW next to the text it labels is how a model scores 100% on nothing.

  ON A REBUILD THIS GATE IS OPTIONAL, unlike gate 13. Its consumer reads the
  container when it is queried rather than reacting to a blob-created event, so
  whatever the previous build uploaded is enough and nothing has to arrive
  again. Gate 13 is the exception: Snowpipe auto-ingest fires on Event Grid
  notifications, and a blob already sitting in landing/ raises none."
"sql|Directory table over the PDFs, mechanism 10|sql/p6_directory_docs.sql"
"tier|External network access, mechanism 11|sql/p6_external_access.sql :: External access is not supported for trial accounts -- error 509009, SQL state 0A000, raised by CREATE EXTERNAL ACCESS INTEGRATION. The network rule and the secret create successfully; only the integration binding them is refused, which is exactly what README section 11 records as a tier gate. Route 11 cannot be built here. Note that a git API integration to the same public internet IS permitted: different integration type, different gate. Continue to step 23."
"gate|Marketplace listing|CHECK FIRST. sql/teardown.sql drops QCOMMERCE and QC_PROBE_TMP and no
  other database, so a mount acquired by a previous build is still there and
  this gate is a no-op, like gates 18 and 20:
      snow sql -c qcpoc -q \"SHOW DATABASES LIKE 'FINANCE%'\" --format csv
  A row whose kind is IMPORTED DATABASE and whose origin names another account
  is the zero-copy mount. Go to step 24.

  Otherwise, in Snowsight -> Data Products -> Marketplace:
      search   Finance & Economics    (Snowflake Public Data Products,
                                       formerly Cybersyn. Free, no trial)
      Get      database FINANCE__ECONOMICS, which is the name
               sql/p6_marketplace.sql expects
      grant    query access to QC_ENGINEER and QC_ANALYST
  There is no SQL that accepts a listing's terms on your behalf.

  Any free listing exercises the same mechanism; this one is the pick because
  it carries FX rates, and every amount in this platform is whole paise. If it
  has been renamed, step 24 discovers what actually arrived and only two
  identifiers change. Mind the warning in that file: a shared table can be
  enormous, and SELECT * against one is the cheapest way to be surprised."
"sql|Marketplace join, mechanism 12|sql/p6_marketplace.sql"
"shell|write_pandas, mechanism 13|scripts/run_in_container.sh pandas"
"gate|CDC|EVERY ONE OF THESE DEFAULTS TO A DRY RUN OR A READ. Without the
  modifiers below they print what they would do, exit 0, and change nothing:
      RESET=1 bash scripts/p7_source_reset.sh
      until curl -sf localhost:8083/connectors >/dev/null; do sleep 3; done
      bash scripts/p7_cdc_sink.sh create
      APPLY=1 bash scripts/p7_mutate_source.sh
  p7_cdc_sink.sh defaults to diagnose, which is worth running first on its own;
  the other two default to counting what they would change.

  RESET=1 RUNS docker compose down -v. That destroys pgdata and rpdata, and with
  them qc.order_status and every registered connector including Part 3s. Both
  are fine by this point: Part 3s tables are full and step 12 has measured them.
  Postgres re-initialises from the CSVs and Debezium snapshots 171,403 rows.

  WHY THE RESET IS NOT OPTIONAL ON A REBUILD. The seven qc.qc.* topics survive a
  teardown with their data, but so does _connect_offsets, so the sinks consumer
  group is already at the end of every one of them. Register the sink against
  that and each channel reports rowsInsertedCount 0 forever: the topics are full
  and there is nothing left to deliver. Only a re-snapshot puts new records
  after the committed offsets.

  Then wait for the connector to drain before step 27:
      bash scripts/p7_cdc_sink.sh status"
"sql|What landed from the seven CDC topics|sql/p7_cdc_verify.sql"
"sql|RAW to CORE, conformance and dedupe|sql/p7_core_conform.sql"
"sql|Streams and SCD2|sql/p7_core_scd2.sql"
"sql|MATCH_RECOGNIZE over the status stream|sql/p7_core_funnel.sql"
# THESE TWO ARE ORDER-CRITICAL AND WERE THE WRONG WAY ROUND. dbt connects as
# SVC_CI with role QC_ENGINEER; steps 28-30 build CORE as ACCOUNTADMIN. Without
# the grants first, seven of the nine models fail on 002003 (42S02) naming
# CORE.CUSTOMER, CORE.STORE, CORE.RIDER, CORE.DIM_PRODUCT, CORE.INVENTORY_DAILY,
# CORE.ORDER_FUNNEL and CORE.ORDER_STATUS_EVENT -- the "or not authorized" half
# of that error, not the "does not exist" half. dim_date builds anyway because
# it reads nothing from CORE, and the seeds load because QC_ENGINEER already
# holds RAW, so the run half-succeeds and the message points at the tables
# rather than at the role. p8_grants.sql has no MART dependency, so nothing
# argues for the other order.
"sql|Let QC_ENGINEER read what ACCOUNTADMIN built|sql/p8_grants.sql"
"dbt|The dimensional model, 9 models and 42 tests|build"
"sql|The feature table|sql/p9_features.sql"
"sql|Train, evaluate, register|sql/p9_train.sql"
"sql|Score with the registered model|sql/p9_score.sql"
"sql|Complaint text preparation|sql/p10_text_prep.sql"
"sql|Classify complaints to reason codes|sql/p10_classify.sql"
# The answer key. Held back from the training path on purpose -- the 300 PDFs
# went to blob without _truth.csv, so the classifier earns the other 240 -- and
# then held back from the manifest by accident, which is a different thing. It
# creates OPS.COMPLAINT_TRUTH, and p10_eval, p10_eval_compare and p11_serve all
# read it. LOAD=1 or it prints the statements and exits 0.
"shell|The answer key, held back until after the classifier ran|LOAD=1 scripts/p10_truth.sh"
"sql|Score the classifier against the answer key|sql/p10_eval.sql"
"sql|Vectors, similarity, a second classifier|sql/p10_vectors.sql"
"sql|The two approaches on the same 240|sql/p10_eval_compare.sql"
"sql|SERVE, the contract the app reads|sql/p11_serve.sql"
"shell|Deploy the console|DEPLOY=1 scripts/p11_deploy.sh"
"sql|Column and row protection|sql/p12_policies.sql"
"sql|Act on what the classifier found|sql/p12_classify_response.sql"
"sql|Quality rules and lineage|sql/p12_quality_lineage.sql"
"sql|Search optimization and the materialized view|sql/p12_serverless.sql"
"sql|An alert that fires on a real failure|sql/p12_alert.sql"
"sql|Repair: governance broke the performance layer|sql/p12_serve_repair.sql"
"sql|Close the two defects that would be exported|sql/p13_serve_harden.sql"
"sql|The outbound share|sql/p13_share.sql"
"gate|CI repository secrets|NO ACCESS TOKEN IS NEEDED HERE. An earlier version of this gate asked for a
  fine-grained PAT and said sql/p14_git.sql would create the secret that holds it
  and print where to paste it. It does neither. The probe in that file reaches
  GitHub over the PUBLIC repository URL with no credential at all, deliberately,
  so that a refusal reads as the feature being gated rather than as a token
  problem.

  AN EARLIER VERSION OF THIS GATE SAID TO EXPECT VERDICT = GATED on the api
  integration for git row, reasoning from section 1 Finding 3 that external
  access integrations are refused here. THAT PREDICTION WAS WRONG and the run
  disproved it: api integration, git repository stage, git fetch and a 59-file
  listing all came back OK, and step 54 then created GIT_API_QCOMMERCE, fetched,
  and deployed a view from the repository. README section 11 and the step 22
  tier note both already said a git integration IS permitted -- different
  integration type, different gate -- and this gate was the only thing claiming
  otherwise. A limitation asserted rather than measured is exactly what the tier
  kind exists to stop, so it is recorded here rather than quietly deleted.

  ON A REBUILD THIS GATE IS OPTIONAL, like gates 18 and 20. What it actually sets
  is three repository secrets, read only by .github/workflows/ci.yml and by
  nothing in this build:
      github.com/vikassingh0593/snowflake_usecase/settings/secrets/actions
      SNOWFLAKE_ACCOUNT   SNOWFLAKE_USER   SNOWFLAKE_PRIVATE_KEY
  SNOWFLAKE_PRIVATE_KEY is the CI key pair created in step 4 -- the PRIVATE half,
  rsa_ci.p8, pasted whole, header and footer lines included. The warehouse job
  skips itself when SNOWFLAKE_ACCOUNT is absent, so CI stays green without any of
  them and the rebuild does not depend on this step."
"sql|Git integration and repository|sql/p14_git.sql"
"sql|Deploy from git|sql/p14_deploy.sql"
"gate|Account budget|Snowsight -> Admin -> Cost Management -> Budgets -> Account Budget
  -> Activate. Limit 80 credits, add your email. This account has no SHOW BUDGETS
  and no ACCOUNT_USAGE.BUDGETS; the budget is reachable only by CALL against
  SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET and only after it has been activated here.
  It is the only control that sees serverless spend -- RM_POC sees virtual
  warehouse credits and nothing else."
"sql|What the whole thing cost|sql/p15_cost.sql"
)

# Everything in sql/ that the manifest deliberately leaves out.
NOT_IN_BUILD="Twenty-one of the 58 files in sql/ are not build steps:
  probes        p6_pkg_probe  p9_ml_probe  p11_streamlit_probe  p12_probe
                p13_probe  p13_probe2  p13_probe3
  diagnostics   p12_budget_probe  p12_cost_reconcile  p12_cost_ai_trace
                p12_ai_recheck  p12_monitor_gap  p12_monitor_gap2
                p13_launder_diag  p13_launder_diag2
  reprints      p9_report  p12_serve_repair_verify
  one-time      p9_registry_fix  p11_fix_object_type
  deferred      p3_credits_backfill -- wants ~3h of ACCOUNT_USAGE latency first
  teardown      teardown.sql

Four of the sixteen scripts in scripts/ are not build steps either:
  tools         sql.sh -- run one file, print only its result tables
                sqllint.sh -- the checks CI runs over this repo
  diagnostic    p3_props.sh -- dump the config a connector plugin accepts
  demo surface  p13_sqlapi.sh -- Part 13's HTTP surface. Nothing reads its output
lib.sh is sourced, and dbt.sh and rebuild.sh are the runners. Every other script
is a build step. p10_truth.sh was neither listed here nor in the manifest, which
is how it went missing until step 38 asked for the table it creates.

Each records what the account did when asked a question. The build path does not
re-enact them, and a probe run against an account that already has the feature
it was probing for tells you nothing you did not already know."

# -----------------------------------------------------------------------------
usage() {
    cat <<'EOF'
usage: scripts/rebuild.sh <command> [options]

  status              what exists in the account right now  (free)
  plan                the build order, numbered              (free)
  teardown            remove every object, behind a confirm gate
  build [options]     walk the plan
      --from N        resume at step N
      --to N          stop after step N
      --dry-run       print each command instead of running it

  FORCE=1             skip the confirm gate (for CI only)
  SNOW_CONN=name      connection to use          (default: qcpoc)
EOF
}

cmd_plan() {
    step "build order — ${#MANIFEST[@]} steps"
    local i=0 kind label payload
    for entry in "${MANIFEST[@]}"; do
        i=$((i + 1))
        # -d '' so read consumes the newlines inside a gate payload rather than
        # stopping at the first one. It returns 1 at EOF, which is expected.
        IFS='|' read -r -d '' kind label payload <<<"$entry" || true
        payload="${payload%$'\n'}"
        if [ "$kind" = gate ]; then
            printf '  %2d  %sGATE%s  %s\n' "$i" "$_Y" "$_0" "$label"
            continue
        fi
        local shown="${payload%% :: *}"
        [ "$kind" = dbt ] && shown="scripts/dbt.sh $payload"
        [ "$kind" = tier ] && shown="$shown   (expected to be refused)"
        printf '  %2d  %-5s %s\n          %s%s%s\n' \
               "$i" "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')" \
               "$label" "$_D" "$shown" "$_0"
    done
    step "not in the build path"
    printf '%s\n' "$NOT_IN_BUILD" | sed 's/^/    /'
}

cmd_status() {
    need_cmd snow
    step "account state — SHOW only, no warehouse resumes, no credits"

    # name, SHOW, and a predicate that drops objects this project did not create.
    # SHOW INTEGRATIONS always returns SNOWFLAKE$LOCAL_APPLICATION, and reporting
    # a vendor default as project residue would make a clean account look dirty.
    local rows=(
      "database|SHOW DATABASES LIKE 'QC%'|"
      "warehouse|SHOW WAREHOUSES LIKE 'WH_%'|"
      "role|SHOW ROLES LIKE 'QC_%'|"
      "user|SHOW USERS LIKE 'SVC_%'|"
      "resource monitor|SHOW RESOURCE MONITORS|\"name\" LIKE 'RM_%'"
      "share|SHOW SHARES LIKE '%QC%'|"
      "external volume|SHOW EXTERNAL VOLUMES|"
      "integration|SHOW INTEGRATIONS|\"name\" NOT LIKE 'SNOWFLAKE\$%'"
    )
    local label show where clean=1
    for row in "${rows[@]}"; do
        IFS='|' read -r label show where <<<"$row"
        local found; found="$(snow_names "$show" "$where")"
        [ "$found" = "-" ] || clean=0
        printf '    %-17s %s\n' "$label" "$found"
    done

    if [ "$clean" = 1 ]; then
        ok "nothing left — teardown was complete"
    else
        note "a dash means gone; anything else is still there"
    fi

    # Not this project's object, and by a wide margin the most expensive thing in
    # the account: 3.1433 credits over seven days, 51.4% of every warehouse
    # credit spent, against 2.9695 for all three WH_* warehouses together. It is
    # the trial account's default, so any Snowsight worksheet that does not name
    # a warehouse resumes it, and RM_POC is level = WAREHOUSE and never saw it.
    # That gap is exactly the one Part 12 went looking for: RM_POC read 3.02.
    step "the warehouse this project did not create"
    printf '    %-17s %s\n' "vendor default" "$(snow_names "SHOW WAREHOUSES LIKE 'SNOWFLAKE_%'")"
    note "sql/teardown.sql sets its AUTO_SUSPEND to 60; it does not drop it"
}

cmd_teardown() {
    need_cmd snow
    need_file sql/teardown.sql
    step "teardown"
    say "sql/teardown.sql drops, account-wide and in dependency order:"
    say "  the share and any probe listings and application packages"
    say "  the Iceberg table, then QCOMMERCE and QC_PROBE_TMP"
    say "  five integrations, two probe leftovers, the external volume EXVOL_QC"
    say "  WH_INGEST_XS, WH_TRANSFORM_XS, WH_APP_XS"
    say "  SVC_KAFKA, SVC_CI and the four QC_ roles"
    say "  RM_POC and RM_ACCOUNT, after ALTER ACCOUNT UNSET RESOURCE_MONITOR"
    warn "this is not recoverable except by rebuilding"
    confirm "About to run sql/teardown.sql against connection '$CONN'."
    snow_file sql/teardown.sql
    ok "teardown run — every REMAINING above should read 0 except the last"
}

cmd_build() {
    local from=1 to="${#MANIFEST[@]}" dry=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) from="${2:?--from needs a step number}"; shift 2 ;;
            --to)   to="${2:?--to needs a step number}";     shift 2 ;;
            --dry-run) dry=1; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    [ "$dry" = 1 ] || need_cmd snow

    step "build — steps $from to $to of ${#MANIFEST[@]}"
    note "estimated cost of a full run: UNVERIFIED, 1.5-3 credits"
    note "most of it is four steps: dbt build, p7_core_conform, p7_core_scd2, p10_vectors"
    note "every warehouse is XSMALL with AUTO_SUSPEND = 60 and is never resized"

    local i=0 kind label payload
    for entry in "${MANIFEST[@]}"; do
        i=$((i + 1))
        [ "$i" -ge "$from" ] || continue
        [ "$i" -le "$to" ] || break
        # -d '' so read consumes the newlines inside a gate payload rather than
        # stopping at the first one. It returns 1 at EOF, which is expected.
        IFS='|' read -r -d '' kind label payload <<<"$entry" || true
        payload="${payload%$'\n'}"

        if [ "$kind" = gate ]; then
            printf '\n%s  %2d  GATE  %s%s\n' "$_Y" "$i" "$label" "$_0"
            printf '%s\n' "$payload" | sed 's/^/      /'
            printf '\n      resume with: %sscripts/rebuild.sh build --from %d%s\n' \
                   "$_B" "$((i + 1))" "$_0"
            return 0
        fi

        step "$i/${#MANIFEST[@]}  $label"
        if [ "$dry" = 1 ]; then
            case "$kind" in
                sql)   note "snow sql -c $CONN -f $payload" ;;
                dbt)   note "scripts/dbt.sh $payload" ;;
                shell) note "$payload" ;;
            esac
            continue
        fi

        # A tier step is one this account is known to refuse. Its payload carries
        # the reason after " :: " so the refusal reads as a recorded limitation
        # rather than a build failure. If it ever succeeds, say so -- that means
        # the account changed and README section 11 is out of date.
        if [ "$kind" = tier ]; then
            if snow_file "${payload%% :: *}"; then
                ok "$label"
                warn "this step was expected to be refused on this account and was not"
                note "README section 11 needs updating"
            else
                warn "$label — refused, and expected to be"
                note "${payload#* :: }"
            fi
            continue
        fi

        case "$kind" in
            sql)   snow_file "$payload" ;;
            dbt)   bash scripts/dbt.sh $payload ;;
            shell) bash -c "$payload" ;;
        esac || {
            warn "step $i failed: $label"
            note "fix it, then: scripts/rebuild.sh build --from $i"
            exit 1
        }
        ok "$label"
    done

    step "reached step $to"
    [ "$to" -lt "${#MANIFEST[@]}" ] \
        && note "continue with: scripts/rebuild.sh build --from $((to + 1))" \
        || ok "build complete — scripts/rebuild.sh status to confirm"
}

case "${1:-}" in
    status)   cmd_status ;;
    plan)     cmd_plan ;;
    teardown) cmd_teardown ;;
    build)    shift; cmd_build "$@" ;;
    *)        usage; exit 1 ;;
esac

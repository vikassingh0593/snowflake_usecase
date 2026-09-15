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
"gate|Azure tenant-admin consent and RBAC|THE LONGEST STEP IN THE PROJECT, AND THE ONE THAT WASTES TIME.
  Three objects were just created and each one minted its OWN service principal:
  a rebuild does not inherit the consent or the role assignments the previous
  build had. All three have to be done again, separately.

      DESC EXTERNAL VOLUME EXVOL_QC;      -- expand STORAGE_LOCATIONS for its URL
      DESC INTEGRATION SI_QC_AZURE;
      DESC INTEGRATION NI_QC_SNOWPIPE;

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

  scripts/p2_rbac.sh automates step 4 ONLY IF ITS APP NAMES ARE UPDATED FIRST.
  It has the previous build's two app prefixes hardcoded at the top, and new
  principals get new names, so as it stands it will silently find nothing. Read
  AZURE_MULTI_TENANT_APP_NAME from the three DESC outputs, put the prefixes in
  APP_BLOB and APP_QUEUE, then run it in Cloud Shell. Portal clicking is fine
  too; the script only exists because container-scoped grants are fiddly.

  RBAC PROPAGATION TAKES ABOUT FIVE MINUTES. Verification failing straight after
  a grant means wait, not debug. This is the single most common way to lose half
  an hour on this project.

  THE GATE, and do not go past a failure here -- every Iceberg step depends on it:
      SELECT SYSTEM\$VERIFY_EXTERNAL_VOLUME('EXVOL_QC');"
"sql|Stages, file formats, RAW tables|sql/p3_prep.sql"
"gate|Operational source and broker|On the machine with Docker:
      cd source && docker compose up -d
  Postgres 16 as the OLTP source, Kafka (Redpanda), Kafka Connect, Debezium.
      python3 source/generate.py
  Writes the generator output every later step reads."
"shell|Kafka connector plugin|scripts/p3_connector.sh"
"shell|Sink connector, mechanisms 1 and 3|scripts/p3_sink.sh"
"shell|Snowpipe Streaming SDK, mechanism 2|scripts/run_in_container.sh stream"
"sql|Mechanisms 1 vs 2 vs 3 on identical input|sql/p3_benchmark.sql"
"gate|Clickstream upload|In Azure Cloud Shell:
      bash scripts/upload_source.sh clickstream
  One blob at a time, so Event Grid raises one notification per file and
  COPY_HISTORY shows N loads instead of one opaque one."
"sql|Snowpipe auto-ingest, mechanism 4|sql/p4_snowpipe_auto.sql"
"sql|Snowpipe REST, mechanism 5|sql/p4_snowpipe_rest.sql"
"shell|REST ingest driver|python3 scripts/p4_rest_ingest.py"
"sql|COPY and VALIDATE, mechanisms 6 and 7|sql/p4_copy_parquet.sql"
"gate|Settlement upload|In Azure Cloud Shell:
      bash scripts/upload_source.sh settlement"
"sql|External table and Iceberg, mechanisms 8 and 9|sql/p5_external_iceberg.sql"
"gate|Complaint PDF upload|In Azure Cloud Shell:
      bash scripts/upload_source.sh complaints
  _truth.csv stays behind. It is the answer key for Part 10 and a label sitting
  in RAW next to the text it labels is how a model scores 100% on nothing."
"sql|Directory table over the PDFs, mechanism 10|sql/p6_directory_docs.sql"
"sql|External network access, mechanism 11|sql/p6_external_access.sql"
"gate|Marketplace listing|Snowsight -> Data Products -> Marketplace. Acquire the free
  listing named in sql/p6_marketplace.sql and mount it as QC_MARKETPLACE. There
  is no SQL that accepts a listing's terms on your behalf."
"sql|Marketplace join, mechanism 12|sql/p6_marketplace.sql"
"shell|write_pandas, mechanism 13|scripts/run_in_container.sh pandas"
"gate|CDC|Debezium has to be pointed at a source that has moved:
      bash scripts/p7_source_reset.sh
      bash scripts/p7_cdc_sink.sh
      bash scripts/p7_mutate_source.sh
  Seven topics, one connector, deletes included."
"sql|What landed from the seven CDC topics|sql/p7_cdc_verify.sql"
"sql|RAW to CORE, conformance and dedupe|sql/p7_core_conform.sql"
"sql|Streams and SCD2|sql/p7_core_scd2.sql"
"sql|MATCH_RECOGNIZE over the status stream|sql/p7_core_funnel.sql"
"dbt|The dimensional model, 9 models and 42 tests|build"
"sql|Let QC_ENGINEER read what ACCOUNTADMIN built|sql/p8_grants.sql"
"sql|The feature table|sql/p9_features.sql"
"sql|Train, evaluate, register|sql/p9_train.sql"
"sql|Score with the registered model|sql/p9_score.sql"
"sql|Complaint text preparation|sql/p10_text_prep.sql"
"sql|Classify complaints to reason codes|sql/p10_classify.sql"
"sql|Score the classifier against the answer key|sql/p10_eval.sql"
"sql|Vectors, similarity, a second classifier|sql/p10_vectors.sql"
"sql|The two approaches on the same 240|sql/p10_eval_compare.sql"
"sql|SERVE, the contract the app reads|sql/p11_serve.sql"
"shell|Deploy the console|scripts/p11_deploy.sh"
"sql|Column and row protection|sql/p12_policies.sql"
"sql|Act on what the classifier found|sql/p12_classify_response.sql"
"sql|Quality rules and lineage|sql/p12_quality_lineage.sql"
"sql|Search optimization and the materialized view|sql/p12_serverless.sql"
"sql|An alert that fires on a real failure|sql/p12_alert.sql"
"sql|Repair: governance broke the performance layer|sql/p12_serve_repair.sql"
"sql|Close the two defects that would be exported|sql/p13_serve_harden.sql"
"sql|The outbound share|sql/p13_share.sql"
"gate|GitHub access token|The git integration authenticates with a fine-grained PAT,
  Contents: read-only, on this repository alone. Create it at
  github.com/settings/personal-access-tokens and have it ready -- p14_git.sql
  creates the secret that holds it and prints where to paste it.
  Also set the repository secrets the CI workflow reads: SNOWFLAKE_ACCOUNT,
  SNOWFLAKE_USER, SNOWFLAKE_PRIVATE_KEY. The warehouse job skips itself when
  SNOWFLAKE_ACCOUNT is absent, so CI stays green without them."
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
        local shown="$payload"
        [ "$kind" = dbt ] && shown="scripts/dbt.sh $payload"
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

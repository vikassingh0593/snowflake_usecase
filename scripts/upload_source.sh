#!/usr/bin/env bash
# =============================================================================
# scripts/upload_source.sh — generate a source dataset and upload it to Azure.
#
# Replaces p4_clickstream.sh, p5_settlement.sh and p6_complaints.sh. They were
# the same script three times: run a generator, loop over the output, push it at
# a container, list what landed. The three real differences are data, not code,
# and they are in the table below rather than scattered across three files.
#
#   target        generator             container  prefix        upload
#   ----------------------------------------------------------------------
#   clickstream   gen_clickstream.py    landing    clickstream/  one at a time
#   settlement    gen_settlement.py     external   settlement/   one at a time
#   complaints    gen_complaints.py     docs       complaints/   batch
#
# WHY clickstream AND settlement UPLOAD ONE FILE AT A TIME. Each blob creation
# raises a separate Event Grid notification onto snowpipe-queue. Snowpipe then
# sees N distinct files arriving rather than one batch, and the auto-ingest
# behaviour shows up in COPY_HISTORY as N loads instead of one opaque one. docs/
# has no Event Grid subscription, so nothing is watching for individual blob
# events there and 300 round trips would buy nothing.
#
# RUN IN AZURE CLOUD SHELL. It has python3 and az, every generator is standard
# library only, and nothing needs installing on either machine.
#
# PREREQUISITE, once per storage account. Owning the subscription lets you
# CREATE the storage account but grants no blob data access -- control plane and
# data plane are separate in Azure, which is the same distinction that made
# SYSTEM$VERIFY_EXTERNAL_VOLUME fail on the delegation key. Without it,
# --auth-mode login returns "You do not have the required permissions":
#
#   ME=$(az ad signed-in-user show --query id -o tsv)
#   az role assignment create --assignee-object-id "$ME" \
#     --assignee-principal-type User --role "Storage Blob Data Contributor" \
#     --scope "/subscriptions/<sub>/resourceGroups/rg-qcpoc/providers/Microsoft.Storage/storageAccounts/<sa>"
#
# Deliberately not --auth-mode key. The account key is unscoped, never expires
# and would sit in shell history; a scoped grant on your own identity costs one
# command. Note the asymmetry: Snowflake's principal has READER on all three
# containers because it only ever reads them, while the producer needs
# CONTRIBUTOR. Snowflake can never write to a landing zone, which is the correct
# least privilege and the reason generation happens here and not in an account.
#
#   bash scripts/upload_source.sh clickstream          24 files, ~50k events
#   HOURS=4 TARGET=8000 bash scripts/upload_source.sh clickstream    quick test
#   bash scripts/upload_source.sh settlement           7 daily 3PL files
#   bash scripts/upload_source.sh complaints           300 PDFs
#   N=50 bash scripts/upload_source.sh complaints      fewer
#   UPLOAD=0 bash scripts/upload_source.sh complaints  generate only, inspect
#
# Cost: hot blob storage in the low hundreds of kilobytes. Rounds to nothing.
# =============================================================================
. "$(dirname "$0")/lib.sh"

SA="${SA:-snowflakeqcpoc25056}"
UPLOAD="${UPLOAD:-1}"

TARGET_NAME="${1:-}"

case "$TARGET_NAME" in
  clickstream)
    GEN=(source/gen_clickstream.py --hours "${HOURS:-24}" --target "${TARGET:-50000}")
    DIR=source/out/clickstream ; CONTAINER=landing  ; PREFIX=clickstream
    PATTERN='*.ndjson.gz'      ; MODE=each
    NEXT="The pipe polls the Event Grid queue. Give it a minute, then:
       SELECT SYSTEM\$PIPE_STATUS('QCOMMERCE.LAND.PIPE_CLICKSTREAM_AUTO');
       SELECT COUNT(*) FROM QCOMMERCE.RAW.CLICKSTREAM_AUTO;"
    ;;
  settlement)
    GEN=(source/gen_settlement.py --days "${DAYS:-7}")
    DIR=source/out/settlement  ; CONTAINER=external ; PREFIX=settlement
    PATTERN='*.csv'            ; MODE=each
    NEXT='snow sql -c qcpoc -f sql/p5_external_iceberg.sql'
    ;;
  complaints)
    GEN=(source/gen_complaints.py --n "${N:-300}")
    DIR=source/out/complaints  ; CONTAINER=docs     ; PREFIX=complaints
    PATTERN='CMP-*.pdf'        ; MODE=batch
    NEXT='snow sql -c qcpoc -f sql/p6_directory_docs.sql

     The directory table does not notice new blobs by itself. ALTER STAGE
     REFRESH is what reconciles it, and that is what the stream sees.'
    ;;
  *)
    die "usage: scripts/upload_source.sh {clickstream|settlement|complaints}"
    ;;
esac

need_cmd python3
step "generating $TARGET_NAME"
python3 "${GEN[@]}"

# The complaints answer key must not reach the platform. A label sitting in RAW
# next to the text it labels is how a model ends up scoring 100% on nothing --
# the pattern is only excluded because CMP-*.pdf does not match _truth.csv, so
# this is a statement of intent, not the mechanism.
if [ "$TARGET_NAME" = complaints ]; then
    note "withheld from upload: $DIR/_truth.csv  (answer key for Part 10)"
fi

[ "$UPLOAD" = "1" ] || { note "UPLOAD=0, stopping after generate"; exit 0; }

need_cmd az
step "uploading to $SA/$CONTAINER/$PREFIX/"

if [ "$MODE" = each ]; then
    shopt -s nullglob
    files=("$DIR"/$PATTERN)
    shopt -u nullglob
    [ "${#files[@]}" -gt 0 ] || die "$DIR/$PATTERN matched nothing -- did the generator run?"
    for f in "${files[@]}"; do
        az storage blob upload \
            --account-name "$SA" --auth-mode login \
            --container-name "$CONTAINER" \
            --name "$PREFIX/$(basename "$f")" \
            --file "$f" --overwrite -o none
        say "uploaded $(basename "$f")"
    done
else
    az storage blob upload-batch \
        --account-name "$SA" --auth-mode login \
        --destination "$CONTAINER" --destination-path "$PREFIX" \
        --source "$DIR" --pattern "$PATTERN" \
        --overwrite -o none
fi

step "blobs now in $CONTAINER/$PREFIX/"
az storage blob list --account-name "$SA" --auth-mode login \
    --container-name "$CONTAINER" --prefix "$PREFIX/" \
    --query "length(@)" -o tsv | xargs printf "    %s blobs\n"
az storage blob list --account-name "$SA" --auth-mode login \
    --container-name "$CONTAINER" --prefix "$PREFIX/" \
    --query "[:5].{name:name, size:properties.contentLength}" -o table

step "next, in Snowflake"
say "$NEXT"

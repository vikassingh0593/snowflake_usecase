#!/usr/bin/env bash
# =============================================================================
# scripts/p6_complaints.sh — mechanism 10: complaint PDFs into docs/
#
# RUN IN AZURE CLOUD SHELL, same as p4_clickstream.sh. python3 and az are both
# there, the generator is standard library only, and your Mac's Python stays
# out of it.
#
# Same prerequisite as p4: Storage Blob Data Contributor on YOUR identity at
# the storage account. Owning the subscription is control plane and grants no
# blob access. If --auth-mode login says "You do not have the required
# permissions", that grant is what is missing -- see the note at the top of
# scripts/p4_clickstream.sh for the exact command.
#
# Snowflake's principal has READER on docs/, so it can never write here. The
# producer needs CONTRIBUTOR. That asymmetry is the point.
#
#   bash scripts/p6_complaints.sh              300 PDFs, generate + upload
#   N=50 bash scripts/p6_complaints.sh         fewer
#   UPLOAD=0 bash scripts/p6_complaints.sh     generate only, inspect first
#
# Cost: ~320 KB of hot blob. Rounds to nothing.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SA="${SA:-snowflakeqcpoc25056}"
N="${N:-300}"
UPLOAD="${UPLOAD:-1}"
DIR="source/out/complaints"

echo "== generating"
python3 source/gen_complaints.py --n "$N"

# _truth.csv is the answer key for scoring the classifier in Part 10. It must
# not reach the platform -- a label sitting in RAW next to the text it labels
# is how a model ends up scoring 100% on nothing.
echo
echo "== withheld from upload: $DIR/_truth.csv  (answer key)"

[ "$UPLOAD" = "1" ] || { echo "UPLOAD=0, stopping after generate"; exit 0; }

echo
echo "== uploading to $SA/docs/complaints/"
# upload-batch, not a loop. docs/ has no Event Grid subscription -- only
# landing/ does -- so nothing is watching for individual blob events here and
# there is no reason to make 300 round trips.
az storage blob upload-batch \
  --account-name "$SA" --auth-mode login \
  --destination docs --destination-path complaints \
  --source "$DIR" --pattern "CMP-*.pdf" \
  --overwrite -o none

echo
echo "== blobs now in docs/complaints/"
az storage blob list --account-name "$SA" --auth-mode login \
  --container-name docs --prefix complaints/ \
  --query "length(@)" -o tsv | xargs printf "  %s blobs\n"
az storage blob list --account-name "$SA" --auth-mode login \
  --container-name docs --prefix complaints/ \
  --query "[:3].{name:name, size:properties.contentLength}" -o table

cat <<'EOF'

== Next, in Snowflake
   snow sql -c qcpoc -f sql/p6_directory_docs.sql

   The directory table does not notice new blobs by itself. ALTER STAGE
   REFRESH is what reconciles it, and that is what the stream sees.
EOF

#!/usr/bin/env bash
#
# Part 13, fourth surface: the SQL API.
#
# POST /api/v2/statements with a key-pair JWT. There is no SQL that can test
# this -- it is an HTTP call, which is the point: the SQL API is how something
# that is not a Snowflake client reaches the platform.
#
# SVC_CI is the caller. Part 1 gave it TYPE = SERVICE and a key pair, and
# p13_probe.sql confirmed both are still true: type=SERVICE keypair=true. A
# service user cannot log in interactively, so a leaked JWT is the only
# exposure, and a JWT expires in an hour.
#
# WHAT THE JWT HAS TO CONTAIN, because getting this wrong is the usual reason
# the endpoint returns 401 with nothing useful:
#
#   iss   <ACCOUNT>.<USER>.SHA256:<base64 fingerprint of the PUBLIC key>
#   sub   <ACCOUNT>.<USER>
#   iat   now
#   exp   now + 3600 at most
#
# ACCOUNT is the locator in upper case with no region suffix. The fingerprint is
# of the public key derived from the private one, so this script computes it
# rather than asking anyone to paste it -- the Part 12 lesson about invented
# values applies to configuration too.
#
#   scripts/p13_sqlapi.sh                    dry run: build and print the JWT claim set
#   RUN=1 scripts/p13_sqlapi.sh              actually POST
#   RUN=1 SQL="SELECT 1" scripts/p13_sqlapi.sh
#
# Dry-run by default, the same convention as p2_azure.sh and p10_truth.sh.
set -euo pipefail

ACCOUNT="${SNOW_ACCOUNT:-OOB49311}"
USER_NAME="${SNOW_USER:-SVC_CI}"
KEY="${SNOW_KEY:-$HOME/.snowflake/keys/svc_ci_rsa_key.p8}"
ROLE="${SNOW_ROLE:-QC_ANALYST}"
WAREHOUSE="${SNOW_WAREHOUSE:-WH_APP_XS}"
DATABASE="${SNOW_DATABASE:-QCOMMERCE}"
SCHEMA_NAME="${SNOW_SCHEMA:-SERVE}"
SQL="${SQL:-SELECT COUNT(*) AS N FROM SERVE.SLA_BY_STORE_HOUR}"
RUN="${RUN:-0}"

if [ ! -f "$KEY" ]; then
    echo "no private key at $KEY" >&2
    echo "set SNOW_KEY, or point it at the key created for SVC_CI in Part 1." >&2
    exit 1
fi

# The venv that runs dbt and the connector already carries cryptography; this
# uses nothing beyond it and the standard library. No new dependency.
JWT=$(python3 - "$KEY" "$ACCOUNT" "$USER_NAME" <<'PY'
import base64, hashlib, json, sys, time
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

key_path, account, user = sys.argv[1], sys.argv[2].upper(), sys.argv[3].upper()

with open(key_path, "rb") as fh:
    private_key = serialization.load_pem_private_key(fh.read(), password=None)

# The fingerprint Snowflake stores is SHA256 over the DER-encoded PUBLIC key,
# base64 of the raw digest -- not hex, and not over the private key.
public_der = private_key.public_key().public_bytes(
    encoding=serialization.Encoding.DER,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
)
fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(public_der).digest()).decode()

now = int(time.time())
payload = {
    "iss": "{}.{}.{}".format(account, user, fingerprint),
    "sub": "{}.{}".format(account, user),
    "iat": now,
    "exp": now + 3600,
}

def seg(obj):
    raw = json.dumps(obj, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

signing_input = (seg({"alg": "RS256", "typ": "JWT"}) + "." + seg(payload)).encode()
signature = private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
token = signing_input.decode() + "." + base64.urlsafe_b64encode(signature).rstrip(b"=").decode()

print(json.dumps({"token": token, "claims": payload}))
PY
)

CLAIMS=$(echo "$JWT" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["claims"], indent=2))')
TOKEN=$(echo "$JWT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

echo "endpoint  https://${ACCOUNT}.snowflakecomputing.com/api/v2/statements"
echo "claims"
echo "$CLAIMS"
echo
echo "statement $SQL"
echo "as        role=$ROLE warehouse=$WAREHOUSE"
echo

if [ "$RUN" != "1" ]; then
    echo "dry run. RUN=1 to POST."
    exit 0
fi

BODY=$(python3 -c '
import json, sys
print(json.dumps({
    "statement": sys.argv[1],
    "timeout": 60,
    "role": sys.argv[2],
    "warehouse": sys.argv[3],
    "database": sys.argv[4],
    "schema": sys.argv[5],
}))' "$SQL" "$ROLE" "$WAREHOUSE" "$DATABASE" "$SCHEMA_NAME")

curl -sS -i -X POST \
  "https://${ACCOUNT}.snowflakecomputing.com/api/v2/statements" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Snowflake-Authorization-Token-Type: KEYPAIR_JWT" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "$BODY"
echo

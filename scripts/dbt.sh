#!/usr/bin/env bash
# =============================================================================
# scripts/dbt.sh — run dbt against a pinned local image.
#
# dbt is not installed on this machine and does not need to be. It lives in a
# tagged image built once from dbt/Dockerfile, and every invocation is a
# throwaway container with the repo mounted.
#
# WHY AN IMAGE RATHER THAN A NATIVE INSTALL
#
#   Part 14 runs `dbt build` in a Linux container on GitHub Actions. An image
#   pinned to dbt-core 1.12.4 and dbt-snowflake 1.12.0 means local and CI are
#   the same dbt against the same adapter, so a model that passes here passes
#   there for the same reasons. A macOS install would diverge from CI on exactly
#   the axis that matters, and would also risk disturbing the Intel pyenv Python
#   the `snow` CLI runs on.
#
#   This replaces the earlier approach of pip-installing dbt on every run, which
#   cost roughly ninety seconds each time. Fine for the four seeds of mechanism
#   14; unworkable once MART makes dbt a write-run-read-fix loop.
#
# AUTH: key-pair as SVC_CI, read from rsa_ci.p8 in the repo root. No password
# exists anywhere. See dbt/profiles.yml -- it is committed because it contains
# an account, a user, a role and the PATH to a key, and no secret.
#
#   bash scripts/dbt.sh build             seeds, models and every test
#   bash scripts/dbt.sh deps              install dbt_utils
#   bash scripts/dbt.sh debug             connection check, loads nothing
#   bash scripts/dbt.sh run --select fct_order
#   bash scripts/dbt.sh test --select tag:mart
#   REBUILD=1 bash scripts/dbt.sh ...     force the image to rebuild
#
# COST: resumes WH_TRANSFORM_XS. Depends entirely on what is selected -- the
# four seeds are under 0.01 credits, a full MART build over 270,000 CORE rows
# is more. Use --select while iterating.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="qc-dbt:1.12.4"

[ -f rsa_ci.p8 ] || {
  echo "rsa_ci.p8 not found in repo root."
  echo "SVC_CI authenticates by key pair and has no password. To create one:"
  echo "  openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_ci.p8 -nocrypt"
  echo "  openssl rsa -in rsa_ci.p8 -pubout -out rsa_ci.pub"
  echo "  chmod 600 rsa_ci.p8"
  echo "  KEY=\$(grep -v '^-----' rsa_ci.pub | tr -d '\\n')"
  echo "  snow sql -c qcpoc -q \"ALTER USER SVC_CI SET RSA_PUBLIC_KEY = '\$KEY'\""
  exit 1
}

if [ "${REBUILD:-0}" = "1" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== building $IMAGE (once)"
  docker build -q -t "$IMAGE" dbt/
fi

# dbt_packages/ is not committed -- package-lock.yml is, which pins the version
# without carrying 229 files of someone else's code. Resolve on first use. Every
# model in MART calls dbt_utils.generate_surrogate_key, so without this a fresh
# clone fails on the first model with "'dbt_utils' is undefined", which names
# the symptom and not the cause.
if [ ! -d dbt/dbt_packages ] && [ "${1:-}" != "deps" ]; then
  echo "== dbt_packages/ absent, resolving from package-lock.yml (once)"
  docker run --rm -v "$PWD":/work "$IMAGE" deps --profiles-dir . --target dev
fi

# --profiles-dir . because profiles.yml lives beside dbt_project.yml rather than
# in ~/.dbt. Keeping it in the repo is what makes the image stateless: nothing
# about the connection lives in the container or in a home directory.
docker run --rm -it \
  -v "$PWD":/work \
  -e DBT_KEY_PATH=/work/rsa_ci.p8 \
  -e DBT_QUERY_TAG="${DBT_QUERY_TAG:-p08:dbt}" \
  "$IMAGE" "$@" --profiles-dir . --target dev

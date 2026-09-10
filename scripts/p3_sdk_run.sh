#!/usr/bin/env bash
# =============================================================================
# scripts/p3_sdk_run.sh — run mechanism 2 in a container.
#
# The Snowpipe Streaming SDK ships no macOS x86_64 wheel. This Mac is arm64 but
# its Python is an Intel build under Rosetta, and pyenv cannot compile a native
# one because the Intel Homebrew's gettext leaks into the link step.
#
# Docker sidesteps all of it: an arm64 Mac runs arm64 Linux containers natively,
# and the SDK does ship manylinux aarch64. The repo is mounted read-write so the
# script reads out/order_status.ndjson and rsa_kafka.p8 exactly as it would
# locally.
#
# This is a workaround for mechanism 2, not a fix. Part 9 needs Snowpark and
# snowflake-ml-python locally, so a native Python is still worth installing --
# the python.org universal2 build, since pyenv cannot compile one here.
#
#   bash scripts/p3_sdk_run.sh              load, resuming from committed offset
#   bash scripts/p3_sdk_run.sh --status     channel state only
#   bash scripts/p3_sdk_run.sh --restart    drop the channel and reload
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f rsa_kafka.p8 ] || { echo "rsa_kafka.p8 not found in repo root"; exit 1; }
[ -f source/out/order_status.ndjson ] || { echo "run source/generate.py first"; exit 1; }

docker run --rm -it \
  -v "$PWD":/work -w /work \
  python:3.12-slim \
  bash -c "pip install -q --disable-pip-version-check snowpipe-streaming \
           && python source/sdk_stream.py $*"

#!/usr/bin/env bash
# =============================================================================
# scripts/p6_pandas_run.sh — run mechanism 13 in a container.
#
# Same reasoning as scripts/p3_sdk_run.sh. This Mac's Python is an Intel build
# under Rosetta; snowflake-connector-python[pandas] pulls pyarrow and pandas,
# and cryptography 50.x ships arm64-only macOS wheels, so pip would try to
# build all three from source against an Intel Homebrew. An arm64 Linux
# container has manylinux aarch64 wheels for every one of them.
#
# This is still a workaround, not a fix. Part 9 needs Snowpark and
# snowflake-ml-python on the Mac itself -- install the python.org universal2
# build before starting it.
#
#   bash scripts/p6_pandas_run.sh              build the frame and load it
#   bash scripts/p6_pandas_run.sh --dry-run    build and print, connect to nothing
#
# COST: resumes WH_INGEST_XS for a few seconds to create and fill an 8-row
# table. Under 0.01 credits.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f rsa_kafka.p8 ] || { echo "rsa_kafka.p8 not found in repo root"; exit 1; }
[ -f source/out/dark_stores.csv ] || { echo "run source/generate.py first"; exit 1; }

docker run --rm -it \
  -v "$PWD":/work -w /work \
  python:3.12-slim \
  bash -c "pip install -q --disable-pip-version-check 'snowflake-connector-python[pandas]' \
           && python scripts/p6_write_pandas.py $*"

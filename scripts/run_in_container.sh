#!/usr/bin/env bash
# =============================================================================
# scripts/run_in_container.sh — run a Python step in an arm64 Linux container.
#
# Replaces p3_sdk_run.sh and p6_pandas_run.sh, which were the same thirty lines
# twice with a different package list and a different precondition.
#
# WHY A CONTAINER AT ALL, since it looks like avoidance. This Mac is arm64 but
# its Python is an Intel build running under Rosetta. The Snowpipe Streaming SDK
# ships no macOS x86_64 wheel; the connector's pandas extra pulls pyarrow and
# cryptography, whose recent versions publish arm64-only macOS wheels. pip
# therefore tries to build all of them from source against an Intel Homebrew and
# fails in three different ways. An arm64 Mac runs arm64 Linux containers
# natively and manylinux aarch64 wheels exist for every one of them.
#
# It is a workaround, not a fix. Part 9 needed Snowpark locally and got it by
# moving training inside the account as a stored procedure instead.
#
#   scripts/run_in_container.sh stream            mechanism 2, the streaming SDK
#   scripts/run_in_container.sh stream --status   channel state only
#   scripts/run_in_container.sh stream --restart  drop the channel and reload
#   scripts/run_in_container.sh pandas            mechanism 13, write_pandas
#   scripts/run_in_container.sh pandas --dry-run  build the frame, connect to nothing
#
# COST: pandas resumes WH_INGEST_XS for a few seconds to create and fill an
# 8-row table. Under 0.01 credits. stream writes through a pipe and costs
# serverless credits that round to nothing.
# =============================================================================
. "$(dirname "$0")/lib.sh"

TARGET="${1:-}"; shift || true

case "$TARGET" in
  stream)
    need_file rsa_kafka.p8 "rsa_kafka.p8 not found in the repo root"
    need_file source/out/order_status.ndjson "run source/generate.py first"
    step "mechanism 2 — Snowpipe Streaming SDK"
    # SS_LOG_LEVEL quiets the Rust core, which logs every channel, token refresh
    # and telemetry flush at INFO and buries the script's own output. Set it to
    # info when diagnosing an ingestion problem.
    in_container "snowpipe-streaming" source/sdk_stream.py "$@"
    ;;
  pandas)
    need_file rsa_kafka.p8 "rsa_kafka.p8 not found in the repo root"
    need_file source/out/dark_stores.csv "run source/generate.py first"
    step "mechanism 13 — write_pandas"
    in_container "'snowflake-connector-python[pandas]'" scripts/p6_write_pandas.py "$@"
    ;;
  *)
    die "usage: scripts/run_in_container.sh {stream|pandas} [args...]"
    ;;
esac

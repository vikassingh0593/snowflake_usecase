#!/usr/bin/env python3
"""Mechanism 2 — Snowpipe Streaming SDK, direct, no Kafka anywhere.

Mechanisms 1 and 3 both put a broker and Kafka Connect between the producer and
Snowflake. This one is the same events going straight from a Python process
into a table, which is what makes it the honest control in the three-way
comparison: whatever latency remains here is Snowflake's, not the broker's.

The point of the exercise is channels and offset tokens:

  * A channel is an ordered, exactly-once stream into one table. Reopening a
    channel by name returns the last committed offset token, so a crashed
    producer knows precisely where to resume without re-reading or duplicating.
  * Run this twice. The second run reopens the same channel, reads the
    committed token, skips what is already there, and appends nothing --
    which is the demonstration, not a no-op.

  python source/sdk_stream.py              load, resuming if the channel exists
  python source/sdk_stream.py --restart    drop the channel and start over
  python source/sdk_stream.py --status     show channel state only

Requires: pip install snowpipe-streaming
NOTE: the SDK ships wheels for macOS arm64, Linux x86_64/aarch64 and Windows.
There is no macOS x86_64 wheel, so an Intel Python under Rosetta cannot install
it at all.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

from snowflake.ingest.streaming import StreamingIngestClient

ACCOUNT = "AWTTGVH-OLB61128"
HOST = "awttgvh-olb61128.snowflakecomputing.com"
USER = "SVC_KAFKA"
ROLE = "QC_LOADER"
DB, SCHEMA, TABLE = "QCOMMERCE", "RAW", "ORDER_STATUS_SDK"
CHANNEL = "qc_order_status_sdk_0"

HERE = os.path.dirname(os.path.abspath(__file__))
KEYFILE = os.environ.get("KEYFILE", os.path.join(HERE, "..", "rsa_kafka.p8"))
NDJSON = os.path.join(HERE, "out", "order_status.ndjson")
BATCH = 5_000


def properties() -> dict:
    """Connection properties for the SDK's Rust core.

    host, scheme and port are explicit. The core logs "No account URL provided.
    Constructing from scheme, host, and port" and then fails on an empty host --
    it does not derive one from the account identifier the way the Python
    connector does. The accepted keys are account, account_url, host, scheme,
    port, user, role, private_key, authorization_type, jwt, oauth and token.
    """
    with open(KEYFILE) as fh:
        key = fh.read()
    return {
        "account": ACCOUNT,
        "host": HOST,
        "scheme": "https",
        "port": 443,
        "user": USER,
        "role": ROLE,
        "private_key": key,
        "authorization_type": "jwt",
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restart", action="store_true", help="drop the channel and reload from row 0")
    ap.add_argument("--status", action="store_true", help="print channel state and exit")
    args = ap.parse_args()

    if not os.path.exists(NDJSON):
        print(f"missing {NDJSON} — run source/generate.py first")
        return 1

    client = StreamingIngestClient.from_table(
        client_name="qc-sdk-direct",
        db_name=DB, schema_name=SCHEMA, table_name=TABLE,
        properties=properties(),
    )

    if args.restart:
        try:
            client.drop_channel(CHANNEL)
            print(f"dropped channel {CHANNEL}")
        except Exception as exc:                      # channel may not exist yet
            print(f"drop skipped: {exc}")

    channel, status = client.open_channel(CHANNEL)
    committed = status.latest_committed_offset_token
    print(f"channel  {CHANNEL}")
    print(f"  rows inserted so far  {status.rows_inserted_count}")
    print(f"  committed offset      {committed}")

    if args.status:
        client.close()
        return 0

    # The offset token is the index of the last row appended. Resuming is
    # therefore just "skip that many", and it is exact rather than approximate:
    # the token was committed by Snowflake, not tracked by this process.
    start = int(committed) + 1 if committed is not None else 0

    with open(NDJSON) as fh:
        events = [json.loads(line) for line in fh]
    total = len(events)

    if start >= total:
        print(f"\nnothing to do: all {total:,} rows already committed.")
        print("That is the exactly-once guarantee working -- a re-run appends nothing.")
        client.close()
        return 0

    print(f"\nappending rows {start:,}..{total - 1:,} in batches of {BATCH:,}")
    t0 = time.time()

    for lo in range(start, total, BATCH):
        hi = min(lo + BATCH, total)
        now = datetime.now(timezone.utc).replace(tzinfo=None).isoformat(timespec="milliseconds")
        rows = [
            {
                "RECORD_CONTENT": ev,
                # Shaped like the connector's own RECORD_METADATA so all three
                # mechanisms can be compared on the same columns.
                "RECORD_METADATA": {
                    "source": "snowpipe_streaming_sdk",
                    "channel": CHANNEL,
                    "offset": i,
                    "CreateTime": ev.get("event_ts"),
                },
                "LOAD_TS": now,
            }
            for i, ev in enumerate(events[lo:hi], start=lo)
        ]
        channel.append_rows(rows, start_offset_token=str(lo), end_offset_token=str(hi - 1))
        print(f"  appended {hi - lo:>6,}  through offset {hi - 1:,}")

    print("\nwaiting for commit")
    channel.wait_for_commit(lambda tok: tok is not None and int(tok) >= total - 1,
                            timeout_seconds=120)
    elapsed = time.time() - t0

    final = channel.get_channel_status()
    print(f"\ncommitted offset  {final.latest_committed_offset_token}")
    print(f"rows inserted     {final.rows_inserted_count:,}")
    print(f"rows errored      {final.rows_error_count}")
    print(f"server avg latency {final.server_avg_processing_latency}")
    print(f"wall clock        {elapsed:.1f}s for {total - start:,} rows")

    channel.close()
    client.close()
    print("\nRun again to see the channel resume and append nothing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

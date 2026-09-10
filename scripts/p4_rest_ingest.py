#!/usr/bin/env python3
"""Mechanism 5 — drive Snowpipe over its REST API.

Mechanism 4 is push: a blob lands, Azure raises an event, Snowflake reacts.
This is pull: files are already on an internal stage and the client tells
Snowflake exactly which ones to load. Internal stages have no notification
source, so insertFiles is the only way in -- which is precisely why the brief
asks for both.

  pip install snowflake-ingest
  python scripts/p4_rest_ingest.py            PUT the files, then insertFiles
  python scripts/p4_rest_ingest.py --report   ask insertReport what happened

Auth is the same SVC_KAFKA key pair the Kafka connector uses. The REST API
takes a JWT signed with the private key -- no password anywhere.
"""
from __future__ import annotations

import argparse
import glob
import os
import subprocess
import sys
import time

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization
from snowflake.ingest import SimpleIngestManager, StagedFile

ACCOUNT = "AWTTGVH-OLB61128"
HOST = "awttgvh-olb61128.snowflakecomputing.com"
USER = "SVC_KAFKA"
PIPE = "QCOMMERCE.LAND.PIPE_CLICKSTREAM_REST"
STAGE = "@QCOMMERCE.LAND.STG_INTERNAL"
CONNECTION = os.environ.get("SNOW_CONNECTION", "qcpoc")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KEYFILE = os.environ.get("KEYFILE", os.path.join(ROOT, "rsa_kafka.p8"))
FILES = os.path.join(ROOT, "source", "out", "clickstream", "*.ndjson.gz")


def private_key_der() -> bytes:
    """The REST client signs a JWT, so it needs the key as DER, not PEM text."""
    with open(KEYFILE, "rb") as fh:
        key = serialization.load_pem_private_key(fh.read(), password=None,
                                                 backend=default_backend())
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def put_files(paths: list[str]) -> None:
    """PUT needs a client. Snowsight cannot upload from a filesystem, which is
    the practical reason the Snowflake CLI is a hard requirement for this part."""
    for p in paths:
        cmd = ["snow", "sql", "-c", CONNECTION, "-q",
               f"PUT file://{p} {STAGE}/clickstream/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        status = "ok" if r.returncode == 0 else "FAILED"
        print(f"  PUT {os.path.basename(p):<40} {status}")
        if r.returncode != 0:
            print(r.stderr[:400])
            sys.exit(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="fetch insertReport only")
    args = ap.parse_args()

    paths = sorted(glob.glob(FILES))
    if not paths:
        print(f"no files at {FILES} — run source/gen_clickstream.py first")
        return 1

    mgr = SimpleIngestManager(account=ACCOUNT, host=HOST, user=USER,
                              pipe=PIPE, private_key=private_key_der())

    if args.report:
        print(mgr.get_history())
        return 0

    print(f"== PUT {len(paths)} files to {STAGE}/clickstream/")
    put_files(paths)

    staged = [StagedFile(f"clickstream/{os.path.basename(p)}", None) for p in paths]
    print(f"\n== insertFiles: telling Snowpipe about {len(staged)} files")
    resp = mgr.ingest_files(staged)
    print(f"   {resp['responseCode']}")

    # insertFiles is asynchronous and returns immediately. The load happens
    # afterwards, so the honest confirmation is insertReport, not the POST.
    print("\n== waiting, then insertReport")
    time.sleep(30)
    report = mgr.get_history()
    for f in report.get("files", []):
        print(f"   {f.get('path'):<50} {f.get('status'):<10} "
              f"rows={f.get('rowsInserted')} errors={f.get('errorsSeen')}")
    if not report.get("files"):
        print("   nothing reported yet — Snowpipe is asynchronous, re-run with --report")
    return 0


if __name__ == "__main__":
    sys.exit(main())

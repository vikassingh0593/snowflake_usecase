#!/usr/bin/env python3
"""Mechanism 13 — write_pandas: a dataframe straight into a table.

The store -> delivery-zone mapping is the kind of reference data a business
owner keeps in a spreadsheet and nobody ever builds a pipeline for. Eight rows.
A COPY needs a file, a stage, a file format and a target table; write_pandas
needs a dataframe and a table name, and creates the table from the dtypes.

It is also the mechanism with the sharpest edge in this project:

  auto_create_table quotes every identifier. Pandas gives it lower-case column
  names, so the table comes back with "store_id" -- lower case, quoted, and
  unreachable from SQL that says STORE_ID. Upper-casing the frame first is the
  whole fix, and skipping it produces a table that looks fine in the result and
  cannot be joined to anything.

Note the key format against scripts/p4_rest_ingest.py: snowflake-ingest 1.0.x
wants a PEM *string*, this connector wants DER *bytes*. Same key pair, same
account, two different expectations.

  bash scripts/p6_pandas_run.sh          run it in a container (recommended)
  python scripts/p6_write_pandas.py      run it locally, if you have arm64 python

Auth is the SVC_KAFKA key pair. No password anywhere.
"""
from __future__ import annotations

import argparse
import os
import sys

ACCOUNT = "AWTTGVH-OLB61128"
USER = "SVC_KAFKA"
ROLE = "QC_LOADER"
WAREHOUSE = "WH_INGEST_XS"
DATABASE = "QCOMMERCE"
SCHEMA = "RAW"
TABLE = "DIM_STORE_SEED"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KEYFILE = os.environ.get("KEYFILE", os.path.join(ROOT, "rsa_kafka.p8"))
STORES_CSV = os.path.join(ROOT, "source", "out", "dark_stores.csv")

# The reference data itself. Version-controlled here rather than in the source
# database on purpose: this is a commercial decision, not an operational fact,
# and it changes when someone in operations says so.
ZONE_BY_CITY = {
    "Gurgaon":   ("NCR-WEST",    "Meera Nair",     6.0),
    "Noida":     ("NCR-EAST",    "Rohan Verma",    5.5),
    "Ghaziabad": ("NCR-EAST",    "Rohan Verma",    7.0),
    "Delhi":     ("NCR-CENTRAL", "Ananya Sharma",  4.5),
    "Faridabad": ("NCR-SOUTH",   "Kabir Reddy",    7.5),
}
TIER_BY_PINCODE_PREFIX = {"1100": "T1", "1220": "T1", "2013": "T2",
                          "1210": "T3", "2010": "T3"}


def load_private_key() -> bytes:
    """PEM file -> DER bytes. This connector will not take the PEM."""
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization

    if not os.path.exists(KEYFILE):
        sys.exit(f"private key not found: {KEYFILE}")
    with open(KEYFILE, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None,
                                                 backend=default_backend())
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def build_frame():
    import pandas as pd

    if not os.path.exists(STORES_CSV):
        sys.exit(f"{STORES_CSV} not found -- run source/generate.py first")

    df = pd.read_csv(STORES_CSV)
    df["pin4"] = df["pincode"].astype(str).str.zfill(6).str[:4]

    df["zone_code"] = df["city"].map(lambda c: ZONE_BY_CITY[c][0])
    df["zone_manager"] = df["city"].map(lambda c: ZONE_BY_CITY[c][1])
    df["service_radius_km"] = df["city"].map(lambda c: ZONE_BY_CITY[c][2])
    df["store_tier"] = df["pin4"].map(TIER_BY_PINCODE_PREFIX).fillna("T3")
    # A promise is set per tier, and this column is what makes an SLA breach a
    # commercial fact rather than a number someone remembers.
    df["promise_minutes"] = df["store_tier"].map({"T1": 12, "T2": 16, "T3": 20})

    df = df[["store_id", "store_code", "city", "pincode", "lat", "lon",
             "zone_code", "zone_manager", "store_tier",
             "service_radius_km", "promise_minutes", "is_active"]]

    # THE FIX. auto_create_table quotes identifiers exactly as given, so a
    # lower-case frame produces a lower-case quoted table that no unquoted SQL
    # can reach. Upper-case here, once, before it becomes a schema.
    df.columns = [c.upper() for c in df.columns]
    return df


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="build the frame and print it, connect to nothing")
    args = ap.parse_args()

    df = build_frame()
    print(f"frame: {len(df)} rows x {len(df.columns)} columns")
    print(df.to_string(index=False))

    if args.dry_run:
        print("\n--dry-run: nothing sent")
        return 0

    import snowflake.connector
    from snowflake.connector.pandas_tools import write_pandas

    conn = snowflake.connector.connect(
        account=ACCOUNT, user=USER, private_key=load_private_key(),
        role=ROLE, warehouse=WAREHOUSE, database=DATABASE, schema=SCHEMA,
        session_parameters={"QUERY_TAG": "p06:write_pandas"},
    )
    try:
        # overwrite=True replaces the table rather than appending, which is the
        # right semantics for reference data: there is one current mapping, and
        # yesterday's is not a row to keep. quote_identifiers=False stops the
        # connector quoting the (already upper-case) names into existence.
        ok, n_chunks, n_rows, output = write_pandas(
            conn, df, TABLE,
            database=DATABASE, schema=SCHEMA,
            auto_create_table=True, overwrite=True,
            quote_identifiers=False,
        )
        print(f"\nwrite_pandas: success={ok} chunks={n_chunks} rows={n_rows}")

        cur = conn.cursor()
        cur.execute(f"SELECT COUNT(*) FROM {DATABASE}.{SCHEMA}.{TABLE}")
        print(f"count in Snowflake: {cur.fetchone()[0]}")

        # Proof the identifiers are usable, not just present. This unquoted
        # reference is exactly what fails when the frame was left lower-case.
        cur.execute(f"SELECT ZONE_CODE, COUNT(*), AVG(PROMISE_MINUTES) "
                    f"FROM {DATABASE}.{SCHEMA}.{TABLE} GROUP BY 1 ORDER BY 1")
        print("\nzone_code           stores  avg_promise")
        for zone, cnt, avg in cur.fetchall():
            print(f"  {zone:<18} {cnt:>4}   {float(avg):>6.1f}")

        cur.execute(f"DESC TABLE {DATABASE}.{SCHEMA}.{TABLE}")
        print("\ncolumn types as inferred from the dtypes:")
        for row in cur.fetchall():
            print(f"  {row[0]:<20} {row[1]}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

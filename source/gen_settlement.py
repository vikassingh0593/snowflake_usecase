#!/usr/bin/env python3
"""3PL settlement extracts — the partner drop that mechanism 8 queries in place.

Standard library only, so it runs in Azure Cloud Shell where az lives.

A settlement file is what a logistics partner sends after the fact: what they
believe they delivered, what they are charging, and what they collected. It
disagrees with your own order data often enough that reconciling the two is the
reason to keep it queryable rather than loaded.

  python3 source/gen_settlement.py --days 7
Output: source/out/settlement/settlement_YYYYMMDD.csv
"""
from __future__ import annotations

import argparse
import csv
import os
import random
from datetime import datetime, timedelta, timezone

random.seed(20260911)
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "settlement")

CARRIERS = ["SWIFTLOG", "METROSHIP", "NCRDASH"]
HEADER = ["settlement_id", "settlement_date", "carrier", "order_id",
          "freight_paise", "cod_collected_paise", "adjustment_paise",
          "status", "remarks"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--per-day", type=int, default=400)
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    today = datetime.now(timezone.utc).date()
    total = 0

    for d in range(args.days, 0, -1):
        day = today - timedelta(days=d)
        path = os.path.join(OUT, f"settlement_{day.strftime('%Y%m%d')}.csv")
        with open(path, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(HEADER)
            for i in range(args.per_day):
                # Order ids overlap the generated order range, so the external
                # table joins to FCT_ORDER later and the mismatches are real
                # rather than every row failing to match.
                order_id = 900000 + random.randint(0, 19999)
                cod = random.choice([0, 0, 0, random.randint(5000, 120000)])
                status = random.choices(
                    ["SETTLED", "SETTLED", "SETTLED", "DISPUTED", "PENDING"],
                    weights=[70, 10, 10, 6, 4])[0]
                w.writerow([
                    f"{day.strftime('%Y%m%d')}-{i:05d}",
                    day.isoformat(),
                    random.choice(CARRIERS),
                    order_id,
                    random.randint(1500, 9000),
                    cod,
                    random.choice([0, 0, 0, -random.randint(500, 5000)]),
                    status,
                    "" if status == "SETTLED" else random.choice(
                        ["address mismatch", "weight dispute", "awaiting POD"]),
                ])
                total += 1
        print(f"  {os.path.basename(path)}  {args.per_day} rows")

    print(f"\n{args.days} files, {total:,} rows -> {OUT}")


if __name__ == "__main__":
    main()

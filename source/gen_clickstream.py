#!/usr/bin/env python3
"""Clickstream generator — hourly gzipped NDJSON for Snowpipe.

Standard library only, so it runs anywhere including Azure Cloud Shell. That
matters: landing/ is read-only to Snowflake by design, so Snowflake cannot write
its own test files there. Generating and uploading from Cloud Shell keeps the
least-privilege grant intact instead of widening it for convenience.

  python3 source/gen_clickstream.py            24 files, ~50,000 events
  python3 source/gen_clickstream.py --hours 4  fewer, for a quick test

Output: source/out/clickstream/clickstream_YYYYMMDDHH.ndjson.gz
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

random.seed(20260910)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "clickstream")

N_CUSTOMERS, N_PRODUCTS = 500, 200
PAGES = ["/", "/search", "/category/grocery", "/category/fresh",
         "/category/beverages", "/cart", "/checkout"]
ACTIONS = ["view", "search", "add_to_cart", "remove_from_cart", "checkout_start", "purchase"]
ACTION_W = [55, 15, 14, 4, 7, 5]
DEVICES, DEVICE_W = ["android", "ios", "web"], [58, 30, 12]
UTM = [None, None, "google", "meta", "push", "referral"]

# Same IST demand curve as the order generator, so clickstream volume and order
# volume peak together rather than contradicting each other.
HOUR_WEIGHT = [1, 1, 1, 1, 1, 2, 4, 7, 9, 10, 11, 14, 18, 16, 11, 10,
               12, 15, 22, 26, 24, 18, 9, 4]
IST = timedelta(hours=5, minutes=30)


def events_for_hour(hour_start: datetime, n: int) -> list[dict]:
    out = []
    for _ in range(n):
        session = str(uuid.uuid4())
        customer = random.randint(1, N_CUSTOMERS) if random.random() > 0.25 else None
        device = random.choices(DEVICES, weights=DEVICE_W)[0]
        for _ in range(random.choices([1, 2, 3, 5, 8], weights=[30, 28, 22, 14, 6])[0]):
            action = random.choices(ACTIONS, weights=ACTION_W)[0]
            ts = hour_start + timedelta(seconds=random.randint(0, 3599),
                                        milliseconds=random.randint(0, 999))
            out.append({
                "click_id": str(uuid.uuid4()),
                "session_id": session,
                "customer_id": customer,
                "event_ts": ts.strftime("%Y-%m-%dT%H:%M:%S.") + f"{ts.microsecond // 1000:03d}Z",
                "page": random.choice(PAGES),
                "action": action,
                "product_id": random.randint(1, N_PRODUCTS) if action != "search" else None,
                "device": device,
                "app_version": random.choice(["4.11.2", "4.12.0", "4.9.7"]),
                "utm_source": random.choice(UTM),
            })
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=int, default=24)
    ap.add_argument("--target", type=int, default=50_000, help="approximate total events")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    end = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    hours = [end - timedelta(hours=h) for h in range(args.hours, 0, -1)]

    weights = [HOUR_WEIGHT[(h + IST).hour] for h in hours]
    scale = args.target / (sum(weights) * 2.6)      # ~2.6 events per session

    total = 0
    for h, w in zip(hours, weights):
        n_sessions = max(1, int(w * scale))
        evs = events_for_hour(h, n_sessions)
        path = os.path.join(OUT, f"clickstream_{h.strftime('%Y%m%d%H')}.ndjson.gz")
        with gzip.open(path, "wt") as fh:
            for e in evs:
                fh.write(json.dumps(e, separators=(",", ":")) + "\n")
        total += len(evs)
        print(f"  {os.path.basename(path)}  {len(evs):>5,} events  "
              f"{os.path.getsize(path) / 1024:.0f} KB")

    print(f"\n{len(hours)} files, {total:,} events -> {OUT}")


if __name__ == "__main__":
    main()

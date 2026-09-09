#!/usr/bin/env python3
"""Quick-commerce source data generator.

Pure standard library on purpose: no faker, no psycopg2, no kafka client. It
writes CSVs that Postgres COPYs and NDJSON that `rpk topic produce` publishes,
so the source system needs no Python dependencies at all.

Output -> source/out/
  dark_stores.csv customers.csv products.csv riders.csv
  inventory.csv orders.csv order_items.csv     (loaded into Postgres)
  order_status.ndjson                          (produced to qc.order_status)

Money is integer paise everywhere. Timestamps are ISO-8601 UTC with
milliseconds, stamped as the producer would stamp them.
"""
from __future__ import annotations

import csv
import json
import math
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

SEED = 20260909
random.seed(SEED)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
DAYS = 60
END = datetime(2026, 9, 9, tzinfo=timezone.utc)
START = END - timedelta(days=DAYS)

N_STORES, N_PRODUCTS, N_CUSTOMERS, N_RIDERS, N_ORDERS = 8, 200, 500, 60, 20_000
DUP_RATE = 0.01      # at-least-once delivery: CORE dedupes these with QUALIFY
ANOMALY_RATE = 0.02  # skipped / out-of-order transitions for MATCH_RECOGNIZE

IST = timedelta(hours=5, minutes=30)


def iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{ts.microsecond // 1000:03d}Z"


def haversine_km(lat1, lon1, lat2, lon2) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def write_csv(name, header, rows):
    path = os.path.join(OUT, f"{name}.csv")
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(rows)
    print(f"  {name:<14} {len(rows):>7,} rows")


# --------------------------------------------------------------------------
# Reference data. Delhi NCR, consistent with the lat/lon in the event contract.
# --------------------------------------------------------------------------
CITIES = [
    ("Gurgaon", "122001", 28.4595, 77.0266), ("Gurgaon", "122018", 28.4212, 77.0430),
    ("Noida", "201301", 28.5355, 77.3910),   ("Noida", "201304", 28.5062, 77.4025),
    ("Delhi", "110016", 28.5494, 77.2001),   ("Delhi", "110024", 28.5672, 77.2436),
    ("Faridabad", "121001", 28.4089, 77.3178), ("Ghaziabad", "201009", 28.6692, 77.4538),
]

CATEGORY_TREE = {
    "Grocery":   {"Staples": ["Rice", "Atta", "Pulses", "Sugar"],
                  "Snacks": ["Chips", "Biscuits", "Namkeen"]},
    "Fresh":     {"Produce": ["Vegetables", "Fruits"],
                  "Dairy": ["Milk", "Curd", "Paneer", "Cheese"]},
    "Beverages": {"Cold": ["Soft Drinks", "Juices", "Energy"],
                  "Hot": ["Tea", "Coffee"]},
    "Household": {"Cleaning": ["Detergent", "Floor Cleaner"],
                  "Personal Care": ["Shampoo", "Soap", "Oral Care"]},
}

FIRST = ["Aarav", "Vivaan", "Aditya", "Ananya", "Diya", "Ishaan", "Kabir", "Meera",
         "Neha", "Rohan", "Saanvi", "Tara", "Vikram", "Zara", "Arjun", "Priya"]
LAST = ["Sharma", "Verma", "Singh", "Gupta", "Reddy", "Nair", "Iyer", "Bose",
        "Kapoor", "Malhotra", "Chawla", "Rao", "Joshi", "Mehta"]


def gen_stores():
    rows = []
    for i, (city, pin, lat, lon) in enumerate(CITIES[:N_STORES], start=1):
        rows.append([i, f"DS{i:03d}", city, pin, round(lat, 6), round(lon, 6),
                     (START - timedelta(days=random.randint(200, 900))).date(), True])
    return rows


def gen_products():
    rows, pid = [], 0
    flat = [(l1, l2, l3) for l1, subs in CATEGORY_TREE.items()
            for l2, l3s in subs.items() for l3 in l3s]
    while pid < N_PRODUCTS:
        l1, l2, l3 = flat[pid % len(flat)]
        pid += 1
        # price in paise: 1500 (Rs 15) .. 95000 (Rs 950)
        price = random.choice([1500, 2500, 3900, 4900, 7500, 9900, 14900, 19900,
                               24900, 34900, 49900, 74900, 95000])
        rows.append([pid, f"SKU{pid:05d}", f"{l3} Pack {pid % 7 + 1}", l1, l2, l3,
                     price, random.random() > 0.06,
                     iso(START + timedelta(days=random.randint(0, DAYS)))])
    return rows


def gen_customers():
    rows = []
    for cid in range(1, N_CUSTOMERS + 1):
        city, pin, lat, lon = random.choice(CITIES)
        name = f"{random.choice(FIRST)} {random.choice(LAST)}"
        rows.append([
            cid, name,
            f"{name.split()[0].lower()}.{cid}@example.com",
            f"+9198{random.randint(10000000, 99999999)}",
            random.choices(["NEW", "REGULAR", "PREMIUM"], weights=[20, 60, 20])[0],
            pin,
            round(lat + random.uniform(-0.06, 0.06), 6),
            round(lon + random.uniform(-0.06, 0.06), 6),
            iso(START - timedelta(days=random.randint(0, 700))),
        ])
    return rows


def gen_riders():
    rows = []
    for rid in range(1, N_RIDERS + 1):
        rows.append([rid, f"{random.choice(FIRST)} {random.choice(LAST)}",
                     f"+9197{random.randint(10000000, 99999999)}",
                     random.choices(["BIKE", "EV_BIKE", "CYCLE"], weights=[70, 25, 5])[0],
                     random.randint(1, N_STORES),
                     random.choice(["MORNING", "EVENING", "NIGHT"]),
                     random.random() > 0.08,
                     (START - timedelta(days=random.randint(10, 500))).date()])
    return rows


def gen_inventory():
    rows = []
    for d in range(DAYS):
        day = (START + timedelta(days=d)).date()
        for s in range(1, N_STORES + 1):
            for p in range(1, N_PRODUCTS + 1):
                rows.append([day, s, p, max(0, int(random.gauss(48, 22))), 12])
    return rows


# --------------------------------------------------------------------------
# Orders. The breach model is driven only by things that are observable in
# Snowflake later -- distance, hour of day, store load, basket size, rider
# availability. Nothing synthetic that the feature pipeline cannot rebuild,
# so Part 9's model learns a real signal rather than a planted one.
# --------------------------------------------------------------------------
HOUR_WEIGHT = [1, 1, 1, 1, 1, 2, 4, 7, 9, 10, 11, 14, 18, 16, 11, 10,
               12, 15, 22, 26, 24, 18, 9, 4]   # IST hours


def pick_placed_ts() -> datetime:
    day = START + timedelta(days=random.randint(0, DAYS - 1))
    ist_hour = random.choices(range(24), weights=HOUR_WEIGHT)[0]
    ist = day.replace(hour=0, minute=0, second=0, microsecond=0) + IST
    ts = ist + timedelta(hours=ist_hour, minutes=random.randint(0, 59),
                         seconds=random.randint(0, 59),
                         milliseconds=random.randint(0, 999)) - IST
    return ts.astimezone(timezone.utc)


def gen_orders(stores, customers, riders):
    store_by_id = {r[0]: r for r in stores}
    cust_by_id = {r[0]: r for r in customers}
    riders_by_store: dict[int, list[int]] = {}
    for r in riders:
        if r[6]:
            riders_by_store.setdefault(r[4], []).append(r[0])

    load: dict[tuple[int, str], int] = {}
    orders, items, events = [], [], []
    item_id = 0

    for oid in range(900_000, 900_000 + N_ORDERS):
        placed = pick_placed_ts()
        cust_id = random.randint(1, N_CUSTOMERS)
        cust = cust_by_id[cust_id]
        # nearest store, with 15% going to the second nearest (stockout, capacity)
        ranked = sorted(stores, key=lambda st: haversine_km(st[4], st[5], cust[6], cust[7]))
        store = ranked[1] if (len(ranked) > 1 and random.random() < 0.15) else ranked[0]
        store_id = store[0]

        bucket = (store_id, placed.strftime("%Y-%m-%dT%H"))
        load[bucket] = load.get(bucket, 0) + 1
        store_load = load[bucket]

        dist = haversine_km(store[4], store[5], cust[6], cust[7])
        n_items = random.choices([1, 2, 3, 4, 5, 6, 8], weights=[24, 28, 22, 12, 8, 4, 2])[0]

        gross = 0
        for _ in range(n_items):
            pid = random.randint(1, N_PRODUCTS)
            qty = random.choices([1, 2, 3], weights=[70, 22, 8])[0]
            unit = random.choice([1500, 2500, 3900, 4900, 7500, 9900, 14900, 19900, 24900, 34900])
            item_id += 1
            line = unit * qty
            gross += line
            items.append([item_id, oid, pid, qty, unit, line])

        coupon = random.choice([None, None, None, "QC10", "FIRST50", "WEEKEND20"])
        discount = int(gross * 0.1) if coupon else 0
        fee = 0 if gross >= 30000 else 2900
        total = gross - discount + fee

        promised = placed + timedelta(minutes=random.randint(10, 25))
        ist_hour = (placed + IST).hour
        peak = 1.0 if ist_hour in (12, 13, 19, 20, 21) else 0.0
        pool = riders_by_store.get(store_id, [])
        rider_id = random.choice(pool) if pool else None

        logit = (-3.05
                 + 0.85 * (dist / 5.0)
                 + 0.55 * peak
                 + 0.70 * (min(store_load, 15) / 15.0)
                 + 0.25 * (n_items / 5.0)
                 + random.gauss(0, 0.50))
        p_breach = 1 / (1 + math.exp(-logit))

        cancelled = random.random() < 0.03
        if cancelled:
            status, packed = "CANCELLED", (placed + timedelta(minutes=random.randint(1, 4))
                                           if random.random() < 0.5 else None)
            picked = delivered = None
        else:
            status = "DELIVERED"
            packed = placed + timedelta(minutes=random.uniform(1.5, 6.0))
            picked = packed + timedelta(minutes=random.uniform(0.5, 4.0))
            base = (promised - placed).total_seconds() / 60.0
            late = random.random() < p_breach
            ride_minutes = base * (random.uniform(1.06, 1.85) if late
                                   else random.uniform(0.55, 0.94))
            delivered = placed + timedelta(minutes=ride_minutes)
            if delivered <= picked:      # keep the milestone order intact
                delivered = picked + timedelta(minutes=random.uniform(1.0, 3.0))

        orders.append([oid, cust_id, store_id, rider_id, iso(placed), iso(promised),
                       iso(packed) if packed else "", iso(picked) if picked else "",
                       iso(delivered) if delivered else "", status,
                       random.choices(["UPI", "CARD", "COD", "WALLET"], weights=[55, 22, 15, 8])[0],
                       coupon or "", n_items, gross, discount, fee, total])

        events.extend(build_events(oid, store_id, rider_id, placed, packed, picked,
                                   delivered, cancelled))

    return orders, items, events


def build_events(oid, store_id, rider_id, placed, packed, picked, delivered, cancelled):
    """One event per lifecycle transition, plus deliberate imperfections.

    ANOMALY_RATE of orders skip a transition or emit one out of order, so
    MATCH_RECOGNIZE has something real to find. DUP_RATE of events are emitted
    twice, because Snowpipe Streaming is at-least-once and CORE has to dedupe.
    """
    steps = [(None, "PLACED", placed)]
    if cancelled:
        if packed:
            steps.append(("PLACED", "PACKED", packed))
        steps.append((steps[-1][1], "CANCELLED", (packed or placed) + timedelta(minutes=2)))
    else:
        steps += [("PLACED", "PACKED", packed),
                  ("PACKED", "PICKED_UP", picked),
                  ("PICKED_UP", "DELIVERED", delivered)]

    if random.random() < ANOMALY_RATE and len(steps) > 2:
        if random.random() < 0.5:
            del steps[random.randint(1, len(steps) - 2)]        # skipped transition
        else:
            i = random.randint(1, len(steps) - 2)               # out-of-order stamp
            steps[i] = (steps[i][0], steps[i][1], steps[i][2] + timedelta(minutes=9))

    out = []
    for frm, to, ts in steps:
        if ts is None:
            continue
        ev = {
            "event_id": str(uuid.uuid4()),
            "order_id": oid,
            "store_id": store_id,
            "rider_id": rider_id,
            "from_status": frm,
            "to_status": to,
            "event_ts": iso(ts),
            "source": random.choices(["rider_app", "store_app", "backend"],
                                     weights=[55, 30, 15])[0],
            "meta": {"app_version": random.choice(["4.11.2", "4.12.0", "4.9.7"]),
                     "network": random.choices(["4G", "5G", "WIFI"], weights=[55, 30, 15])[0]},
        }
        out.append(ev)
        if random.random() < DUP_RATE:
            out.append(dict(ev))    # same event_id: the duplicate QUALIFY removes
    return out


# --------------------------------------------------------------------------
# Self-validation. The generator checks its own output against the DDL before
# claiming success, because psql \copy loads POSITIONALLY -- a header check
# alone passes happily while a float sits in a money column.
# --------------------------------------------------------------------------
SCHEMA_SQL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "postgres", "init", "01_schema.sql")


def ddl_columns() -> dict[str, list[tuple[str, str]]]:
    """(column, type) per table, in declaration order, parsed from the DDL."""
    import re
    text = open(SCHEMA_SQL).read()
    out = {}
    for m in re.finditer(r"CREATE TABLE (\w+) \((.*?)\n\);", text, re.S):
        cols = []
        for line in m.group(2).split("\n"):
            line = line.split("--")[0].strip().rstrip(",")
            if not line or line.upper().startswith(
                    ("PRIMARY KEY", "FOREIGN KEY", "UNIQUE", "CONSTRAINT")):
                continue
            parts = line.split()
            cols.append((parts[0], " ".join(parts[1:2]).upper()))
        out[m.group(1)] = cols
    return out


def check_value(val: str, sqltype: str) -> str | None:
    if val == "":
        return None                      # NULL, allowed by COPY ... NULL ''
    try:
        if sqltype in ("INT", "BIGINT"):
            int(val)
        elif sqltype == "DOUBLE":
            float(val)
        elif sqltype == "BOOLEAN":
            if val.lower() not in ("true", "false", "t", "f", "1", "0"):
                return "not a boolean"
        elif sqltype == "DATE":
            datetime.strptime(val, "%Y-%m-%d")
        elif sqltype == "TIMESTAMPTZ":
            datetime.strptime(val, "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        return f"not {sqltype.lower()}"
    return None


def validate() -> bool:
    ddl, bad = ddl_columns(), 0
    for table, cols in ddl.items():
        path = os.path.join(OUT, f"{table}.csv")
        if not os.path.exists(path):
            continue
        with open(path) as fh:
            rows = csv.reader(fh)
            header = next(rows)
            names = [c for c, _ in cols]
            if header != names:
                print(f"  FAIL {table}: header/DDL order differs\n"
                      f"       ddl {names}\n       csv {header}")
                bad += 1
                continue
            for n, row in enumerate(rows, start=2):
                for (col, sqltype), val in zip(cols, row):
                    err = check_value(val, sqltype)
                    if err:
                        print(f"  FAIL {table} line {n} column {col}: "
                              f"{val!r} is {err}")
                        bad += 1
                        break
                if bad:
                    break
    print("  validation: OK, every column parses as its DDL type" if not bad
          else f"  validation: {bad} table(s) FAILED -- do not load")
    return bad == 0


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    print(f"generating -> {OUT}")

    stores = gen_stores();      write_csv("dark_stores", ["store_id", "store_code", "city", "pincode", "lat", "lon", "opened_on", "is_active"], stores)
    products = gen_products();  write_csv("products", ["product_id", "sku", "name", "category_l1", "category_l2", "category_l3", "price_paise", "is_active", "updated_at"], products)
    customers = gen_customers();write_csv("customers", ["customer_id", "full_name", "email", "phone", "segment", "home_pincode", "home_lat", "home_lon", "created_at"], customers)
    riders = gen_riders();      write_csv("riders", ["rider_id", "full_name", "phone", "vehicle_type", "store_id", "shift", "is_active", "joined_on"], riders)
    write_csv("inventory", ["snapshot_date", "store_id", "product_id", "on_hand_qty", "reorder_level"], gen_inventory())

    orders, items, events = gen_orders(stores, customers, riders)
    write_csv("orders", ["order_id", "customer_id", "store_id", "rider_id", "placed_ts", "promised_ts", "packed_ts", "picked_up_ts", "delivered_ts", "status", "payment_method", "coupon_code", "item_count", "gross_paise", "discount_paise", "delivery_fee_paise", "order_total_paise"], orders)
    write_csv("order_items", ["order_item_id", "order_id", "product_id", "qty", "unit_price_paise", "line_total_paise"], items)

    path = os.path.join(OUT, "order_status.ndjson")
    with open(path, "w") as fh:
        for e in events:
            fh.write(json.dumps(e, separators=(",", ":")) + "\n")
    print(f"  order_status   {len(events):>7,} events -> order_status.ndjson")

    breached = sum(1 for o in orders
                   if o[8] and o[8] > o[5])
    delivered = sum(1 for o in orders if o[9] == "DELIVERED")
    print(f"\n  delivered {delivered:,} | SLA breach {breached:,} "
          f"({breached / max(delivered, 1):.1%}) | duplicates ~{DUP_RATE:.0%} | "
          f"anomalies ~{ANOMALY_RATE:.0%}")

    if not validate():
        raise SystemExit(1)


if __name__ == "__main__":
    main()

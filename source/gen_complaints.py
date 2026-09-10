#!/usr/bin/env python3
"""Mechanism 10 — the complaint corpus, as PDFs.

Writes source/out/complaints/CMP-nnnnnn.pdf, one page each, plus a small
hand-labelled sample to dbt/seeds/complaint_label.csv for mechanism 14.

The two halves are deliberately different kinds of data:

  the PDFs    unlabelled free text, arriving as files. A directory table is
              the only way to see them, and pypdf in a UDF the only way to
              read them once Cortex is off the table.
  the seed    the labels. Small, hand-curated, version-controlled, and the
              training target for the classifier in Part 10.

No third-party library. A text-only PDF is a handful of objects and an
xref table, and reportlab would be a dependency for eighty lines of work.
Uncompressed streams on purpose: `strings` on the file shows the text, which
makes a bad extraction obvious without opening a reader.

  python3 source/gen_complaints.py            300 PDFs + the label seed
  python3 source/gen_complaints.py --n 50     fewer, for a quick loop
"""
from __future__ import annotations

import argparse
import csv
import os
import random
from datetime import datetime, timedelta, timezone

SEED = 20260909
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "complaints")
SEEDS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "dbt", "seeds")

END = datetime(2026, 9, 9, tzinfo=timezone.utc)
DAYS = 60
N_ORDERS = 20_000          # must match generate.py, so order ids resolve
N_DEFAULT = 300
LABEL_FRACTION = 0.20      # how much of the corpus is hand-labelled

CITIES = ["Gurgaon", "Gurgaon", "Noida", "Noida", "Delhi", "Delhi",
          "Faridabad", "Ghaziabad"]

# --------------------------------------------------------------------------
# Reason codes. The taxonomy also ships as a dbt seed -- these two must agree,
# which is the point of keeping the generator and the seed in one file.
# --------------------------------------------------------------------------
REASONS = {
    "LATE_DELIVERY": [
        "The app promised {promised} minutes and the order turned up after {actual}. "
        "This is the {nth} time this month. I was told the rider was two minutes away for "
        "nearly twenty minutes.",
        "Ordered at {t} and it arrived {late} minutes past the promised time. Nobody called, "
        "nobody messaged. The tracking screen just froze on 'picked up'.",
        "Delivery was {late} minutes late and the whole reason I pay for this service is speed. "
        "If the promise is not real, do not show a countdown.",
    ],
    "MISSING_ITEM": [
        "Two items from my order are missing -- the {item} and one pack of {item2}. "
        "The bill charged me for both. Please refund, and check the packing at store {store}.",
        "The {item} never arrived. The bag was sealed, so this was a packing error, not the rider.",
        "Order shows {n} items, the bag had {n2}. Missing the {item}. I have photographed the bag "
        "and the invoice.",
    ],
    "DAMAGED_ITEM": [
        "The {item} arrived crushed. It was at the bottom of the bag under a bottle. "
        "Basic packing would have prevented this.",
        "Bottle had leaked across everything else in the bag. The {item} is soaked and unusable. "
        "I want the whole order refunded, not just the bottle.",
        "The packaging was torn on arrival and the {item} inside is damaged. Rider said it was "
        "already like that when he collected it.",
    ],
    "WRONG_ITEM": [
        "I ordered {item} and received {item2}. Not remotely the same thing. "
        "I need the correct item today, not a credit note.",
        "Wrong variant sent again -- I selected the larger pack and got the small one, "
        "charged at the larger price.",
        "Received someone else's order entirely. Different name on the slip. "
        "Please arrange collection.",
    ],
    "QUALITY_FRESH": [
        "The {item} was already spoiled when it arrived. Expiry on the pack was yesterday. "
        "Selling that is not a picking error, it is a stock rotation problem at store {store}.",
        "Milk was warm on arrival. The cold chain clearly is not being kept for the "
        "{late} minutes this took to reach me.",
        "Produce quality has dropped badly at this store. The {item} was limp and browning. "
        "I have started checking every bag before the rider leaves.",
    ],
    "RIDER_BEHAVIOUR": [
        "The rider was rude when I asked why the order was late, and left the bag on the floor "
        "outside without ringing. Order {oid}.",
        "Rider marked the order delivered while still ten minutes away, then handed it over "
        "later. The timestamp on your side is wrong as a result.",
        "The rider refused to wait thirty seconds at the gate and threatened to return the "
        "order. That is not acceptable.",
    ],
    "PAYMENT_ISSUE": [
        "Charged twice for order {oid}. Both amounts show on my statement, the app shows one "
        "order. Refund the duplicate.",
        "The coupon was applied on the summary screen and then not applied on the final bill. "
        "I paid {amount} more than shown.",
        "Payment failed in the app but the money left my account. No order was created and "
        "no refund has appeared.",
    ],
    "REFUND_DELAY": [
        "The refund for order {oid} was approved {nth} days ago and has still not reached my "
        "account. Support keeps saying seven working days and restarting the clock.",
        "I have been waiting over a week for a refund of {amount} paise. Each chat opens a new "
        "ticket and closes it without doing anything.",
        "Refund promised on the call, nothing received. This is the third follow-up.",
    ],
    "APP_ISSUE": [
        "The app crashed at checkout and created three duplicate orders. I cancelled two and "
        "was charged a cancellation fee on both.",
        "Cannot see the live tracking at all -- the map is blank and the ETA does not update. "
        "This happens every evening around {t}.",
        "Address saved in the app keeps reverting to an old one, which is why the last two "
        "orders went to the wrong building.",
    ],
    "PACKAGING": [
        "Everything arrives in separate plastic bags even for a four item order. "
        "This is wasteful and it is not what the app claims about packaging.",
        "Frozen items packed with hot items in the same bag. The {item} had started to thaw.",
        "No seal on the bag at all. For food deliveries that is not acceptable.",
    ],
}

REASON_DESC = {
    "LATE_DELIVERY":   ("Delivery later than the promised time",      "operations"),
    "MISSING_ITEM":    ("One or more ordered items not delivered",    "fulfilment"),
    "DAMAGED_ITEM":    ("Item physically damaged in transit",         "fulfilment"),
    "WRONG_ITEM":      ("Item delivered does not match the order",    "fulfilment"),
    "QUALITY_FRESH":   ("Perishable item spoiled or out of condition","supply"),
    "RIDER_BEHAVIOUR": ("Conduct of the delivery rider",              "operations"),
    "PAYMENT_ISSUE":   ("Incorrect or duplicate charge",              "finance"),
    "REFUND_DELAY":    ("Approved refund not received",               "finance"),
    "APP_ISSUE":       ("Defect in the customer application",         "product"),
    "PACKAGING":       ("Packaging quality or waste",                 "supply"),
}

ITEMS = ["Amul Taaza milk 1L", "Tata Salt 1kg", "Aashirvaad atta 5kg", "Fortune oil 1L",
         "Britannia bread", "Amul butter 500g", "Nandini curd 400g", "Safal peas 500g",
         "Kellogg's cornflakes", "Maggi 12-pack", "Tropicana juice 1L", "Colgate 200g",
         "Surf Excel 1kg", "Lays chips", "Paneer 200g", "Bananas 1 dozen",
         "Tomatoes 1kg", "Onions 2kg", "Coriander bunch", "Curd 1kg"]

OPENERS = ["", "Hello, ", "Hi team, ", "To whom it may concern, ",
           "Raising this for the second time. ", "Please look into this. "]
CLOSERS = ["Please resolve.", "Awaiting your response.", "I expect a refund.",
           "Kindly confirm what action you will take.",
           "I have been a customer for two years and this is disappointing.",
           "Happy to share photographs if needed.", ""]


# --------------------------------------------------------------------------
# A minimal PDF writer. Base-14 Helvetica, one page, uncompressed content.
# --------------------------------------------------------------------------
def pdf_escape(s: str) -> str:
    return s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


def wrap(text: str, width: int) -> list[str]:
    words, lines, cur = text.split(), [], ""
    for w in words:
        if len(cur) + len(w) + 1 > width:
            lines.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}".strip()
    if cur:
        lines.append(cur)
    return lines


def content_stream(header: list[tuple[str, int]], body: list[str]) -> bytes:
    """header is (text, size) pairs; body is pre-wrapped 10pt lines."""
    out = ["BT", "1 0 0 1 56 786 Tm", "14 TL"]
    for text, size in header:
        out.append(f"/F1 {size} Tf")
        out.append(f"{int(size * 1.45)} TL")
        out.append(f"({pdf_escape(text)}) Tj T*")
    out.append("/F1 10 Tf")
    out.append("14 TL")
    for line in body:
        out.append(f"({pdf_escape(line)}) Tj T*")
    out.append("ET")
    return ("\n".join(out) + "\n").encode("latin-1", "replace")


def write_pdf(path: str, header: list[tuple[str, int]], body: list[str]) -> None:
    stream = content_stream(header, body)
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream",
    ]

    buf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body_bytes in enumerate(objs, start=1):
        offsets.append(len(buf))
        buf += f"{i} 0 obj\n".encode() + body_bytes + b"\nendobj\n"

    xref_at = len(buf)
    buf += f"xref\n0 {len(objs) + 1}\n".encode()
    buf += b"0000000000 65535 f \n"
    for off in offsets:
        buf += f"{off:010d} 00000 n \n".encode()
    buf += (f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_at}\n%%EOF\n").encode()

    with open(path, "wb") as f:
        f.write(bytes(buf))


# --------------------------------------------------------------------------
def build(n: int) -> tuple[list[dict], list[str]]:
    rng = random.Random(SEED)
    start = END - timedelta(days=DAYS)
    rows, codes = [], sorted(REASONS)

    # Weighted so LATE_DELIVERY dominates, as it does in the order data.
    weights = {"LATE_DELIVERY": 26, "MISSING_ITEM": 15, "QUALITY_FRESH": 12,
               "DAMAGED_ITEM": 10, "WRONG_ITEM": 9, "REFUND_DELAY": 8,
               "PAYMENT_ISSUE": 7, "RIDER_BEHAVIOUR": 6, "APP_ISSUE": 4,
               "PACKAGING": 3}
    pool = [c for c in codes for _ in range(weights[c])]

    for i in range(1, n + 1):
        code = rng.choice(pool)
        raised = start + timedelta(days=rng.randint(0, DAYS - 1),
                                   hours=rng.randint(6, 23), minutes=rng.randint(0, 59))
        oid = rng.randint(1, N_ORDERS)
        promised = rng.choice([10, 12, 15, 18, 20, 25])
        late = rng.randint(6, 48)
        item, item2 = rng.sample(ITEMS, 2)
        text = rng.choice(REASONS[code]).format(
            promised=promised, actual=promised + late, late=late, nth=rng.randint(2, 6),
            t=f"{rng.randint(18, 22)}:{rng.randrange(0, 60, 5):02d}",
            item=item, item2=item2, n=rng.randint(4, 12), n2=rng.randint(2, 3),
            store=f"DS{rng.randint(1, 8):03d}", oid=f"{oid}", amount=rng.randrange(4000, 90000, 500),
        )
        body = f"{rng.choice(OPENERS)}{text} {rng.choice(CLOSERS)}".strip()

        rows.append({
            "ticket_id": f"CMP-{i:06d}",
            "order_id": oid,
            "store_id": rng.randint(1, 8),
            "city": rng.choice(CITIES),
            "channel": rng.choices(["app", "email", "call_centre"], [6, 3, 1])[0],
            "raised_at": raised.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "reason_code": code,
            "body": body,
        })
    return rows, codes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=N_DEFAULT)
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SEEDS, exist_ok=True)
    rows, codes = build(args.n)

    for r in rows:
        header = [
            ("QuickCommerce - Customer Complaint", 15),
            ("", 8),
            (f"Ticket {r['ticket_id']}    Order {r['order_id']}    Store DS{r['store_id']:03d}", 10),
            (f"Raised {r['raised_at']}    Channel: {r['channel']}    City: {r['city']}", 10),
            ("", 8),
        ]
        write_pdf(os.path.join(OUT, f"{r['ticket_id']}.pdf"), header, wrap(r["body"], 88))

    # ---- dbt seed 1: the reason-code taxonomy ----
    with open(os.path.join(SEEDS, "complaint_reason_code.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["reason_code", "description", "owning_team", "is_sla_related"])
        for c in codes:
            desc, team = REASON_DESC[c]
            w.writerow([c, desc, team, c in ("LATE_DELIVERY", "REFUND_DELAY")])

    # ---- dbt seed 2: the hand-labelled training sample ----
    # Deterministic sample, not the whole corpus: the classifier has to
    # generalise from a fifth of it to the rest, which is the actual problem.
    rng = random.Random(SEED + 1)
    labelled = rng.sample(rows, int(len(rows) * LABEL_FRACTION))
    labelled.sort(key=lambda r: r["ticket_id"])
    with open(os.path.join(SEEDS, "complaint_label.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["ticket_id", "reason_code", "labelled_by", "labelled_on"])
        for r in labelled:
            w.writerow([r["ticket_id"], r["reason_code"], "cx_team", "2026-09-10"])

    # ---- the answer key, for scoring only. Never joined in a model. ----
    with open(os.path.join(OUT, "_truth.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["ticket_id", "order_id", "store_id", "raised_at", "reason_code"])
        for r in rows:
            w.writerow([r["ticket_id"], r["order_id"], r["store_id"],
                        r["raised_at"], r["reason_code"]])

    total = sum(os.path.getsize(os.path.join(OUT, f"{r['ticket_id']}.pdf")) for r in rows)
    print(f"{len(rows)} PDFs in {OUT}  ({total / 1024:.0f} KB)")
    print(f"{len(labelled)} labelled rows -> dbt/seeds/complaint_label.csv")
    print(f"{len(codes)} reason codes    -> dbt/seeds/complaint_reason_code.csv")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# Quick-Commerce Analytics Platform — what it is and why

A plain-language companion to `docs/ARCHITECTURE.md`. That document is for engineers.
This one is for anyone who needs to know what we are building, what it will answer, and
where we have got to.

**Living document.** The status table at the end is updated as each stage lands.

---

## 1. The business problem

Quick commerce sells a promise, not just goods. When a customer places an order, the app
commits to a delivery time — typically 10 to 25 minutes. That promise is the product. A
late delivery costs more than the order: it costs the refund, the support call, and
often the customer.

Today most operators find out about a breach when it has already happened. The dispatcher
sees the order go red on a screen and has no time left to do anything useful.

**The question this platform answers: which orders are going to be late, early enough to
do something about it?**

And behind that, the questions a business needs answered every day:

| Question | Who asks it |
|---|---|
| Which stores are missing their promise, and at what hours? | Operations manager |
| Which orders currently in flight are at risk right now? | Dispatcher |
| Why did our on-time rate drop last Tuesday? | Regional head |
| How much stock will each store need tomorrow? | Supply planning |
| What are customers actually complaining about? | Customer experience |
| Who is allowed to see customer contact details? | Compliance |

---

## 2. The business we are modelling

A quick-commerce operator in Delhi NCR:

| | |
|---|---|
| **8 dark stores** | small warehouses, not shops. No customers walk in |
| **60 riders** | attached to a store, working shifts |
| **500 customers**, **200 products** | across grocery, fresh, beverages, household |
| **20,000 orders** over 60 days | each with a promised delivery time |
| **~16% arrive late** | the number the whole platform exists to reduce |

Every amount of money is held in **paise, as a whole number**. Never ₹461.19 — always
46119. Money expressed as a decimal accumulates rounding errors as it moves between
systems; whole paise cannot. It is a small decision that prevents a whole category of
"the numbers don't tie out" meetings.

---

## 3. The journey of one order

This is the platform in one story.

**A customer places an order at 7:42pm.** The app writes it to the operational database
and promises delivery by 8:02pm.

**Within seconds**, that new order is copied into the analytics platform. We do not wait
for a nightly batch — the operational database publishes every change as it happens, and
the platform picks it up continuously.

**Meanwhile the order emits events** as it moves: accepted, packed, picked up by a rider,
delivered. Each one arrives separately, within seconds. The rider's phone also sends its
location every few seconds while the delivery is in progress.

**The platform scores the order for risk** using what it knows at that moment: how far
the customer is from the store, how busy the store is right now, how many items are in
the basket, what time of day it is, and how that store has been performing this week.

**The dispatcher sees it on a screen** — a queue of at-risk orders, worst first. They can
reassign a rider, extend the promise and tell the customer, or issue a credit up front.

**Whatever they choose is recorded.** And here is the part that matters: those decisions
feed back into the platform as data. Next month's risk model knows which interventions
actually worked. **The system learns from its own operators.**

**Afterwards**, the order joins the historical record — feeding the store scorecards, the
demand forecast, and the analysis of why on-time rates move.

---

## 4. How the platform is put together

Data moves through five stages. Each has one job, and the discipline of not letting them
blur is what keeps the whole thing trustworthy.

| Stage | Plain English | Why it exists separately |
|---|---|---|
| **Landing** | Data arrives, exactly as sent, and is never edited | If something goes wrong downstream, we can always go back to what actually arrived |
| **Cleaning** | Duplicates removed, types fixed, history preserved | The same event can legitimately arrive twice. Cleaning is where that is resolved — once, in one place |
| **Modelling** | Reshaped into the business's own vocabulary: orders, stores, riders, products | So a question like "on-time rate by store by hour" is one simple query, not a research project |
| **Laboratory** | Where the data science happens: experiments, model training | Deliberately unpoliced. Analysts need room to try things that do not work |
| **Serving** | The published, governed answers that apps and people are allowed to use | Nothing reaches a dashboard without passing quality checks first |

**The rule that keeps this honest: the laboratory is a sandbox, serving is a contract.**
Anyone can build anything in the laboratory. Nothing leaves it for the business until it
has passed automated quality tests. A dashboard can never accidentally be pointed at a
half-finished experiment.

---

## 5. Why the data arrives in so many different ways

Real businesses do not have one neat data source, and this platform deliberately
demonstrates that. Data arrives:

| From | Example | Arriving |
|---|---|---|
| The operational database | orders, customers, stock | continuously, within seconds |
| The rider and store apps | status changes, GPS | continuously, thousands per minute |
| Partner systems | third-party logistics settlement files | as files, on their schedule |
| Customer service | complaint PDFs and photographs | as documents |
| The public internet | weather at each store | on request |
| Data marketplace | reference datasets | shared, never copied |
| The business itself | category hierarchies, service-level targets | version-controlled, like code |

Fourteen distinct arrival routes in total. Each is the right answer to a different
constraint — you cannot make a partner change their file schedule, and you should not
copy a dataset someone is willing to share.

---

## 6. Trust and control

Three things make the platform safe to give people access to.

**Not everyone sees everything.** An analyst querying order data sees a scrambled version
of the customer's email address, and only the stores they are responsible for. The
protection is attached to the data itself, not to a particular report — so it cannot be
bypassed by querying a different way.

**The data checks itself.** Automated tests run continuously: are there orders without a
customer? Risk scores outside the possible range? Missing deliveries? A failure raises an
alert immediately rather than surfacing as a wrong number in a meeting three weeks later.

**Every cost is attributed.** Cloud analytics bills by the second, and it is easy to
build something that quietly costs more than it earns. Every job here is tagged, so at
any point we can say exactly what each part of the platform cost to run.

---

## 7. What it produces

An operations console with four views:

| View | Answers |
|---|---|
| **Operations** | How is each store performing, by hour? Where are deliveries concentrated on the map? |
| **Risk queue** | Which orders in flight are likely to be late, and what should I do about each one? |
| **Ask** | A guided way to answer business questions without writing code |
| **Data health** | Is the platform itself working, and can I trust today's numbers? |

Plus, running underneath: a demand forecast per store and category, automatic detection
of unusual patterns, and an explanation of *why* a metric moved rather than just that it
did.

---

## 8. Progress

| Stage | Status | What it means in business terms |
|---|---|---|
| Capability assessment | ✅ Done | Confirmed what the platform can and cannot do (see §9) |
| **Source systems** | ✅ Done | The operational database, its live change feed, and the app event stream are running and producing data |
| **Cloud storage and access** | ✅ **Done** | File storage created in the same region as the platform, with four separate areas for arriving files, archives, partner data and documents. The platform has been granted least-privilege access to each: it can write only to the archive, and read the rest |
| Platform foundation | ✅ Done | Analytics environment, nine data zones, three compute clusters, four access roles and a spending cap are live |
| Data arrival | 🟡 In progress | **12 of 14 routes live.** The same 79,663 app events reach the platform three different ways, so the cost and speed of each can be compared on identical data. Files arrive automatically when a partner drops them, on request, and as bulk backfills — including one that gained a new column mid-load and was absorbed without anyone changing a table definition. A logistics partner's files are read where they sit without being copied. An open-format archive has been written that other tools can read without going through this platform. Reference data now arrives from a spreadsheet-shaped dataframe and from version-controlled business constants. And one dataset is used without being ingested at all — read live from its publisher, with not one byte stored here |
| Cleaning and modelling | ⬜ | Turning raw arrivals into the business's vocabulary |
| Risk prediction | ⬜ | Training and deploying the late-delivery model |
| Forecasting and text analysis | ⬜ | Demand forecast, anomaly detection, complaint analysis |
| Operations console | ⬜ | The four-view application, including the learning feedback loop |
| Governance | ⬜ | Access controls, quality alerts, cost reporting |
| Sharing | ⬜ | Publishing data to partners and external consumers |

---

### Where things stand, in one sentence

**Twelve of the fourteen arrival routes are live, and nothing has moved past the
landing zone.** 376,508 records sit inside the platform exactly as they arrived.
Turning them into the business's own vocabulary is the next stage and none of it
has started.

| | |
|---|---|
| Records inside the analytics platform | **376,508** |
| Read where they sit, never copied | 2,800 |
| Used live from a publisher, never stored | 15,683 |
| Arrival routes connected | **12 of 14** |
| Records cleaned, modelled or served | **0** |
| Cloud spend confirmed | 3.78 of ~200 credits |

The same 79,663 app events arrive three separate ways on purpose: identical
input through three mechanisms is the only honest way to compare their cost and
speed. Removing those duplicates is the first job of the cleaning stage, not of
arrival.

**One route is worth singling out.** A public financial dataset is now queried
directly from its publisher's storage — nothing copied, nothing scheduled,
nothing to go stale. What it costs instead is a dependency: if the publisher
withdraws access, every query through it fails at once with no local copy to
fall back on. It also showed the honest limit of free data — the published rates
stop three months short of today, so the platform reports the most recent rate
available and says which day it came from, rather than quietly returning
nothing.

**What has not been done still matters more than what has.** There is still no
spending alert covering the continuous-loading services; the existing cap only
sees the query engine. Twelve routes have now run without it.

---

## 9. Two constraints worth knowing about

**The account cannot use the built-in AI text features.** They are disabled on this
account type. This affects how complaints are analysed: instead of a ready-made AI
service, we train our own classification model. More work to build, but the model is ours
— it can be inspected, versioned, and improved, which a black-box service cannot.

**The account has stronger governance features than expected.** Data protection can be
attached directly to columns and rows rather than approximated through restricted views.
We will build both approaches side by side and compare them, which turns a constraint
into a genuinely useful finding about how to protect data.

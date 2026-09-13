"""
Quick-commerce operations console.

Runs as Streamlit in Snowflake. Every query goes through SERVE, never MART,
LAB or OPS directly -- an app that reaches into an experimental schema pins
its shape, and Part 12's masking and row policies need one surface to attach
to rather than nine.

Packages: whatever CREATE STREAMLIT provides by default, which on this account
is python 3.11, snowflake-snowpark-python and streamlit 1.52. No
environment.yml, because the built-in charts cover everything here and a
declared dependency that buys nothing is a dependency that can break a deploy.
"""

import json

import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Quick-Commerce Console", layout="wide")

session = get_active_session()

# Aggregates over a few thousand rows on an XS warehouse. Five minutes of cache
# means a tab switch is free and a genuine refresh is still one click away.
CACHE_SECONDS = 300

# The routing threshold. Measured in p10_eval.sql, not chosen: every one of the
# classifier's 35 held-out errors falls below it and all 192 predictions above
# it were correct. It is duplicated in SERVE.COMPLAINT_TRIAGE, and if the model
# is retrained BOTH have to be re-derived from the new confidence quintiles.
CONFIDENCE_GATE = 0.235


@st.cache_data(ttl=CACHE_SECONDS, show_spinner=False)
def q(sql: str):
    return session.sql(sql).to_pandas()


def show_table(df):
    """st.dataframe, across whatever Streamlit this runtime actually has.

    Snowflake wraps st.dataframe in its own mixin -- a traceback here names
    DataFrameSelectorMixin, not Streamlit's DataFrameMixin -- and that wrapper
    does not accept hide_index or column_config even though the version string
    says 1.52. So this feature-detects by calling and catching TypeError rather
    than branching on st.__version__, which describes Streamlit and not what
    the wrapper forwards. TypeError is raised before anything renders, so
    falling back costs nothing and cannot double-draw.
    """
    try:
        st.dataframe(df, use_container_width=True)
    except TypeError:
        st.dataframe(df)


def toggle(label, value=False, help=None):
    """st.toggle where it exists, st.checkbox where it does not."""
    fn = getattr(st, "toggle", st.checkbox)
    try:
        return fn(label, value=value, help=help)
    except TypeError:
        return fn(label, value)


def log_action(subject_type: str, subject_id: str, action: str,
               note: str, context: dict) -> None:
    """Append one row to SERVE.ACTION_LOG.

    Bound parameters rather than string formatting. The note is free text typed
    by whoever is on shift, and building SQL out of it by concatenation is how
    an apostrophe in "rider didn't call" becomes a syntax error on a good day
    and something worse on a bad one.
    """
    session.sql(
        "INSERT INTO SERVE.ACTION_LOG "
        "  (SUBJECT_TYPE, SUBJECT_ID, ACTION, NOTE, CONTEXT) "
        "SELECT ?, ?, ?, ?, PARSE_JSON(?)",
        params=[subject_type, subject_id, action, note, json.dumps(context)],
    ).collect()


st.title("Quick-commerce operations console")
import sys

st.caption(
    "Reads QCOMMERCE.SERVE only. 8 dark stores, 20,000 orders over 60 days, "
    "300 complaints.  ·  streamlit %s, python %s"
    % (st.__version__, sys.version.split()[0])
)

ops_tab, risk_tab, complaints_tab, health_tab = st.tabs(
    ["Operations", "Risk queue", "Complaints", "Health"]
)

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------
with ops_tab:
    stores = q("SELECT DISTINCT STORE_CODE, CITY FROM SERVE.SLA_BY_STORE_HOUR "
               "ORDER BY STORE_CODE")
    picked = st.multiselect(
        "Stores", stores["STORE_CODE"].tolist(),
        default=stores["STORE_CODE"].tolist(),
        help="All 8 by default. Narrowing changes every figure on this tab.",
    )
    if not picked:
        st.info("Pick at least one store.")
    else:
        # Parameter binding is not available inside a cached helper that takes
        # only a string, so the list is validated against the values the
        # warehouse itself returned rather than trusted.
        allowed = set(stores["STORE_CODE"])
        safe = ", ".join("'%s'" % s for s in picked if s in allowed)

        totals = q(
            "SELECT SUM(ORDERS) AS ORDERS, SUM(BREACHED) AS BREACHED, "
            "       ROUND(100.0 * SUM(BREACHED) / NULLIF(SUM(ORDERS), 0), 2) AS BREACH_PCT, "
            "       ROUND(SUM(GROSS_PAISE) / 100000.0, 1) AS GROSS_THOUSAND_RUPEES "
            "FROM SERVE.SLA_BY_STORE_HOUR WHERE STORE_CODE IN (%s)" % safe
        ).iloc[0]

        a, b, c, d = st.columns(4)
        a.metric("Orders", "{:,}".format(int(totals["ORDERS"])))
        b.metric("Breached", "{:,}".format(int(totals["BREACHED"])))
        c.metric("Breach rate", "{:.2f}%".format(totals["BREACH_PCT"]))
        d.metric("Gross", "Rs {:,.0f}k".format(totals["GROSS_THOUSAND_RUPEES"]))

        st.subheader("Breach rate by local hour")
        st.caption(
            "Hours are IST. The data is stored in UTC, so an unconverted chart "
            "would put the evening peak at half past one in the afternoon."
        )
        by_hour = q(
            "SELECT IST_HOUR, "
            "       ROUND(100.0 * SUM(BREACHED) / NULLIF(SUM(ORDERS), 0), 2) AS BREACH_PCT, "
            "       SUM(ORDERS) AS ORDERS "
            "FROM SERVE.SLA_BY_STORE_HOUR WHERE STORE_CODE IN (%s) "
            "GROUP BY IST_HOUR ORDER BY IST_HOUR" % safe
        )
        st.bar_chart(by_hour, x="IST_HOUR", y="BREACH_PCT", height=260)

        left, right = st.columns(2)
        with left:
            st.subheader("By store")
            show_table(
                q("SELECT STORE_CODE, CITY, SUM(ORDERS) AS ORDERS, "
                  "       ROUND(100.0*SUM(BREACHED)/NULLIF(SUM(ORDERS),0),2) AS BREACH_PCT, "
                  "       ROUND(SUM(DELIVERED_SEC)/NULLIF(SUM(DELIVERED_N),0)/60.0,1) AS AVG_ACTUAL_MIN "
                  "FROM SERVE.SLA_STORE_HOUR_AGG WHERE STORE_CODE IN (%s) "
                  "GROUP BY STORE_CODE, CITY ORDER BY BREACH_PCT DESC" % safe))
        with right:
            st.subheader("Worst store-hours")
            st.caption("At least 20 orders, so a single late delivery cannot top the list.")
            show_table(
                q("SELECT STORE_CODE, IST_HOUR, SUM(ORDERS) AS ORDERS, "
                  "       ROUND(100.0*SUM(BREACHED)/NULLIF(SUM(ORDERS),0),2) AS BREACH_PCT "
                  "FROM SERVE.SLA_BY_STORE_HOUR WHERE STORE_CODE IN (%s) "
                  "GROUP BY STORE_CODE, IST_HOUR HAVING SUM(ORDERS) >= 20 "
                  "ORDER BY BREACH_PCT DESC LIMIT 12" % safe))

# ---------------------------------------------------------------------------
# Risk queue
# ---------------------------------------------------------------------------
with risk_tab:
    st.warning(
        "**This is a replay, not a live queue.** Every order below was "
        "delivered weeks ago. It is built from the model's TEST window -- days "
        "it never trained on -- so the scores are honest, and because the "
        "outcome already exists an action taken here can be scored against "
        "what actually happened. A live queue could only promise that."
    )

    capacity = st.slider(
        "Orders a dispatcher can act on this shift", 10, 500, 100, step=10,
        help="The queue is the top N by predicted breach probability.",
    )

    queue = q(
        "SELECT ORDER_ID, PLACED_TS, STORE_CODE, CITY, PROMISED_MIN, ITEM_COUNT, "
        "       ROUND(DIST_KM, 2) AS DIST_KM, STORE_LOAD_60M, IS_PEAK_HOUR, "
        "       P_BREACH, RISK_DECILE, ACTUAL_BREACHED "
        "FROM SERVE.ORDER_RISK ORDER BY P_BREACH DESC LIMIT %d" % int(capacity)
    )

    reveal = toggle(
        "Reveal outcomes", value=False,
        help="Hidden by default so the queue reads the way a dispatcher would "
             "see it, with the score and nothing else.",
    )

    if reveal:
        caught = int(queue["ACTUAL_BREACHED"].sum())
        total_breaches = int(q(
            "SELECT COUNT(*) AS N FROM SERVE.ORDER_RISK WHERE ACTUAL_BREACHED"
        ).iloc[0]["N"])
        pool = int(q("SELECT COUNT(*) AS N FROM SERVE.ORDER_RISK").iloc[0]["N"])
        a, b, c = st.columns(3)
        a.metric("Breaches in this queue", "{:,}".format(caught))
        b.metric("Share of all breaches caught",
                 "{:.1f}%".format(100.0 * caught / max(total_breaches, 1)))
        c.metric("Share of orders touched",
                 "{:.1f}%".format(100.0 * len(queue) / max(pool, 1)))
        st.caption(
            "Acting on %d of %d orders reaches %d of %d breaches. Untargeted, "
            "the same %d orders would have reached about %d."
            % (len(queue), pool, caught, total_breaches, len(queue),
               round(total_breaches * len(queue) / max(pool, 1)))
        )
        shown = queue
    else:
        shown = queue.drop(columns=["ACTUAL_BREACHED"])

    show_table(shown)

    st.subheader("Record a decision")
    st.caption(
        "This is the part that is not a dashboard. What gets decided here lands "
        "in SERVE.ACTION_LOG, and a later dbt model joins those decisions to "
        "outcomes so the app's own history becomes a feature for the next "
        "model run."
    )
    with st.form("order_action", clear_on_submit=True):
        f1, f2 = st.columns([1, 2])
        order_id = f1.selectbox("Order", queue["ORDER_ID"].tolist())
        action = f1.selectbox(
            "Action",
            ["REASSIGN_RIDER", "EXTEND_PROMISE", "ISSUE_CREDIT",
             "CALL_CUSTOMER", "NO_ACTION"],
        )
        note = f2.text_area("Note", placeholder="Why, in one line.", height=90)
        if st.form_submit_button("Log it"):
            row = queue[queue["ORDER_ID"] == order_id].iloc[0]
            log_action(
                "ORDER", str(order_id), action, note,
                {"p_breach": float(row["P_BREACH"]),
                 "risk_decile": int(row["RISK_DECILE"]),
                 "store_code": str(row["STORE_CODE"]),
                 "queue_size": int(capacity)},
            )
            st.success("Logged against order %s." % order_id)

# ---------------------------------------------------------------------------
# Complaints
# ---------------------------------------------------------------------------
with complaints_tab:
    bands = q(
        "SELECT ROUTING, COUNT(*) AS N, ROUND(MIN(CONFIDENCE),3) AS LO, "
        "       ROUND(MAX(CONFIDENCE),3) AS HI "
        "FROM SERVE.COMPLAINT_TRIAGE GROUP BY ROUTING ORDER BY ROUTING"
    ).set_index("ROUTING")

    a, b, c = st.columns(3)
    a.metric("Auto-routed", int(bands.loc["AUTO", "N"]) if "AUTO" in bands.index else 0)
    b.metric("Needs a human", int(bands.loc["REVIEW", "N"]) if "REVIEW" in bands.index else 0)
    c.metric("Confidence gate", "%.3f" % CONFIDENCE_GATE)

    st.info(
        "**The threshold is measured, not chosen.** On the 240 complaints the "
        "classifier never trained on, all 35 of its errors fall below %.3f and "
        "all 192 predictions above it were correct. So AUTO means the model has "
        "not yet been wrong in this band, and REVIEW is where every mistake it "
        "has ever made lives. Retraining invalidates the number."
        % CONFIDENCE_GATE
    )

    st.subheader("Review queue")
    review = q(
        "SELECT TICKET_ID, RAISED_TS, CHANNEL, CITY, STORE_CODE, "
        "       PREDICTED_REASON_CODE, CONFIDENCE, OWNING_TEAM, COMPLAINT_TEXT "
        "FROM SERVE.COMPLAINT_TRIAGE WHERE ROUTING = 'REVIEW' "
        "ORDER BY CONFIDENCE ASC"
    )
    show_table(review)

    st.subheader("Where the auto-routed ones went")
    st.bar_chart(
        q("SELECT PREDICTED_REASON_CODE, COUNT(*) AS N FROM SERVE.COMPLAINT_TRIAGE "
          "WHERE ROUTING = 'AUTO' GROUP BY PREDICTED_REASON_CODE ORDER BY N DESC"),
        x="PREDICTED_REASON_CODE", y="N", height=280,
    )

    with st.form("complaint_action", clear_on_submit=True):
        st.write("**Confirm or correct a review-queue classification**")
        g1, g2 = st.columns([1, 2])
        ticket = g1.selectbox("Ticket", review["TICKET_ID"].tolist()
                              if len(review) else ["-"])
        codes = q("SELECT REASON_CODE FROM RAW.COMPLAINT_REASON_CODE "
                  "ORDER BY REASON_CODE")["REASON_CODE"].tolist()
        corrected = g1.selectbox("Correct reason code", codes)
        note = g2.text_area("Note", placeholder="Optional.", height=90)
        if st.form_submit_button("Log it") and len(review):
            row = review[review["TICKET_ID"] == ticket].iloc[0]
            predicted = str(row["PREDICTED_REASON_CODE"])
            log_action(
                "COMPLAINT", str(ticket),
                "CONFIRM" if corrected == predicted else "RECLASSIFY",
                note,
                {"predicted": predicted, "corrected": corrected,
                 "confidence": float(row["CONFIDENCE"])},
            )
            st.success("Logged against %s." % ticket)

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------
with health_tab:
    health = q("SELECT CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, CHECK_TS "
               "FROM SERVE.DATA_HEALTH ORDER BY PASSED ASC, CHECK_TS DESC")
    failing = int((~health["PASSED"].astype(bool)).sum())

    a, b = st.columns(2)
    a.metric("Checks", len(health))
    # delta_color is passed only alongside a delta. Streamlit validates the two
    # together and this tab is the one that has to render when everything else
    # is broken -- it is where you look to find out what broke.
    if failing:
        b.metric("Failing", failing, delta="needs attention", delta_color="inverse")
    else:
        b.metric("Failing", 0)

    st.caption("Failing checks sort first. A check that has never run does not "
               "appear here at all, which is its own kind of silence.")
    show_table(health)

    st.subheader("Models")
    show_table(q("SELECT * FROM SERVE.MODEL_SCOREBOARD ORDER BY MODEL_NAME, SPLIT"))

    st.subheader("Decisions recorded")
    actions = q("SELECT LOGGED_AT, ACTED_BY, SUBJECT_TYPE, SUBJECT_ID, ACTION, NOTE "
                "FROM SERVE.ACTION_LOG ORDER BY LOGGED_AT DESC LIMIT 50")
    if len(actions):
        show_table(actions)
    else:
        st.caption("Nothing logged yet. Use the forms on the other two tabs.")

    st.subheader("Runtime")
    st.caption(
        "Reported by the app rather than read from INFORMATION_SCHEMA.PACKAGES. "
        "That table describes the UDF and procedure channel, which is a "
        "different environment from this one -- only the app can say what the "
        "app is running."
    )
    versions = q(
        "SELECT CURRENT_VERSION() AS SNOWFLAKE, CURRENT_WAREHOUSE() AS WAREHOUSE, "
        "       CURRENT_ROLE() AS ROLE, CURRENT_USER() AS USER_"
    ).iloc[0]
    st.code(
        "streamlit  %s\n"
        "python     %s\n"
        "snowflake  %s\n"
        "warehouse  %s\n"
        "role       %s\n"
        "user       %s"
        % (st.__version__, sys.version.split()[0], versions["SNOWFLAKE"],
           versions["WAREHOUSE"], versions["ROLE"], versions["USER_"]),
        language="text",
    )

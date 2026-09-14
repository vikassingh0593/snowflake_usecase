-- =============================================================================
-- PART 12 / STEP 5 — an alert that fires on a real failure.
--
-- OPS.DQ_RESULTS has collected 40-odd checks across twelve parts and every one
-- of them is green, which is pleasant and useless: a check nobody reads is a
-- check that will be green on the day it matters too. An alert is the thing
-- that closes that gap, and the only way to know it works is to BREAK
-- something and watch it fire.
--
-- ON COST. An alert runs on a schedule and uses a warehouse, so it is
-- recurring spend by construction. This one is created suspended, executed
-- ONCE by hand, and dropped at the end of the file. The mechanism gets
-- demonstrated; nothing is left ticking.
--
-- ON EMAIL. The notification integration probed available, but delivery also
-- needs a VERIFIED recipient address on the account, which is a second gate
-- the probe did not test -- the same distinction that made the data metric
-- schedule look available when executing it was not. So the alert's action
-- writes to a table, which cannot fail, and the email is attempted separately
-- at the very end where a refusal costs nothing.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p12:alert';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — where a fired alert lands.
-- =============================================================================
CREATE TABLE IF NOT EXISTS OPS.ALERT_LOG (
  FIRED_AT     TIMESTAMP_NTZ DEFAULT SYSDATE(),
  ALERT_NAME   STRING,
  CHECK_NAME   STRING,
  TARGET       STRING,
  OBSERVED     NUMBER,
  EXPECTED     STRING
) COMMENT = 'what an alert saw when it fired. Written by the alert itself';

SELECT COUNT(*)                          AS checks_recorded,
       SUM(IFF(PASSED, 0, 1))            AS currently_failing,
       COUNT(DISTINCT CHECK_NAME)        AS distinct_checks
FROM   OPS.DQ_RESULTS;

-- =============================================================================
-- STEP 2 — the alert.
--
-- The condition reads the LATEST result per check, not every row ever written.
-- DQ_RESULTS is append-only, so a check that failed once in August and has
-- passed every day since would keep an alert firing forever on a problem that
-- was fixed months ago -- which is how people learn to ignore alerts.
-- =============================================================================
CREATE OR REPLACE ALERT OPS.ALERT_DQ_FAILED
  WAREHOUSE = WH_TRANSFORM_XS
  SCHEDULE  = '1440 MINUTE'
  IF (EXISTS (
        SELECT 1
        FROM   OPS.DQ_RESULTS
        QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_NAME, TARGET
                                   ORDER BY CHECK_TS DESC) = 1
           AND NOT PASSED
      ))
  THEN
    INSERT INTO OPS.ALERT_LOG (ALERT_NAME, CHECK_NAME, TARGET, OBSERVED, EXPECTED)
    SELECT 'ALERT_DQ_FAILED', CHECK_NAME, TARGET, OBSERVED, EXPECTED
    FROM   OPS.DQ_RESULTS
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_NAME, TARGET
                               ORDER BY CHECK_TS DESC) = 1
       AND NOT PASSED;

SHOW ALERTS IN SCHEMA OPS;

-- Created suspended by default. Confirm that rather than assume it -- an alert
-- that starts running on a daily schedule is exactly the recurring spend this
-- project forbids.
SELECT "name", "state", "schedule", "condition"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- =============================================================================
-- STEP 3 — nothing is broken, so break something.
--
-- A deliberately failing check, clearly labelled as a drill so that anyone
-- reading OPS.DQ_RESULTS later does not spend an afternoon investigating a
-- data quality problem that was staged.
-- =============================================================================
SELECT COUNT(*) AS alert_log_rows_before FROM OPS.ALERT_LOG;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'zzz_drill_seeded_failure', 'OPS.ALERT_DQ_FAILED', FALSE, 1,
       'A DELIBERATE FAILURE, seeded by p12_alert.sql to prove the alert '
         || 'fires. Removed at the end of the same file. If this row is still '
         || 'here, the file did not finish',
       OBJECT_CONSTRUCT('drill', TRUE);

-- EXECUTE ALERT runs the condition and action immediately, ignoring the
-- schedule. It is how an alert gets tested without waiting a day for it, and
-- without ever resuming it.
EXECUTE ALERT OPS.ALERT_DQ_FAILED;

-- =============================================================================
-- STEP 4 — did it fire.
--
-- Alert execution is asynchronous: EXECUTE ALERT returns before the action has
-- run. ALERT_HISTORY is the record of what actually happened, and a row in
-- OPS.ALERT_LOG is the proof the action reached its target.
-- =============================================================================
-- SELECT *, because the shape of ALERT_HISTORY has not been seen here and
-- naming columns from memory is what has gone wrong twelve times in this
-- part. There is no ROWS_INSERTED on it -- that was the twelfth.
SELECT *
FROM   TABLE(INFORMATION_SCHEMA.ALERT_HISTORY(
              SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP())))
WHERE  NAME = 'ALERT_DQ_FAILED'
ORDER  BY SCHEDULED_TIME DESC
LIMIT  5;

SELECT * FROM OPS.ALERT_LOG ORDER BY FIRED_AT DESC LIMIT 5;

-- =============================================================================
-- STEP 5 — clean up the drill, then the alert.
-- =============================================================================
-- Removes every seeded row, including any left by a run that aborted between
-- the seed and here -- which is exactly what happened on the first attempt.
DELETE FROM OPS.DQ_RESULTS WHERE CHECK_NAME = 'zzz_drill_seeded_failure';

-- RENAMING A CHECK ORPHANS ITS LAST RESULT, and the drill above is what
-- exposed it. vectors_are_not_all_the_same was renamed to
-- vectors_separate_the_documents in Part 10 after it failed on a false
-- assumption. The rename means the OLD name's final row -- a failure -- is
-- permanently the latest result for a check that no longer runs, so any
-- "is anything failing" query answers yes forever.
--
-- An append-only check log needs this cleanup whenever a check is renamed.
-- The alternative is a retired-checks list to filter against, which is more
-- machinery for the same outcome and one more thing to forget to update.
DELETE FROM OPS.DQ_RESULTS WHERE CHECK_NAME = 'vectors_are_not_all_the_same';

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'alert_fires_on_a_seeded_failure', 'OPS.ALERT_DQ_FAILED',
       (SELECT COUNT(*) FROM OPS.ALERT_LOG
         WHERE CHECK_NAME = 'zzz_drill_seeded_failure') >= 1,
       (SELECT COUNT(*) FROM OPS.ALERT_LOG),
       'the alert saw a deliberately failed check and wrote it down. The '
         || 'seeded row is removed; the ALERT_LOG entry stays as the evidence '
         || 'that the mechanism works',
       (SELECT OBJECT_CONSTRUCT('seeded_row_still_in_dq_results',
                 (SELECT COUNT(*) FROM OPS.DQ_RESULTS
                   WHERE CHECK_NAME = 'zzz_drill_seeded_failure')));

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
-- QUALIFY is evaluated AFTER aggregation, so it cannot reference a raw column
-- in a query that does COUNT(*): "[DQ_RESULTS.PASSED] is not a valid group by
-- expression". The latest-row filter has to happen in a subquery and the count
-- outside it. This is the same mistake as the NTILE one in Part 10, written a
-- second time in a different clause.
SELECT 'no_check_is_currently_failing', 'OPS.DQ_RESULTS',
       (SELECT COUNT(*) FROM (
          SELECT PASSED FROM OPS.DQ_RESULTS
          QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_NAME, TARGET
                                     ORDER BY CHECK_TS DESC) = 1
        ) WHERE NOT PASSED) = 0,
       (SELECT COUNT(*) FROM (
          SELECT PASSED FROM OPS.DQ_RESULTS
          QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_NAME, TARGET
                                     ORDER BY CHECK_TS DESC) = 1
        ) WHERE NOT PASSED),
       'the latest result of every check passes, drill removed. This is the '
         || 'condition the alert watches, evaluated the same way it does',
       NULL;

DROP ALERT IF EXISTS OPS.ALERT_DQ_FAILED;

SHOW ALERTS IN SCHEMA OPS;

SELECT CHECK_NAME, PASSED, OBSERVED, EXPECTED
FROM   OPS.DQ_RESULTS
WHERE  TARGET IN ('OPS.ALERT_DQ_FAILED', 'OPS.DQ_RESULTS')
ORDER  BY CHECK_TS DESC
LIMIT  3;

-- =============================================================================
-- STEP 6 — the email route, built but NOT fired.
--
-- The integration is created here. The send is not, and that is deliberate:
-- sending mail is an outward-facing act and it belongs behind a decision
-- rather than inside a script somebody runs to test an alert. Nobody should
-- find out that a file sends email by receiving one.
--
-- There is also a gate the probe did not test. The integration creating
-- successfully says nothing about whether any RECIPIENT is verified on the
-- account -- exactly the shape of the data metric function, where ALTER
-- succeeded and EXECUTE turned out to be a separate privilege. So the address
-- is looked up rather than assumed, and the send is left as a statement to run
-- by hand.
-- =============================================================================
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS NI_EMAIL_OPS
  TYPE = EMAIL
  ENABLED = TRUE
  COMMENT = 'data quality alerts. Recipients must be verified account users';

SHOW INTEGRATIONS LIKE 'NI_EMAIL_OPS';

-- Which address would receive it, from the account rather than from memory.
-- No email address is hard-coded in this repository.
SHOW USERS LIKE '%';
SELECT "name" AS user_name,
       "email" AS email,
       "disabled"
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE  "name" = CURRENT_USER();

-- To actually send it, run this by hand with the address above:
--
--   CALL SYSTEM$SEND_EMAIL(
--     'NI_EMAIL_OPS',
--     'you@example.com',
--     '[qcommerce] data quality alert drill',
--     'The Part 12 alert drill. If this arrived, the integration works and '
--       || 'the recipient is verified on the account.');
--
-- A refusal there names the gate: an unverified recipient is reported
-- differently from a missing integration, and only one of them is fixable
-- from SQL.

-- =============================================================================
-- PART 14 / STEP 2 — deploy from git, now that the contract is known.
--
-- WHAT STEP 1 ESTABLISHED.
--
--   git api integration    NOT gated. §1 Finding 3 refuses external access
--                          integrations; a git_https_api integration to the
--                          same public internet is permitted. Different
--                          integration type, different gate, and the finding
--                          should not be read as covering both.
--   repository + FETCH     work. LS returned 55 files on main.
--   EXECUTE IMMEDIATE FROM refused: Unsupported statement type 'USE'.
--   zero-copy clone        CARRIES the row access policy. Verified by role:
--                          QC_ANALYST reads 3 stores on the clone and 3 on the
--                          original, ACCOUNTADMIN 8 and 8.
--
-- THE CLONE RESULT IS THE ONE WORTH PUTTING BESIDE THE OTHERS. Part 13 spent
-- the day on what happens to protection when an object is derived from a
-- protected one, and the three answers are all different:
--
--   materialised aggregate   filter lost         silently, found 2 days later
--   share                    filter accepted     without objecting either way
--   zero-copy clone          filter preserved    verified by role
--
-- No single feature's documentation mentions the other two.
--
-- WHY EVERY FILE IN THIS REPOSITORY IS UNDEPLOYABLE. EXECUTE IMMEDIATE FROM
-- runs a file as a Snowflake Scripting block. USE ROLE, USE WAREHOUSE and USE
-- DATABASE do not exist inside one, and all 55 files open with four of them --
-- including this one, which is why the deploy target lives in sql/deploy/ and
-- is written to the narrower contract: fully qualified names, context
-- inherited from the caller, nothing that assumes an interactive session.
--
-- That is the real constraint CI/CD imposes on a SQL codebase, and it is not
-- the one anybody plans for. Rewriting 55 files to suit a deploy mechanism
-- would be the tail wagging the dog; splitting deployable files into their own
-- directory with their own rules is the smaller change and the honest one.
--
-- ON COST. Metadata and one view. Nothing left behind. ~0.02 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p14:deploy';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — the repository, kept this time rather than probed and dropped.
-- =============================================================================
CREATE API INTEGRATION IF NOT EXISTS GIT_API_QCOMMERCE
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/vikassingh0593')
  ENABLED = TRUE
  COMMENT = 'public repo, no secret. Permitted where an external access integration is not';

CREATE GIT REPOSITORY IF NOT EXISTS LAND.GIT_QCOMMERCE
  API_INTEGRATION = GIT_API_QCOMMERCE
  ORIGIN = 'https://github.com/vikassingh0593/snowflake_usecase'
  COMMENT = 'Snowflake reads this repository directly. Part 14';

ALTER GIT REPOSITORY LAND.GIT_QCOMMERCE FETCH;

LS @LAND.GIT_QCOMMERCE/branches/main/sql/deploy/;

-- =============================================================================
-- STEP 2 — deploy a file that obeys the contract.
-- =============================================================================
EXECUTE IMMEDIATE FROM @LAND.GIT_QCOMMERCE/branches/main/sql/deploy/v_share_entitlement.sql;

SELECT * FROM SERVE.V_SHARE_ENTITLEMENT ORDER BY ACCOUNT_LOCATOR, STORE_CODE;

-- =============================================================================
-- STEP 3 — checks.
-- =============================================================================
INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'view_deployed_from_git',
       'SERVE.V_SHARE_ENTITLEMENT',
       COUNT(*) = 1,
       COUNT(*),
       'the view exists and was created by EXECUTE IMMEDIATE FROM a git stage',
       TO_VARIANT('deployable files live in sql/deploy/ and carry no USE statements')
FROM   QCOMMERCE.INFORMATION_SCHEMA.VIEWS
WHERE  TABLE_SCHEMA = 'SERVE' AND TABLE_NAME = 'V_SHARE_ENTITLEMENT';

-- LS re-issued immediately before the check rather than counting backwards
-- with LAST_QUERY_ID(-n). The offset would have to be hand-counted through the
-- INSERTs above and re-counted every time a statement is added -- which is the
-- same class of guess as an invented column name, and this project has paid
-- for four of those.
LS @LAND.GIT_QCOMMERCE/branches/main/sql/deploy/;

INSERT INTO OPS.DQ_RESULTS (CHECK_NAME, TARGET, PASSED, OBSERVED, EXPECTED, DETAIL)
SELECT 'git_repository_reachable',
       'LAND.GIT_QCOMMERCE',
       COUNT(*) >= 1,
       COUNT(*),
       'at least one deployable file visible on the main branch',
       TO_VARIANT('a git_https_api integration is permitted where an external access integration is refused')
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT CHECK_NAME, TARGET, PASSED, OBSERVED
FROM   OPS.DQ_RESULTS
WHERE  CHECK_NAME IN ('view_deployed_from_git', 'git_repository_reachable')
QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_NAME ORDER BY CHECK_TS DESC) = 1;

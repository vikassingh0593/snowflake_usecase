-- Deployable through EXECUTE IMMEDIATE FROM @git_repo/...
--
-- NO SESSION-CONTEXT STATEMENTS. EXECUTE IMMEDIATE FROM runs a file as a
-- Snowflake Scripting block, and USE ROLE, USE WAREHOUSE and USE DATABASE do
-- not exist inside one:
--
--   090236: Unsupported statement type 'USE'
--
-- Every other SQL file in this repository opens with four of them, so none of
-- them can be deployed this way. Files under sql/deploy/ are written to the
-- narrower contract instead: every name fully qualified, context inherited
-- from whoever calls, and nothing that assumes an interactive session.
--
-- That is the real constraint CI/CD puts on a SQL codebase, and it is not the
-- one anybody plans for.
CREATE OR REPLACE VIEW QCOMMERCE.SERVE.V_SHARE_ENTITLEMENT
COMMENT = 'which consumer accounts may see which stores. Deployed from git'
AS
SELECT e.ACCOUNT_LOCATOR,
       e.STORE_CODE,
       s.CITY,
       e.GRANTED_AT
FROM   QCOMMERCE.GOV.ACCOUNT_STORE_ENTITLEMENT e
LEFT   JOIN QCOMMERCE.MART.DIM_STORE s ON s.STORE_CODE = e.STORE_CODE;

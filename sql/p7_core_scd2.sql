-- =============================================================================
-- sql/p7_core_scd2.sql — Part 7b: streams and SCD2.
--
-- The chain this builds, and why each link exists:
--
--   RAW.CDC_PRODUCTS   every version of every row, as captured
--        |  MERGE, keyed on product_id
--   CORE.PRODUCT       one row per product, current state only
--        |  STANDARD STREAM -- before AND after images
--   CORE.DIM_PRODUCT   one row per product PER VERSION, with validity dates
--
-- The middle step is why the stream is worth having. CORE.PRODUCT is a MERGE
-- target rather than a CREATE OR REPLACE, so a standard stream on it survives
-- the refresh and reports exactly which rows changed and what they were before.
-- Rebuilding the table instead would invalidate the stream and force SCD2 to
-- diff the whole dimension every run.
--
-- PREREQUISITE: APPLY=1 bash scripts/p7_mutate_source.sh. Until then every CDC
-- row is op = 'r' with before = null, and there is no history to version.
--
-- COST: resumes WH_TRANSFORM_XS. A few hundred rows through a MERGE and a
-- stream. Under 0.01 credits.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_XS;
ALTER SESSION SET QUERY_TAG = 'p07:core_scd2';
USE DATABASE QCOMMERCE;

-- =============================================================================
-- STEP 1 — did the updates actually arrive?
--
-- op = 'u' rows are the whole point. If this shows only 'r', the mutation
-- script has not run or the connector has not caught up, and everything below
-- would produce an SCD2 table with exactly one version per product -- which
-- looks like success.
-- =============================================================================
SELECT 'products'  AS src, RECORD_CONTENT:op::STRING AS op, COUNT(*) AS n FROM RAW.CDC_PRODUCTS  GROUP BY 1,2
UNION ALL
SELECT 'customers',       RECORD_CONTENT:op::STRING,        COUNT(*)    FROM RAW.CDC_CUSTOMERS GROUP BY 1,2
UNION ALL
SELECT 'riders',          RECORD_CONTENT:op::STRING,        COUNT(*)    FROM RAW.CDC_RIDERS    GROUP BY 1,2
UNION ALL
SELECT 'inventory',       RECORD_CONTENT:op::STRING,        COUNT(*)    FROM RAW.CDC_INVENTORY GROUP BY 1,2
ORDER BY 1, 3 DESC;

-- One update, both images. REPLICA IDENTITY FULL on every source table is what
-- puts the complete previous row in `before`; the Postgres default of
-- REPLICA IDENTITY DEFAULT would carry only the primary key and SCD2 would have
-- nothing to compare.
SELECT RECORD_CONTENT:before:product_id::NUMBER  AS product_id,
       RECORD_CONTENT:before:price_paise::NUMBER AS price_was,
       RECORD_CONTENT:after:price_paise::NUMBER  AS price_now,
       RECORD_CONTENT:op::STRING                 AS op
FROM   RAW.CDC_PRODUCTS
WHERE  RECORD_CONTENT:op::STRING = 'u'
ORDER  BY 1
LIMIT  5;

-- =============================================================================
-- STEP 2 — the standard stream. First of the five stream types.
--
-- Standard, not append-only: it carries METADATA$ACTION = DELETE rows alongside
-- INSERT ones, and METADATA$ISUPDATE marks the pair that together represent one
-- update. That DELETE row IS the before-image, and it is the only reason a
-- standard stream costs more than an append-only one.
--
-- Created BEFORE the MERGE. A stream reports changes from the moment it exists,
-- which is the lesson mechanism 10 paid for: create it after and it is empty.
-- =============================================================================
CREATE STREAM IF NOT EXISTS CORE.STR_PRODUCT_CHANGES ON TABLE CORE.PRODUCT;

SELECT COUNT(*) AS pending_before_merge FROM CORE.STR_PRODUCT_CHANGES;

-- =============================================================================
-- STEP 3 — refresh CORE.PRODUCT incrementally.
--
-- MERGE, not CREATE OR REPLACE. Replacing the table would drop every row and
-- re-insert it, so the stream would report 200 changes instead of 20, and
-- rebuilding is what invalidates a stream in the first place.
-- =============================================================================
MERGE INTO CORE.PRODUCT t
USING (
  SELECT
    RECORD_CONTENT:after:product_id::NUMBER                   AS PRODUCT_ID,
    RECORD_CONTENT:after:sku::STRING                          AS SKU,
    RECORD_CONTENT:after:name::STRING                         AS PRODUCT_NAME,
    RECORD_CONTENT:after:category_l1::STRING                  AS CATEGORY_L1,
    RECORD_CONTENT:after:category_l2::STRING                  AS CATEGORY_L2,
    RECORD_CONTENT:after:category_l3::STRING                  AS CATEGORY_L3,
    RECORD_CONTENT:after:price_paise::NUMBER                  AS PRICE_PAISE,
    RECORD_CONTENT:after:is_active::BOOLEAN                   AS IS_ACTIVE,
    TO_TIMESTAMP_NTZ(RECORD_CONTENT:after:updated_at::STRING) AS UPDATED_AT,
    TO_TIMESTAMP_NTZ(RECORD_CONTENT:ts_ms::NUMBER, 3)         AS CDC_TS,
    RECORD_CONTENT:op::STRING                                 AS OP
  FROM RAW.CDC_PRODUCTS
  QUALIFY ROW_NUMBER() OVER (
            PARTITION BY COALESCE(RECORD_CONTENT:after:product_id, RECORD_CONTENT:before:product_id)::NUMBER
            ORDER BY RECORD_CONTENT:ts_ms::NUMBER DESC, RECORD_METADATA:offset::NUMBER DESC) = 1
) s
ON t.PRODUCT_ID = s.PRODUCT_ID
WHEN MATCHED AND s.OP <> 'd' AND (
       t.PRICE_PAISE IS DISTINCT FROM s.PRICE_PAISE
    OR t.IS_ACTIVE   IS DISTINCT FROM s.IS_ACTIVE
    OR t.PRODUCT_NAME IS DISTINCT FROM s.PRODUCT_NAME
    OR t.CATEGORY_L3 IS DISTINCT FROM s.CATEGORY_L3)
  THEN UPDATE SET
       t.PRODUCT_NAME = s.PRODUCT_NAME, t.CATEGORY_L1 = s.CATEGORY_L1,
       t.CATEGORY_L2  = s.CATEGORY_L2,  t.CATEGORY_L3 = s.CATEGORY_L3,
       t.PRICE_PAISE  = s.PRICE_PAISE,  t.IS_ACTIVE   = s.IS_ACTIVE,
       t.UPDATED_AT   = s.UPDATED_AT,   t.CDC_TS      = s.CDC_TS,
       t.CONFORMED_TS = CURRENT_TIMESTAMP()
WHEN MATCHED AND s.OP = 'd' THEN DELETE
WHEN NOT MATCHED AND s.OP <> 'd' THEN
  INSERT (PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY_L1, CATEGORY_L2, CATEGORY_L3,
          PRICE_PAISE, IS_ACTIVE, UPDATED_AT, CDC_TS, CONFORMED_TS)
  VALUES (s.PRODUCT_ID, s.SKU, s.PRODUCT_NAME, s.CATEGORY_L1, s.CATEGORY_L2, s.CATEGORY_L3,
          s.PRICE_PAISE, s.IS_ACTIVE, s.UPDATED_AT, s.CDC_TS, CURRENT_TIMESTAMP());

-- IS DISTINCT FROM, not <>. A NULL on either side makes <> return NULL, which
-- is not TRUE, so a column going from a value to NULL would never be seen as a
-- change and the row would silently stop updating.

-- =============================================================================
-- STEP 4 — what the stream saw.
--
-- An update appears as TWO rows: METADATA$ACTION = DELETE carrying the old
-- values and INSERT carrying the new, both with METADATA$ISUPDATE = TRUE.
-- =============================================================================
SELECT METADATA$ACTION   AS action,
       METADATA$ISUPDATE AS is_update,
       COUNT(*)          AS n
FROM   CORE.STR_PRODUCT_CHANGES
GROUP  BY 1, 2
ORDER  BY 1, 2;

SELECT PRODUCT_ID, SKU, PRICE_PAISE, METADATA$ACTION AS action, METADATA$ISUPDATE AS is_update
FROM   CORE.STR_PRODUCT_CHANGES
ORDER  BY PRODUCT_ID, METADATA$ACTION
LIMIT  6;

-- =============================================================================
-- STEP 5 — SCD2, driven by the stream.
--
-- The two-part MERGE. A single MERGE cannot both close the outgoing version and
-- open the incoming one, because both target the same business key and a MERGE
-- may touch a target row only once. The standard answer is to feed it a source
-- that contains each change twice under different join keys:
--
--   merge_key = PRODUCT_ID -> matches the open row, closes it
--   merge_key = NULL       -> matches nothing, inserts the new version
--
-- dbt snapshots do this too. Writing it by hand is the point: §8 lists MERGE for
-- "SCD2 upserts where dbt snapshots do not fit", and this is that shape.
-- =============================================================================
CREATE TABLE IF NOT EXISTS CORE.DIM_PRODUCT (
  PRODUCT_SK    STRING,
  PRODUCT_ID    NUMBER,
  SKU           STRING,
  PRODUCT_NAME  STRING,
  CATEGORY_L1   STRING,
  CATEGORY_L2   STRING,
  CATEGORY_L3   STRING,
  PRICE_PAISE   NUMBER,
  IS_ACTIVE     BOOLEAN,
  VALID_FROM    TIMESTAMP_NTZ,
  VALID_TO      TIMESTAMP_NTZ,
  IS_CURRENT    BOOLEAN,
  ROW_HASH      STRING
);

-- Seed the dimension on first run: every current product becomes version 1,
-- open-ended. Guarded so a re-run does not duplicate it.
INSERT INTO CORE.DIM_PRODUCT
SELECT MD5(p.PRODUCT_ID::STRING || '|' || p.CDC_TS::STRING) AS PRODUCT_SK,
       p.PRODUCT_ID, p.SKU, p.PRODUCT_NAME,
       p.CATEGORY_L1, p.CATEGORY_L2, p.CATEGORY_L3,
       p.PRICE_PAISE, p.IS_ACTIVE,
       '1900-01-01'::TIMESTAMP_NTZ AS VALID_FROM,
       NULL                        AS VALID_TO,
       TRUE                        AS IS_CURRENT,
       MD5(CONCAT_WS('|', p.PRODUCT_NAME, p.CATEGORY_L3,
                          p.PRICE_PAISE::STRING, p.IS_ACTIVE::STRING)) AS ROW_HASH
FROM   CORE.PRODUCT p
WHERE  NOT EXISTS (SELECT 1 FROM CORE.DIM_PRODUCT);

-- The versioning MERGE reads CORE.PRODUCT, not the stream. The stream proves
-- WHICH rows changed and what they were; the dimension needs the full current
-- state to compare hashes against, and a SELECT on a stream does not advance
-- its offset anyway -- only a DML does.
MERGE INTO CORE.DIM_PRODUCT d
USING (
  SELECT PRODUCT_ID AS MERGE_KEY, * FROM CORE.PRODUCT
  UNION ALL
  SELECT NULL       AS MERGE_KEY, p.*
  FROM   CORE.PRODUCT p
  JOIN   CORE.DIM_PRODUCT c
    ON   c.PRODUCT_ID = p.PRODUCT_ID AND c.IS_CURRENT
   AND   c.ROW_HASH <> MD5(CONCAT_WS('|', p.PRODUCT_NAME, p.CATEGORY_L3,
                                          p.PRICE_PAISE::STRING, p.IS_ACTIVE::STRING))
) s
ON d.PRODUCT_ID = s.MERGE_KEY AND d.IS_CURRENT
WHEN MATCHED AND d.ROW_HASH <> MD5(CONCAT_WS('|', s.PRODUCT_NAME, s.CATEGORY_L3,
                                                  s.PRICE_PAISE::STRING, s.IS_ACTIVE::STRING))
  THEN UPDATE SET d.VALID_TO = s.CDC_TS, d.IS_CURRENT = FALSE
WHEN NOT MATCHED THEN
  INSERT (PRODUCT_SK, PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY_L1, CATEGORY_L2,
          CATEGORY_L3, PRICE_PAISE, IS_ACTIVE, VALID_FROM, VALID_TO, IS_CURRENT, ROW_HASH)
  VALUES (MD5(s.PRODUCT_ID::STRING || '|' || s.CDC_TS::STRING),
          s.PRODUCT_ID, s.SKU, s.PRODUCT_NAME, s.CATEGORY_L1, s.CATEGORY_L2,
          s.CATEGORY_L3, s.PRICE_PAISE, s.IS_ACTIVE, s.CDC_TS, NULL, TRUE,
          MD5(CONCAT_WS('|', s.PRODUCT_NAME, s.CATEGORY_L3,
                             s.PRICE_PAISE::STRING, s.IS_ACTIVE::STRING)));

-- =============================================================================
-- STEP 6 — verify the history.
-- =============================================================================
SELECT COUNT(*)                                   AS dim_rows,
       COUNT(DISTINCT PRODUCT_ID)                 AS products,
       SUM(IFF(IS_CURRENT, 1, 0))                 AS current_rows,
       SUM(IFF(NOT IS_CURRENT, 1, 0))             AS closed_rows
FROM   CORE.DIM_PRODUCT;

-- Exactly one current version per product. More than one is the classic SCD2
-- bug and it is invisible until a fact joins to the dimension and doubles.
SELECT COUNT(*) AS products_with_multiple_current
FROM  (SELECT PRODUCT_ID FROM CORE.DIM_PRODUCT WHERE IS_CURRENT
       GROUP BY PRODUCT_ID HAVING COUNT(*) > 1);

-- No gaps and no overlaps in the validity ranges.
SELECT COUNT(*) AS overlapping_versions
FROM   CORE.DIM_PRODUCT a
JOIN   CORE.DIM_PRODUCT b
  ON   a.PRODUCT_ID = b.PRODUCT_ID
 AND   a.PRODUCT_SK <> b.PRODUCT_SK
 AND   a.VALID_FROM < COALESCE(b.VALID_TO, '9999-12-31'::TIMESTAMP_NTZ)
 AND   COALESCE(a.VALID_TO, '9999-12-31'::TIMESTAMP_NTZ) > b.VALID_FROM;

-- The price history, which is the thing SCD2 exists to answer.
SELECT PRODUCT_ID, SKU, PRICE_PAISE, VALID_FROM, VALID_TO, IS_CURRENT
FROM   CORE.DIM_PRODUCT
WHERE  PRODUCT_ID IN (SELECT PRODUCT_ID FROM CORE.DIM_PRODUCT
                      GROUP BY PRODUCT_ID HAVING COUNT(*) > 1)
ORDER  BY PRODUCT_ID, VALID_FROM
LIMIT  10;

-- =============================================================================
-- TEARDOWN
-- =============================================================================
-- DROP TABLE  IF EXISTS QCOMMERCE.CORE.DIM_PRODUCT;
-- DROP STREAM IF EXISTS QCOMMERCE.CORE.STR_PRODUCT_CHANGES;

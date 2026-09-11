#!/usr/bin/env bash
# =============================================================================
# scripts/p7_mutate_source.sh — change the source so CDC has something to say.
#
# Every row landed so far is op = 'r': a snapshot read, with before = null.
# SCD2 versions a dimension by comparing what a row WAS against what it BECAME,
# and a snapshot has no "was". Without a real UPDATE there is nothing to version
# and any history built would be synthesised rather than captured -- which is
# exactly the thing CDC exists to avoid.
#
# Deterministic by modulo, not random, so a second run changes the same rows and
# the SCD2 result is reproducible.
#
#   bash scripts/p7_mutate_source.sh          dry run, counts only
#   APPLY=1 bash scripts/p7_mutate_source.sh  apply the changes
#
# Deletes go to inventory. products is referenced by order_items and inventory,
# so deleting one raises a foreign key violation; inventory has no dependents.
#
# COST: local Postgres plus ~50 CDC events over Snowpipe Streaming. Rounds to
# nothing.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

APPLY="${APPLY:-0}"
PSQL="docker exec -i qc-postgres psql -U postgres -d qcommerce"

if [ "$APPLY" != "1" ]; then
  echo "DRY RUN. Rows that WOULD change:"
  $PSQL -c "
    SELECT 'products.price_paise +15%' AS change, COUNT(*) FROM qc.products WHERE product_id % 10 = 0
    UNION ALL SELECT 'customers.segment promoted', COUNT(*) FROM qc.customers WHERE customer_id % 33 = 0
    UNION ALL SELECT 'riders.is_active -> false',  COUNT(*) FROM qc.riders    WHERE rider_id % 12 = 0
    UNION ALL SELECT 'inventory rows deleted',     COUNT(*) FROM qc.inventory
              WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM qc.inventory) AND product_id % 20 = 0;"
  echo
  echo "To apply:  APPLY=1 bash scripts/p7_mutate_source.sh"
  exit 0
fi

echo "== before"
$PSQL -c "
  SELECT product_id, sku, price_paise FROM qc.products
  WHERE product_id % 10 = 0 ORDER BY product_id LIMIT 5;"

echo "== applying"
$PSQL -v ON_ERROR_STOP=1 -c "
  UPDATE qc.products
     SET price_paise = ROUND(price_paise * 1.15), updated_at = now()
   WHERE product_id % 10 = 0;

  UPDATE qc.customers
     SET segment = CASE segment WHEN 'REGULAR' THEN 'PLUS'
                                WHEN 'PLUS'    THEN 'PREMIUM'
                                ELSE 'PLUS' END
   WHERE customer_id % 33 = 0;

  UPDATE qc.riders SET is_active = false WHERE rider_id % 12 = 0;

  DELETE FROM qc.inventory
   WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM qc.inventory)
     AND product_id % 20 = 0;"

echo "== after"
$PSQL -c "
  SELECT product_id, sku, price_paise FROM qc.products
  WHERE product_id % 10 = 0 ORDER BY product_id LIMIT 5;"

echo
echo "== waiting for the change events to reach Snowflake"
sleep 20
bash scripts/p7_cdc_sink.sh status 2>/dev/null | grep -E "TOTAL-LAG|STATE" || true

cat <<'EOF'

== Verify the before-images arrived, in Snowflake
   snow sql -c qcpoc -q "
     SELECT RECORD_CONTENT:op::STRING AS op, COUNT(*) AS n
     FROM QCOMMERCE.RAW.CDC_PRODUCTS GROUP BY 1 ORDER BY 2 DESC"

   Expect r = 200 and u = 20. Then:
   snow sql -c qcpoc -f sql/p7_core_scd2.sql
EOF

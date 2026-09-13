{{ config(materialized='table') }}

-- PERIODIC SNAPSHOT. One row per store per product per day, whether or not
-- anything moved. That is the difference from a transaction fact: the absence
-- of change is itself a measurement, and "stock sat at zero for six days" is a
-- fact you cannot derive from a table that only records movements.
select
    {{ dbt_utils.generate_surrogate_key(['snapshot_date', 'store_id', 'product_id']) }} as inventory_sk,
    to_number(to_char(snapshot_date, 'YYYYMMDD'))              as snapshot_date_sk,
    snapshot_date,
    {{ dbt_utils.generate_surrogate_key(['store_id']) }}       as store_sk,
    store_id,
    product_id,
    on_hand_qty,
    reorder_level,
    on_hand_qty <= reorder_level                               as is_below_reorder,
    greatest(reorder_level - on_hand_qty, 0)                   as units_short
from {{ source('core', 'inventory_daily') }}

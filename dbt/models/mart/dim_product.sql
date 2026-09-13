{{ config(materialized='table') }}

-- SCD2, and the only dimension here that is. The surrogate key includes
-- valid_from, so each version is a distinct row a fact can point at: an order
-- placed before a price rise joins the price that was in force at the time,
-- not the price today. That is the whole reason the history was kept.
select
    {{ dbt_utils.generate_surrogate_key(['product_id', 'valid_from']) }} as product_sk,
    product_id,
    sku,
    product_name,
    category_l1,
    category_l2,
    category_l3,
    price_paise,
    is_active,
    valid_from,
    coalesce(valid_to, '9999-12-31'::timestamp_ntz)  as valid_to,
    is_current
from {{ source('core', 'dim_product') }}

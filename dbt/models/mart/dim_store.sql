{{ config(materialized='table') }}

-- SCD1. A dark store does not move, and if one did the old address would be
-- misinformation rather than history. Overwriting is the correct behaviour here
-- and choosing it deliberately is the point -- SCD2 on every dimension is a
-- habit, not a design.
select
    {{ dbt_utils.generate_surrogate_key(['store_id']) }} as store_sk,
    store_id,
    store_code,
    city,
    pincode,
    lat,
    lon,
    opened_on,
    is_active
from {{ source('core', 'store') }}

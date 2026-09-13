{{ config(materialized='table') }}

-- TRANSACTION grain, immutable. One row per lifecycle transition, already
-- deduplicated in CORE. Kept beside the accumulating snapshot rather than
-- folded into it: the snapshot cannot represent a transition that never
-- happened, and that absence is exactly what 348 orders are interesting for.
select
    {{ dbt_utils.generate_surrogate_key(['event_id']) }}    as event_sk,
    event_id,
    order_id,
    {{ dbt_utils.generate_surrogate_key(['order_id']) }}    as order_sk,
    {{ dbt_utils.generate_surrogate_key(['store_id']) }}    as store_sk,
    {{ dbt_utils.generate_surrogate_key(['rider_id']) }}    as rider_sk,
    to_number(to_char(event_ts, 'YYYYMMDD'))                as event_date_sk,
    from_status,
    to_status,
    event_ts,
    source_app,
    app_version,
    network
from {{ source('core', 'order_status_event') }}

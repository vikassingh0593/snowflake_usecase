{{ config(materialized='table') }}

-- ACCUMULATING SNAPSHOT. One row per order, rewritten as the order walks its
-- lifecycle: milestone timestamps as columns, the lag between each pair, and
-- the outcome. This is the grain that answers "how long from packed to picked
-- up"; fct_order_status_event keeps the immutable log beside it and answers
-- "which transitions were skipped". Both exist on purpose.
with outcome as (
    select order_id, 'CLEAN'     as lifecycle_outcome from {{ source('core', 'order_funnel') }}
    union all
    select order_id, 'CANCELLED'                      from {{ source('core', 'order_cancelled') }}
    union all
    select order_id, anomaly_type                     from {{ source('core', 'order_lifecycle_anomaly') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['o.order_id']) }}      as order_sk,
    o.order_id,

    to_number(to_char(o.placed_ts, 'YYYYMMDD'))                 as placed_date_sk,
    {{ dbt_utils.generate_surrogate_key(['o.customer_id']) }}   as customer_sk,
    {{ dbt_utils.generate_surrogate_key(['o.store_id']) }}      as store_sk,
    {{ dbt_utils.generate_surrogate_key(['o.rider_id']) }}      as rider_sk,

    o.placed_ts,
    o.promised_ts,
    o.packed_ts,
    o.picked_up_ts,
    o.delivered_ts,

    -- Legs measured from the EVENT STREAM where a clean funnel exists, because
    -- the events are the record of what happened. Orders without one keep null
    -- legs rather than a value computed from the header, which would look
    -- identical and mean something different.
    f.pack_sec,
    f.pick_sec,
    f.ride_sec,
    f.total_sec,

    o.status,
    coalesce(x.lifecycle_outcome, 'NO_EVENTS')                  as lifecycle_outcome,

    o.delivered_ts is not null
      and o.delivered_ts > o.promised_ts                        as is_breached,
    case when o.delivered_ts is not null
         then datediff('second', o.promised_ts, o.delivered_ts)
    end                                                         as breach_sec,

    o.payment_method,
    o.coupon_code,
    o.item_count,
    o.gross_paise,
    o.discount_paise,
    o.delivery_fee_paise,
    o.order_total_paise

from {{ source('core', 'order_header') }} o
left join {{ source('core', 'order_funnel') }} f using (order_id)
left join outcome x on x.order_id = o.order_id

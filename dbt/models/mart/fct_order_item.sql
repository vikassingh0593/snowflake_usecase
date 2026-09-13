{{ config(materialized='table') }}

-- TRANSACTION grain, and the model that pays for SCD2.
--
-- product_sk is resolved AS AT the moment the order was placed, not as at now.
-- Twenty products changed price; joining on product_id alone would restate every
-- historical line at today's price and quietly change revenue that has already
-- been reported. The validity-range join is what stops that.
select
    {{ dbt_utils.generate_surrogate_key(['i.order_item_id']) }} as order_item_sk,
    i.order_item_id,
    i.order_id,
    {{ dbt_utils.generate_surrogate_key(['i.order_id']) }}      as order_sk,
    p.product_sk,
    i.product_id,
    to_number(to_char(o.placed_ts, 'YYYYMMDD'))                 as placed_date_sk,

    i.qty,
    i.unit_price_paise,
    i.line_total_paise,

    -- What the catalogue said at the time, beside what was actually charged.
    -- A gap between them is a discount, a stale price, or a bug, and it cannot
    -- be seen at all without the versioned dimension.
    p.price_paise                                               as catalogue_price_paise,
    i.unit_price_paise - p.price_paise                          as price_variance_paise

from {{ source('core', 'order_item') }} i
join {{ source('core', 'order_header') }} o on o.order_id = i.order_id
left join {{ ref('dim_product') }} p
       on p.product_id = i.product_id
      and o.placed_ts >= p.valid_from
      and o.placed_ts <  p.valid_to

{{ config(materialized='table') }}

-- Generated, not sourced. A date dimension has no upstream system -- it is
-- arithmetic, and generating it means every date in range exists whether or not
-- an order happened that day. Gaps in a date dimension are how "no sales on
-- Tuesday" becomes invisible instead of zero.
with spine as (
  {{ dbt_utils.date_spine(
       datepart="day",
       start_date="to_date('2026-06-01')",
       end_date="to_date('2026-12-31')"
  ) }}
)

select
    to_number(to_char(date_day, 'YYYYMMDD'))            as date_sk,
    date_day                                            as calendar_date,
    year(date_day)                                      as calendar_year,
    quarter(date_day)                                   as calendar_quarter,
    month(date_day)                                     as calendar_month,
    monthname(date_day)                                 as month_name,
    day(date_day)                                       as day_of_month,
    dayofweek(date_day)                                 as day_of_week,
    dayname(date_day)                                   as day_name,
    weekofyear(date_day)                                as week_of_year,
    dayofweek(date_day) in (0, 6)                       as is_weekend
from spine

{{ config(materialized='table') }}

select
    {{ dbt_utils.generate_surrogate_key(['rider_id']) }} as rider_sk,
    rider_id,
    full_name,
    phone,
    vehicle_type,
    store_id,
    shift,
    is_active,
    joined_on
from {{ source('core', 'rider') }}

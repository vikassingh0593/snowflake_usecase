{{ config(materialized='table') }}

-- SCD1 for now. CORE carries the current state; the CDC log holds every version,
-- so the history exists and is recoverable -- it simply has not been versioned
-- into a dimension yet. Stating that is more honest than a surrogate key that
-- implies history it does not have.
select
    {{ dbt_utils.generate_surrogate_key(['customer_id']) }} as customer_sk,
    customer_id,
    full_name,
    email,
    phone,
    segment,
    home_pincode,
    home_lat,
    home_lon,
    created_at
from {{ source('core', 'customer') }}

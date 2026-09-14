-- NorthPeak: DimCustomer dimension
-- Grain: one row per customer, plus one sentinel UNKNOWN row (-1)
-- Only customer_id and email are documented (Dmitri handover, 10 Jul 2026).

{{
  config(
    materialized='view',
    schema='marts',
    tags=['gold', 'dimension']
  )
}}

with source as (
    select * from {{ source('silver', 'customers') }}
),

known as (
    select
        customer_id,
        email,
        email is null as email_is_missing
    from source
),

unknown as (
    select
        -1 as customer_id,
        cast(null as varchar) as email,
        true as email_is_missing
)

select customer_id as customer_key, customer_id, email, email_is_missing from known
union all
select customer_id as customer_key, customer_id, email, email_is_missing from unknown

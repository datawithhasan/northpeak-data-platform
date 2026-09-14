-- NorthPeak: DimStore dimension
-- Grain: one row per store. No unknown-sentinel row -
-- contract requires store_key is never null (every order has a real store).
-- Only store_id is documented; no other store attributes exist in source docs yet.

{{
  config(
    materialized='view',
    schema='marts',
    tags=['gold', 'dimension']
  )
}}

select
    store_id as store_key,
    store_id
from {{ source('silver', 'stores') }}

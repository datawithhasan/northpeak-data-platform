-- NorthPeak: DimDate dimension
-- Synthetic calendar spine, 2018-01-01 through 2030-01-01

{{
  config(
    materialized='table',
    schema='marts',
    tags=['gold', 'dimension']
  )
}}

with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2018-01-01' as date)",
        end_date="cast('2030-01-01' as date)"
    ) }}
)

select
    cast(date_day as date)                        as date_day,
    cast(strftime(date_day, '%Y%m%d') as integer)  as date_key,
    extract(year from date_day)                    as year,
    extract(month from date_day)                   as month,
    extract(day from date_day)                     as day,
    extract(dow from date_day)                      as day_of_week
from spine

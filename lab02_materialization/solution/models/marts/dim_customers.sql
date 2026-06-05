{{
    config(materialized='table')
}}

with customers as (
    select * from {{ ref('stg_customers') }}
),

nations as (
    select
        n_nationkey as nation_id,
        n_name      as nation_name,
        n_regionkey as region_id
    from {{ source('tpch', 'nation') }}
),

regions as (
    select
        r_regionkey as region_id,
        r_name      as region_name
    from {{ source('tpch', 'region') }}
),

final as (
    select
        customers.customer_id,
        customers.customer_name,
        customers.market_segment,
        customers.account_balance,
        customers.phone_number,
        nations.nation_name,
        regions.region_name
    from customers
    left join nations
        on customers.nation_id = nations.nation_id
    left join regions
        on nations.region_id = regions.region_id
)

select * from final

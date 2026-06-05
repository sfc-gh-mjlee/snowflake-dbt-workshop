{{
    config(materialized='table')
}}

with lineitem as (
    select
        l_orderkey                                   as order_id,
        l_suppkey                                    as supplier_id,
        l_extendedprice * (1 - l_discount)           as net_revenue,
        l_shipdate                                   as ship_date
    from {{ source('tpch', 'lineitem') }}
),

orders as (
    select order_id, customer_id, order_date
    from {{ ref('stg_orders') }}
),

customers as (
    select customer_id, nation_id
    from {{ ref('stg_customers') }}
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

joined as (
    select
        {{ dbt_utils.generate_surrogate_key(['orders.order_date', 'nations.nation_name']) }} as revenue_key,
        orders.order_date,
        nations.nation_name,
        regions.region_name,
        sum(lineitem.net_revenue)               as total_net_revenue,
        count(distinct orders.order_id)         as order_count,
        {{ safe_divide('sum(lineitem.net_revenue)', 'count(distinct orders.order_id)') }} as avg_order_revenue
    from lineitem
    inner join orders    on lineitem.order_id     = orders.order_id
    inner join customers on orders.customer_id    = customers.customer_id
    inner join nations   on customers.nation_id   = nations.nation_id
    inner join regions   on nations.region_id     = regions.region_id
    group by 1, 2, 3, 4
)

select * from joined

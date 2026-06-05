{{
    config(
        materialized='incremental',
        unique_key='order_id',
        incremental_strategy='merge',
        cluster_by=['order_date']
    )
}}

with orders as (
    select * from {{ ref('stg_orders') }}

    {% if is_incremental() %}
        where order_date > (
            select dateadd(day, -3, max(order_date))
            from {{ this }}
        )
    {% endif %}
),

lineitem_agg as (
    select
        l_orderkey                                              as order_id,
        sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as gross_item_sales_amount,
        sum(l_extendedprice * (1 - l_discount))                as net_item_sales_amount,
        count(*)                                               as line_item_count
    from {{ source('tpch', 'lineitem') }}
    group by 1
),

final as (
    select
        orders.order_id,
        orders.customer_id,
        orders.order_status,
        orders.order_date,
        orders.order_priority,
        orders.order_total_price,
        coalesce(lineitem_agg.gross_item_sales_amount, 0) as gross_item_sales_amount,
        coalesce(lineitem_agg.net_item_sales_amount, 0)   as net_item_sales_amount,
        coalesce(lineitem_agg.line_item_count, 0)         as line_item_count
    from orders
    left join lineitem_agg
        on orders.order_id = lineitem_agg.order_id
)

select * from final

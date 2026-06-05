-- fct_orders의 order_total_price는 stg_orders와 일치해야 한다
with fct as (
    select order_id, order_total_price
    from {{ ref('fct_orders') }}
),

stg as (
    select order_id, order_total_price
    from {{ ref('stg_orders') }}
),

mismatches as (
    select
        fct.order_id,
        fct.order_total_price as fct_price,
        stg.order_total_price as stg_price,
        abs(fct.order_total_price - stg.order_total_price) as diff
    from fct
    inner join stg on fct.order_id = stg.order_id
    where abs(fct.order_total_price - stg.order_total_price) > 0.01
)

select * from mismatches

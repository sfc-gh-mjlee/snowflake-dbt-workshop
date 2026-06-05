{% snapshot snap_customers %}

{{
    config(
        target_schema='snapshots',
        unique_key='customer_id',
        strategy='check',
        check_cols=['market_segment', 'account_balance']
    )
}}

select * from {{ ref('stg_customers') }}

{% endsnapshot %}

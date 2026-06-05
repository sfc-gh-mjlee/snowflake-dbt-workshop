# Lab 02: Materialization 심화

**소요 시간:** 약 60분  
**목표:** dbt의 4가지 materialization을 이해하고, Snowflake에 최적화된 incremental 전략과 snapshot을 실습한다.

---

## 이론 (20분)

### 4가지 Materialization 비교

| 종류 | 동작 | 장점 | 단점 | 사용 시나리오 |
|------|------|------|------|---------------|
| **view** | 실행 시 SQL 재계산 | 저장 공간 없음 | 쿼리마다 계산 비용 | staging, 가볍고 자주 바뀌는 변환 |
| **table** | 매 실행마다 DROP → CREATE | 빠른 조회 | 전체 재계산 비용 | 중간 크기 마트, 자주 읽히는 테이블 |
| **incremental** | 새 데이터만 추가/갱신 | 대용량 처리 효율적 | 복잡한 설정 | 이벤트 로그, 팩트 테이블 |
| **ephemeral** | CTE로 인라인 처리 | 물리 오브젝트 없음 | 재사용 불가 | 중간 변환 (성능 주의) |

### Incremental 전략 심화

dbt-snowflake는 3가지 incremental 전략을 지원합니다:

```
append (기본)
└── 새 행만 INSERT
└── 중복 제거 없음
└── use_case: 이벤트 로그, 순수 append-only

merge (권장)
└── unique_key 기준으로 MERGE INTO
└── 기존 행 UPDATE + 신규 행 INSERT
└── use_case: 팩트 테이블, 주문처럼 상태가 바뀌는 데이터

delete+insert
└── 특정 파티션 삭제 후 INSERT
└── unique_key 없어도 됨
└── use_case: 날짜 파티션 전략
```

### Incremental 모델 핵심 패턴

```sql
{{
    config(
        materialized='incremental',
        unique_key='order_id',
        incremental_strategy='merge',
        cluster_by=['order_date']   -- Snowflake 클러스터링 키
    )
}}

with source as (
    select * from {{ ref('stg_orders') }}

    {% if is_incremental() %}
        -- 첫 실행(full-refresh)이 아닐 때만 적용
        where order_date > (select max(order_date) from {{ this }})
    {% endif %}
)

select * from source
```

> **핵심 원칙:** `{% if is_incremental() %}` 블록 안에 필터를 넣어야  
> `dbt run --full-refresh` 시 전체 데이터를 다시 처리할 수 있습니다.

### Snapshot (SCD Type 2)

원천 데이터의 **변경 이력**을 추적하는 기능입니다.

```sql
-- snapshots/snap_customers.sql
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
```

dbt가 자동으로 추가하는 메타 컬럼:

| 컬럼 | 설명 |
|------|------|
| `dbt_scd_id` | 각 행의 고유 해시 키 |
| `dbt_updated_at` | 행이 생성/갱신된 시각 |
| `dbt_valid_from` | 이 버전이 유효해진 시각 |
| `dbt_valid_to` | NULL이면 현재 유효 버전 |

---

## 실습

### Step 1: view vs table 비교 (10분)

Lab01에서 만든 `stg_orders`(view)를 기반으로 table materialization을 사용하는 mart를 만들어봅니다.

**`models/marts/dim_customers.sql`**

```sql
{{
    config(materialized='table')
}}

with customers as (
    select * from {{ ref('stg_customers') }}
),

nations as (
    select * from {{ ref('stg_nations') }}  -- Lab01 도전과제에서 만든 모델
),

regions as (
    select * from {{ ref('stg_regions') }}
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
```

> **참고:** `stg_nations`, `stg_regions`는 Lab01 도전과제입니다.  
> solution은 `../lab01_project_setup/solution/` 디렉토리를 참고하세요.

```bash
# 실행 후 Snowflake에서 오브젝트 타입 확인
dbt run --select dim_customers
```

Snowflake 워크시트에서 확인:
```sql
SHOW TABLES IN SCHEMA dbt_workshop_db.dev_<name>_marts;
-- TABLE_TYPE = 'BASE TABLE' 확인
```

### Step 2: Incremental 모델 구현 (20분)

**`models/marts/fct_orders.sql`**

```sql
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
        -- 3일치 겹침: 늦게 들어오는 데이터(late-arriving) 처리
    {% endif %}
),

lineitem as (
    select
        l_orderkey              as order_id,
        sum(l_extendedprice
            * (1 - l_discount)
            * (1 + l_tax))      as gross_item_sales_amount,
        sum(l_extendedprice
            * (1 - l_discount)) as net_item_sales_amount,
        count(*)                as line_item_count
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
        lineitem.gross_item_sales_amount,
        lineitem.net_item_sales_amount,
        lineitem.line_item_count
    from orders
    left join lineitem
        on orders.order_id = lineitem.order_id
)

select * from final
```

```bash
# 첫 실행 (전체 데이터 적재)
dbt run --select fct_orders

# 두 번째 실행 (incremental - 빠름)
dbt run --select fct_orders

# 강제 전체 재처리
dbt run --select fct_orders --full-refresh
```

**실행 로그에서 확인할 사항:**
- 첫 실행: `Creating table fct_orders`
- 두 번째 실행: `Merging into table fct_orders`

### Step 3: Snapshot으로 SCD Type 2 구현 (20분)

**`snapshots/snap_customers.sql`**

```sql
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
```

```bash
# 스냅샷 초기 실행
dbt snapshot

# Snowflake에서 확인
-- SELECT * FROM dbt_workshop_db.dev_<name>_snapshots.snap_customers LIMIT 10;
-- dbt_valid_to IS NULL 인 행이 현재 유효 버전
```

**SCD Type 2 동작 시뮬레이션:**

```sql
-- 워크샵 교관이 시뮬레이션용으로 사용
-- (실제 원천 데이터는 읽기 전용이므로 직접 수정 불가)
-- 대신 stg_customers 모델에 테스트용 데이터 변경을 추가한 뒤
-- dbt snapshot을 재실행하는 방식으로 이력 추적을 확인합니다
SELECT
    customer_id,
    customer_name,
    market_segment,
    account_balance,
    dbt_valid_from,
    dbt_valid_to
FROM dev_<name>_snapshots.snap_customers
WHERE customer_id = 1
ORDER BY dbt_valid_from;
```

---

## Materialization 선택 가이드

```
데이터 크기가 크고 매일 증분이 있다
    → incremental (merge 전략)

변경 이력 추적이 필요하다
    → snapshot

집계·join이 무겁고 자주 읽힌다
    → table

가볍고 항상 최신 데이터여야 한다
    → view

중간 변환인데 물리적 오브젝트로 만들기 애매하다
    → ephemeral
```

---

## 검증 체크리스트

- [ ] `dim_customers`: MARTS 스키마에 BASE TABLE로 생성됨
- [ ] `fct_orders`: incremental 첫 실행 완료
- [ ] `fct_orders`: 두 번째 실행에서 MERGE 동작 확인
- [ ] `snap_customers`: SNAPSHOTS 스키마에 `dbt_valid_from/to` 컬럼 포함 확인

---

## 도전 과제

1. `fct_orders`의 `incremental_strategy`를 `delete+insert`로 바꾸고, `cluster_by`를 `['order_date', 'order_status']`로 설정해보세요.
2. `snap_customers`에서 `strategy='timestamp'` 방식도 시도해보세요. `check`와 어떤 차이가 있나요?
3. `ephemeral` materialization으로 `int_orders_enriched.sql`(중간 변환 레이어)을 만들고, `fct_orders`에서 참조해보세요.

---

[← Lab 01](../lab01_project_setup/LAB.md) | [Lab 03 →](../lab03_jinja_macros/LAB.md)

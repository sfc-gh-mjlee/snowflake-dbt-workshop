# Lab 03: Jinja & 매크로

**소요 시간:** 약 60분  
**목표:** Jinja2 템플릿 문법과 dbt 매크로를 활용하여 재사용 가능하고 환경 적응형 SQL을 작성한다.

---

## 이론 (20분)

### Jinja2 in dbt

dbt 모델은 SQL + Jinja2 템플릿 엔진의 결합입니다.  
dbt compile 단계에서 Jinja가 순수 SQL로 변환됩니다.

```
models/fct_orders.sql (Jinja)
    ↓  dbt compile
target/compiled/.../fct_orders.sql (순수 SQL)
    ↓  dbt run
Snowflake 실행
```

**Jinja 기본 문법:**

| 문법 | 설명 | 예시 |
|------|------|------|
| `{{ expr }}` | 표현식 출력 | `{{ ref('stg_orders') }}` |
| `{% stmt %}` | 제어문 | `{% if condition %}` |
| `{# comment #}` | 주석 | `{# 임시 비활성화 #}` |

### dbt 기본 내장 함수

```sql
-- 다른 모델 참조 (DAG 의존성 자동 등록)
{{ ref('model_name') }}

-- 원천 테이블 참조
{{ source('source_name', 'table_name') }}

-- 현재 모델 자신 참조 (incremental에서 사용)
{{ this }}
{{ this.schema }}     -- 스키마명
{{ this.identifier }} -- 테이블명

-- 환경 변수
{{ env_var('MY_ENV_VAR') }}
{{ env_var('MY_ENV_VAR', 'default_value') }}
```

### 실행 컨텍스트 분기

```sql
-- 프로파일 타겟 기반 분기
{% if target.name == 'prod' %}
    -- 프로덕션 전용 로직
    select * from large_table
{% else %}
    -- 개발 환경: 데이터 제한
    select * from large_table limit 10000
{% endif %}

-- 특정 날짜 이후 데이터만 (개발 환경 비용 최적화)
{% if is_incremental() %}
    where event_date > (select max(event_date) from {{ this }})
{% elif target.name != 'prod' %}
    where event_date >= dateadd(month, -3, current_date)
{% endif %}
```

### 매크로(Macro) 구조

매크로는 Jinja 함수입니다. `macros/` 폴더에 `.sql` 파일로 작성합니다.

```sql
-- macros/cents_to_dollars.sql
{% macro cents_to_dollars(column_name) %}
    ({{ column_name }} / 100)::decimal(18, 2)
{% endmacro %}

-- 사용
select {{ cents_to_dollars('price_cents') }} as price_dollars
```

### dbt-utils 패키지

dbt Labs에서 제공하는 유용한 매크로 모음입니다.

```yaml
# packages.yml
packages:
  - package: dbt-labs/dbt_utils
    version: 1.1.1
```

자주 쓰는 dbt_utils 매크로:

| 매크로 | 설명 |
|--------|------|
| `dbt_utils.generate_surrogate_key(['col1', 'col2'])` | 복합키로 해시 SK 생성 |
| `dbt_utils.date_spine(...)` | 날짜 시퀀스 생성 |
| `dbt_utils.star(ref(...), except=[...])` | 특정 컬럼 제외하고 SELECT * |
| `dbt_utils.pivot(...)` | 피벗 테이블 생성 |
| `dbt_utils.union_relations([...])` | 여러 테이블 UNION ALL |

---

## 실습

### Step 1: packages.yml 작성 & 설치 (5분)

**`packages.yml`** (프로젝트 루트에 생성):

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: 1.1.1
```

```bash
# 패키지 설치
dbt deps

# 설치 확인
ls dbt_packages/
```

### Step 2: 커스텀 매크로 작성 (15분)

**`macros/format_currency.sql`**

```sql
{% macro format_currency(column_name, currency_code='USD', scale=2) %}
    round({{ column_name }}, {{ scale }})
{% endmacro %}
```

**`macros/limit_in_dev.sql`**

```sql
{#
    개발 환경에서 데이터 샘플링을 자동 적용하는 매크로.
    prod 환경에서는 아무것도 추가하지 않음.
    사용법: {{ limit_in_dev(1000) }}
#}
{% macro limit_in_dev(row_limit=1000) %}
    {% if target.name != 'prod' %}
        limit {{ row_limit }}
    {% endif %}
{% endmacro %}
```

**`macros/safe_divide.sql`**

```sql
{% macro safe_divide(numerator, denominator) %}
    iff(
        {{ denominator }} = 0 or {{ denominator }} is null,
        null,
        {{ numerator }} / {{ denominator }}
    )
{% endmacro %}
```

### Step 3: surrogate key를 활용한 팩트 테이블 (15분)

**`models/marts/fct_revenue_by_nation.sql`**

```sql
{{
    config(materialized='table')
}}

with lineitem as (
    select
        l_orderkey   as order_id,
        l_suppkey    as supplier_id,
        l_extendedprice * (1 - l_discount) as net_revenue,
        l_shipdate   as ship_date
    from {{ source('tpch', 'lineitem') }}
),

orders as (
    select
        order_id,
        customer_id,
        order_date
    from {{ ref('stg_orders') }}
),

customers as (
    select
        customer_id,
        nation_id
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
        -- surrogate key: 날짜 + 국가 조합의 유일성 보장
        {{ dbt_utils.generate_surrogate_key(['orders.order_date', 'nations.nation_name']) }} as revenue_key,

        orders.order_date,
        nations.nation_name,
        regions.region_name,
        sum(lineitem.net_revenue) as total_net_revenue,
        count(distinct orders.order_id) as order_count,

        -- 매크로 활용: 0 나누기 방어
        {{ safe_divide('sum(lineitem.net_revenue)', 'count(distinct orders.order_id)') }} as avg_order_revenue

    from lineitem
    inner join orders on lineitem.order_id = orders.order_id
    inner join customers on orders.customer_id = customers.customer_id
    inner join nations on customers.nation_id = nations.nation_id
    inner join regions on nations.region_id = regions.region_id
    group by 1, 2, 3, 4
)

select * from joined
```

```bash
dbt compile --select fct_revenue_by_nation
# target/compiled/ 에서 생성된 순수 SQL 확인

dbt run --select fct_revenue_by_nation
```

### Step 4: 환경별 분기 모델 (10분)

**`models/marts/fct_orders_dev_optimized.sql`**

```sql
{{
    config(
        materialized='table',
        tags=['dev-only']
    )
}}

{#
    이 모델은 target.name 분기를 통해
    개발 환경에서는 최근 6개월 데이터만 처리합니다.
#}

with base as (
    select * from {{ ref('fct_orders') }}

    {% if target.name != 'prod' %}
        where order_date >= dateadd(month, -6, current_date())
    {% endif %}
),

final as (
    select
        order_id,
        customer_id,
        order_status,
        order_date,
        order_total_price,
        net_item_sales_amount,

        -- 포맷 매크로 활용
        {{ format_currency('order_total_price') }} as order_total_price_rounded,

        -- 메타데이터
        '{{ target.name }}'::varchar       as dbt_target,
        current_timestamp()                as loaded_at

    from base
)

select * from final
{{ limit_in_dev(5000) }}
```

```bash
# 개발 환경 실행 (limit 5000 적용됨)
dbt run --select fct_orders_dev_optimized

# 컴파일 결과 확인 (limit 문 존재 여부)
cat target/compiled/tpch_workshop/models/marts/fct_orders_dev_optimized.sql
```

### Step 5: dbt_utils 심화 - star() 매크로 (5분)

특정 컬럼을 제외한 나머지 모두를 SELECT 할 때 유용합니다.

```sql
-- models/staging/stg_lineitem.sql
with source as (
    select * from {{ source('tpch', 'lineitem') }}
)

select
    -- 원하지 않는 컬럼 제외하고 나머지 전체 선택
    {{ dbt_utils.star(
        from=source('tpch', 'lineitem'),
        except=["L_COMMENT"]
    ) }}
from source
```

```bash
dbt compile --select stg_lineitem
# 생성된 SQL에서 L_COMMENT 제외된 컬럼 목록 확인
```

---

## 매크로 디버깅 팁

```bash
# 모델 컴파일만 (실행 없이 Jinja 결과 확인)
dbt compile --select fct_revenue_by_nation

# Jinja 실행 테스트 (매크로 직접 호출)
dbt run-operation my_macro --args '{"arg1": "value1"}'

# 컴파일된 SQL 확인
cat target/compiled/tpch_workshop/models/marts/fct_revenue_by_nation.sql
```

---

## 검증 체크리스트

- [ ] `dbt deps` 성공 (`dbt_packages/dbt_utils` 폴더 생성)
- [ ] `macros/` 폴더에 3개 매크로 파일 존재
- [ ] `fct_revenue_by_nation` 실행 성공 & `revenue_key` 컬럼 해시값 확인
- [ ] `dbt compile` 결과에서 `safe_divide`가 `IFF(...)` SQL로 변환됨 확인
- [ ] `target.name != 'prod'` 조건에서 `LIMIT` 절 포함 확인

---

## 도전 과제

1. `generate_date_spine` 매크로를 사용하여 날짜 기반 집계에서 날짜 gap이 없는 시계열 테이블을 만들어보세요.
2. `dbt_utils.pivot()`을 사용하여 국가별 시장 세그먼트 크로스탭을 만들어보세요.
3. 여러 모델에서 공통으로 사용하는 "활성 고객" 필터 조건을 매크로화해보세요.  
   (`account_balance > 0 AND market_segment != 'BUILDING'` 조건 기준)

---

[← Lab 02](../lab02_materialization/LAB.md) | [Lab 04 →](../lab04_testing/LAB.md)

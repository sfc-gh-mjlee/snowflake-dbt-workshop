# Lab 04: 테스트 & 데이터 품질

**소요 시간:** 약 45분  
**목표:** dbt의 내장 테스트와 singular 테스트를 작성하여 파이프라인에 데이터 품질 검증 레이어를 구축한다.

---

## 이론 (15분)

### dbt 테스트의 두 가지 종류

#### 1. Generic Tests (schema.yml 기반)

사전 정의된 테스트를 YAML에서 선언적으로 적용합니다.

```
dbt 내장 4가지:
├── unique          -- 컬럼 내 중복 없음
├── not_null        -- null 없음
├── accepted_values -- 허용된 값만 존재
└── relationships   -- FK 무결성 (다른 모델 컬럼과 일치)

dbt-utils/dbt-expectations 등 패키지로 확장 가능
```

#### 2. Singular Tests (tests/ 폴더의 SQL 파일)

`SELECT` 결과가 **0건이면 통과**, **1건 이상이면 실패**가 원칙입니다.

```sql
-- tests/assert_no_negative_revenue.sql
-- 음수 매출이 있으면 테스트 실패
select order_id
from {{ ref('fct_orders') }}
where net_item_sales_amount < 0
```

### Generic Test vs Singular Test 선택 기준

| 상황 | 권장 방식 |
|------|-----------|
| 단순 컬럼 레벨 제약 (PK, FK, Not Null) | Generic |
| 허용값 목록 검증 | Generic |
| 복잡한 비즈니스 규칙 | Singular |
| 여러 테이블 간 집계 일치 확인 | Singular |
| 날짜/숫자 범위 검증 | Generic (dbt-expectations) or Singular |

### 테스트 심각도(severity) 설정

```yaml
columns:
  - name: order_total_price
    tests:
      - not_null:
          severity: warn    # 실패해도 파이프라인 중단하지 않음
      - dbt_utils.expression_is_true:
          expression: ">= 0"
          severity: error   # 실패 시 파이프라인 중단 (기본값)
```

### 테스트 실행 선택자

```bash
dbt test                            # 모든 테스트
dbt test --select stg_orders        # 특정 모델의 테스트만
dbt test --select source:tpch       # 소스 테스트만
dbt test --select tag:critical      # 특정 태그 테스트만
dbt build --select +fct_orders      # run + test 동시
```

---

## 실습

### Step 1: Staging 레이어 Generic 테스트 (10분)

**`models/staging/_stg_orders.yml`**

```yaml
version: 2

models:
  - name: stg_orders
    description: "원천 ORDERS 테이블의 표준화된 staging 뷰"
    columns:
      - name: order_id
        description: "주문 고유 키 (O_ORDERKEY)"
        tests:
          - unique
          - not_null

      - name: customer_id
        description: "고객 FK"
        tests:
          - not_null
          - relationships:
              to: ref('stg_customers')
              field: customer_id

      - name: order_status
        description: "주문 상태"
        tests:
          - not_null
          - accepted_values:
              values: ['O', 'F', 'P']

      - name: order_total_price
        description: "주문 총액"
        tests:
          - not_null

      - name: order_date
        description: "주문 일자"
        tests:
          - not_null
```

**`models/staging/_stg_customers.yml`**

```yaml
version: 2

models:
  - name: stg_customers
    description: "원천 CUSTOMER 테이블의 표준화된 staging 뷰"
    columns:
      - name: customer_id
        tests:
          - unique
          - not_null

      - name: customer_name
        tests:
          - not_null

      - name: market_segment
        tests:
          - accepted_values:
              values:
                - AUTOMOBILE
                - BUILDING
                - FURNITURE
                - MACHINERY
                - HOUSEHOLD

      - name: account_balance
        tests:
          - not_null
```

```bash
# staging 테스트 실행
dbt test --select staging
```

### Step 2: Mart 레이어 테스트 (10분)

**`models/marts/_marts.yml`**

```yaml
version: 2

models:
  - name: fct_orders
    description: "주문 팩트 테이블 (incremental)"
    tests:
      # 모델 레벨 테스트: 복합 고유성
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns:
            - order_id
    columns:
      - name: order_id
        tests:
          - unique
          - not_null

      - name: customer_id
        tests:
          - not_null
          - relationships:
              to: ref('stg_customers')
              field: customer_id
              severity: warn   # FK 위반은 경고만

      - name: order_total_price
        description: "주문 총액은 반드시 양수"
        tests:
          - not_null
          - dbt_utils.expression_is_true:
              expression: ">= 0"

      - name: order_status
        tests:
          - accepted_values:
              values: ['O', 'F', 'P']

  - name: dim_customers
    description: "고객 디멘전 테이블"
    columns:
      - name: customer_id
        tests:
          - unique
          - not_null

      - name: nation_name
        tests:
          - not_null

      - name: region_name
        tests:
          - not_null
```

### Step 3: Singular 테스트 작성 (15분)

**`tests/assert_order_total_matches_lineitem.sql`**

```sql
{#
    비즈니스 규칙 검증:
    fct_orders의 order_total_price는 stg_orders와 일치해야 한다.
    (ETL 과정에서 값 손실 여부 확인)
#}

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

-- 불일치 건이 0이면 테스트 통과
select * from mismatches
```

**`tests/assert_every_order_has_lineitem.sql`**

```sql
{#
    모든 주문(fct_orders)에는 최소 1개 이상의 lineitem이 있어야 한다.
#}

with orders as (
    select order_id from {{ ref('fct_orders') }}
    where line_item_count = 0 or line_item_count is null
)

select * from orders
```

**`tests/assert_customer_nation_coverage.sql`**

```sql
{#
    dim_customers의 모든 고객은 nation_name이 존재해야 한다.
    (join 누락 검증)
#}

select customer_id
from {{ ref('dim_customers') }}
where nation_name is null
   or region_name is null
```

```bash
# 모든 테스트 실행
dbt test

# 실패한 테스트 결과 상세 확인
dbt test --store-failures
-- 실패 행은 target 스키마의 dbt_test__audit 스키마에 저장됨
```

### Step 4: 테스트 결과 해석 (5분)

```bash
# 테스트 결과 요약
dbt test 2>&1 | tail -20
```

예상 출력:
```
21:03:45  Finished running 12 tests in 0 hours 0 minutes and 8.44 seconds (WAL).
21:03:45
21:03:45  Completed with 1 warning:
21:03:45
21:03:45  Warning in test relationships_fct_orders_customer_id__customer_id__ref_stg_customers_ ...
21:03:45    Got 0 results, configured to fail if != 0
21:03:45
21:03:45  Done. PASS=11 WARN=1 ERROR=0 SKIP=0 TOTAL=12
```

**Snowflake에서 실패 행 직접 확인 (--store-failures 사용 시):**
```sql
SELECT * FROM dbt_workshop_db.dev_<name>_dbt_test__audit
    .<test_name>
LIMIT 20;
```

---

## 테스트 커버리지 점검

```bash
# 어떤 모델에 테스트가 없는지 확인
dbt ls --select '*' --resource-type model | while read model; do
    count=$(dbt ls --select "test:$model" 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        echo "NO TESTS: $model"
    fi
done
```

---

## 검증 체크리스트

- [ ] `dbt test --select staging` → PASS=5 이상
- [ ] `stg_orders.order_status` accepted_values 테스트 PASS
- [ ] `stg_orders.customer_id` relationships 테스트 PASS
- [ ] `fct_orders.order_total_price` expression_is_true 테스트 PASS
- [ ] `assert_every_order_has_lineitem` singular 테스트 PASS
- [ ] `--store-failures` 옵션으로 실패 행 확인 방법 이해

---

## 도전 과제

1. `dbt-expectations` 패키지를 설치하고 `expect_column_values_to_be_between`을 사용하여 `L_DISCOUNT`가 0.00~0.10 사이임을 검증하세요.
2. 전체 주문 금액이 전날 대비 50% 이상 변동하면 경고를 발생시키는 singular 테스트를 작성해보세요.
3. `--store-failures` 플래그의 활용 시나리오를 정리해보세요.  
   (어떤 테이블에 어떤 형태로 저장되는지 확인)

---

[← Lab 03](../lab03_jinja_macros/LAB.md) | [Lab 05 →](../lab05_cicd/LAB.md)

# Lab 04: 테스트 & 데이터 품질

**소요 시간:** 약 45분  
**목표:** dbt의 generic 테스트와 singular 테스트를 작성하여 파이프라인에 데이터 품질 검증 레이어를 구축한다.

---

## 이론 (15분)

### dbt 테스트의 두 가지 종류

#### 1. Generic Tests (schema YAML 기반)

```yaml
# 사전 정의된 4가지 내장 테스트
- unique          # 컬럼 내 중복 없음
- not_null        # null 없음
- accepted_values # 허용된 값만 존재
- relationships   # FK 무결성
```

#### 2. Singular Tests (tests/ 폴더의 SQL 파일)

`SELECT` 결과가 **0건이면 통과**, **1건 이상이면 실패** 원칙.

```sql
-- tests/assert_no_negative_revenue.sql
select order_id
from {{ ref('fct_orders') }}
where net_item_sales_amount < 0
```

### 테스트 심각도(severity) 설정

```yaml
- not_null:
    severity: warn    # 실패해도 파이프라인 중단 안 함
- dbt_utils.expression_is_true:
    expression: ">= 0"
    severity: error   # 실패 시 중단 (기본값)
```

### --store-failures 옵션

실패한 행을 Snowflake 테이블로 저장하여 원인 분석에 활용합니다.

```sql
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='test --store-failures';
-- 실패 행은 workshop_dbt_test__audit 스키마에 저장됨
```

---

## 실습

### Step 1: Staging 테스트 실행 및 확인 (10분)

```sql
-- staging 레이어 테스트 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='test --select staging';
```

```sql
-- 실패한 테스트의 원인 데이터 확인 (--store-failures 사용 시)
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='test --select staging --store-failures';

-- 실패 행 확인
SHOW TABLES IN SCHEMA dbt_workshop_db.workshop_dbt_test__audit;
```

**`solution/models/staging/_stg_orders.yml` 테스트 구조:**

```yaml
models:
  - name: stg_orders
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
      - name: order_status
        tests:
          - accepted_values:
              values: ['O', 'F', 'P']
```

### Step 2: Mart 테스트 실행 (10분)

```sql
-- fct_orders 테스트 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='test --select fct_orders';
```

```sql
-- dim_customers 테스트 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='test --select dim_customers';
```

**`solution/models/marts/_marts.yml` 핵심 설정:**

```yaml
- name: fct_orders
  tests:
    # 모델 레벨: 복합 고유성 테스트
    - dbt_utils.unique_combination_of_columns:
        combination_of_columns: [order_id]
  columns:
    - name: order_total_price
      tests:
        - dbt_utils.expression_is_true:
            expression: ">= 0"
    - name: customer_id
      tests:
        - relationships:
            to: ref('stg_customers')
            field: customer_id
            severity: warn   # FK 위반은 경고만
```

### Step 3: Singular 테스트 작성 & 실행 (15분)

`solution/models/tests/assert_order_total_matches_lineitem.sql`을 확인합니다.

```sql
-- GitHub에서 singular 테스트 파일 확인
SELECT $1
FROM @dbt_workshop_db.workshop.dbt_workshop_repo/branches/main/lab04_testing/solution/models/tests/assert_order_total_matches_lineitem.sql
    (FILE_FORMAT => (TYPE = 'CSV' FIELD_DELIMITER = NONE RECORD_DELIMITER = '\n'));
```

```sql
-- 전체 테스트 실행 (run + test 동시)
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='build';
```

예상 출력:
```
PASS=XX WARN=X ERROR=0 SKIP=0 TOTAL=XX
```

### Step 4: 실패 행 분석 (10분)

```sql
-- store-failures로 실패 행 저장 후 분석
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='test --store-failures';

-- 저장된 실패 테이블 목록
SHOW TABLES IN SCHEMA dbt_workshop_db.workshop_dbt_test__audit;

-- 특정 테스트의 실패 행 확인 (테이블명은 테스트 이름 기반)
-- SELECT * FROM dbt_workshop_db.workshop_dbt_test__audit.<test_name> LIMIT 20;
```

---

## 테스트 커버리지 점검

```sql
-- 배포된 프로젝트의 모든 리소스 목록
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='list';

-- 테스트만 필터
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='list --resource-type test';
```

---

## 검증 체크리스트

- [ ] `test --select staging` → PASS 10건 이상
- [ ] `stg_orders.order_status` accepted_values 테스트 PASS
- [ ] `fct_orders.order_total_price` expression_is_true 테스트 PASS
- [ ] `assert_order_total_matches_lineitem` singular 테스트 PASS
- [ ] `--store-failures` 옵션으로 실패 행이 audit 스키마에 저장됨 확인

---

## 도전 과제

1. `dbt-expectations` 패키지를 추가하고 `L_DISCOUNT`가 0.00~0.10 범위임을  
   `expect_column_values_to_be_between`으로 검증해보세요.
2. 전체 주문 금액이 특정 임계값 이하이면 실패하는 singular 테스트를 작성해보세요.  
   (데이터 파이프라인 이상 감지 시나리오)
3. `warn_if` / `error_if` 임계값 설정을 활용하여 "5% 이내 실패는 경고,  
   5% 초과는 에러"로 설정하는 방법을 알아보세요.

---

[← Lab 03](../lab03_jinja_macros/LAB.md) | [Lab 05 →](../lab05_cicd/LAB.md)

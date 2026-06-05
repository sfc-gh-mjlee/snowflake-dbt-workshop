# Lab 02: Materialization 심화

**소요 시간:** 약 60분  
**목표:** dbt의 4가지 materialization을 이해하고, Snowflake에 최적화된 incremental 전략과 snapshot을 Snowsight에서 실습한다.

---

## 이론 (20분)

### 4가지 Materialization 비교

| 종류 | 동작 | 장점 | 단점 | 사용 시나리오 |
|------|------|------|------|---------------|
| **view** | 실행 시 SQL 재계산 | 저장 공간 없음 | 쿼리마다 계산 비용 | staging, 자주 바뀌는 변환 |
| **table** | 매 실행마다 DROP → CREATE | 빠른 조회 | 전체 재계산 비용 | 중간 크기 마트 |
| **incremental** | 새 데이터만 추가/갱신 | 대용량 처리 효율적 | 복잡한 설정 | 이벤트 로그, 팩트 테이블 |
| **ephemeral** | CTE로 인라인 처리 | 물리 오브젝트 없음 | 재사용 불가 | 중간 변환 |

### Incremental 전략 심화

dbt-snowflake는 3가지 incremental 전략을 지원합니다:

```
append      → 새 행만 INSERT (중복 제거 없음)
merge       → unique_key 기준 MERGE (권장)
delete+insert → 파티션 삭제 후 INSERT
```

### Incremental 모델 핵심 패턴

```sql
{{
    config(
        materialized='incremental',
        unique_key='order_id',
        incremental_strategy='merge',
        cluster_by=['order_date']
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

### Snapshot (SCD Type 2)

원천 데이터의 **변경 이력**을 자동 추적합니다.

| dbt 자동 추가 컬럼 | 설명 |
|-------------------|------|
| `dbt_scd_id` | 각 행의 고유 해시 키 |
| `dbt_valid_from` | 이 버전이 유효해진 시각 |
| `dbt_valid_to` | NULL이면 현재 유효 버전 |
| `dbt_updated_at` | 행이 생성/갱신된 시각 |

---

## 실습

### Step 1: table vs view 차이 확인 (10분)

staging(view)을 기반으로 table materialization mart를 실행합니다.

```sql
-- dim_customers (table) 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='run --select dim_customers';
```

Snowsight에서 오브젝트 타입 확인:
```sql
-- staging: VIEW 타입이어야 함
SHOW VIEWS   IN SCHEMA dbt_workshop_db.workshop_staging;

-- marts: TABLE 타입이어야 함
SHOW TABLES  IN SCHEMA dbt_workshop_db.workshop_marts;
```

### Step 2: Incremental 모델 실행 (20분)

```sql
-- fct_orders (incremental) 첫 실행 — 전체 데이터 적재
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='run --select fct_orders';
```

로그에서 확인할 사항: `Creating table fct_orders`

```sql
-- 두 번째 실행 — incremental (빠름)
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='run --select fct_orders';
```

로그에서 확인할 사항: `Merging into table fct_orders`

```sql
-- 행 수 및 최신 날짜 확인
SELECT
    count(*)        AS row_count,
    max(order_date) AS max_date,
    min(order_date) AS min_date
FROM dbt_workshop_db.workshop_marts.fct_orders;
```

**incremental 모델 로직 수정 후 강제 전체 재처리:**

```sql
-- ⚠️ 모델 로직을 수정했다면 반드시 full-refresh 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='run --select fct_orders --full-refresh';
```

### Step 3: Snapshot으로 SCD Type 2 구현 (20분)

```sql
-- snapshot 초기 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='snapshot';
```

```sql
-- 결과 확인: dbt_valid_to IS NULL = 현재 유효 버전
SELECT
    customer_id,
    customer_name,
    market_segment,
    account_balance,
    dbt_valid_from,
    dbt_valid_to
FROM dbt_workshop_db.workshop_snapshots.snap_customers
ORDER BY customer_id, dbt_valid_from
LIMIT 20;

-- 현재 유효 버전 수
SELECT count(*) FROM dbt_workshop_db.workshop_snapshots.snap_customers
WHERE dbt_valid_to IS NULL;
```

---

## Materialization 선택 가이드

```
데이터 크기가 크고 매일 증분이 있다
    → incremental (merge 전략 권장)

변경 이력 추적이 필요하다
    → snapshot

집계·join이 무겁고 자주 읽힌다
    → table

가볍고 항상 최신 데이터여야 한다
    → view

중간 변환인데 물리 오브젝트로 만들기 애매하다
    → ephemeral
```

---

## 검증 체크리스트

- [ ] `dim_customers`: `workshop_marts` 스키마에 BASE TABLE로 생성됨
- [ ] `fct_orders`: 첫 실행 `Creating table`, 두 번째 실행 `Merging` 확인
- [ ] `snap_customers`: `workshop_snapshots` 스키마에 `dbt_valid_from/to` 컬럼 포함 확인
- [ ] `--full-refresh` 실행 후 행 수 변화 없음 확인

---

## 도전 과제

1. `fct_orders`의 `incremental_strategy`를 `delete+insert`로 변경하면 어떻게 동작이 달라지나요?  
   `--full-refresh` 없이도 정합성이 유지될까요?
2. `snap_customers`의 `strategy='check'`를 `strategy='timestamp'`로 바꾸면 무엇이 달라지나요?  
   어떤 컬럼이 추가로 필요한가요?
3. `ephemeral` 모델로 중간 변환 레이어(`int_orders_enriched`)를 만들고  
   `fct_orders`에서 참조해보세요. Snowflake에서 어떤 오브젝트가 생성되나요?

---

[← Lab 01](../lab01_project_setup/LAB.md) | [Lab 03 →](../lab03_jinja_macros/LAB.md)

# Lab 03: Jinja & 매크로

**소요 시간:** 약 60분  
**목표:** Jinja2 템플릿 문법과 dbt 매크로를 활용하여 재사용 가능하고 환경 적응형 SQL을 작성한다.

---

## 이론 (20분)

### Jinja2 in dbt

dbt 모델은 SQL + Jinja2 템플릿 엔진의 결합입니다.  
`compile` 단계에서 Jinja가 순수 SQL로 변환된 뒤 Snowflake에서 실행됩니다.

```
models/fct_orders.sql (Jinja SQL)
    ↓  compile
순수 SQL
    ↓  실행
Snowflake 테이블/뷰
```

**Jinja 기본 문법:**

| 문법 | 설명 | 예시 |
|------|------|------|
| `{{ expr }}` | 표현식 출력 | `{{ ref('stg_orders') }}` |
| `{% stmt %}` | 제어문 | `{% if is_incremental() %}` |
| `{# comment #}` | 주석 | `{# 임시 비활성화 #}` |

### dbt 기본 내장 함수

```sql
{{ ref('model_name') }}         -- 다른 모델 참조
{{ source('name', 'table') }}   -- 원천 테이블 참조
{{ this }}                      -- 현재 모델 자신 (incremental에서 사용)
{{ target.name }}               -- 현재 실행 target (dev/prod)
{{ var('my_var', 'default') }}  -- 런타임 변수
```

### 매크로(Macro)

`macros/` 폴더의 `.sql` 파일에 Jinja 함수를 정의합니다.

```sql
-- macros/safe_divide.sql
{% macro safe_divide(numerator, denominator) %}
    iff(
        {{ denominator }} = 0 or {{ denominator }} is null,
        null,
        {{ numerator }} / nullif({{ denominator }}, 0)
    )
{% endmacro %}

-- 사용
select {{ safe_divide('revenue', 'order_count') }} as avg_revenue
```

### dbt-utils 패키지

`packages.yml`에 선언하고 `snow dbt deploy` 시 함께 번들링됩니다.

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: 1.1.1
```

자주 쓰는 매크로:

| 매크로 | 설명 |
|--------|------|
| `dbt_utils.generate_surrogate_key(['col1', 'col2'])` | 복합키로 해시 SK 생성 |
| `dbt_utils.star(ref(...), except=[...])` | 특정 컬럼 제외하고 SELECT * |
| `dbt_utils.union_relations([...])` | 여러 테이블 UNION ALL |

---

## 실습

### Step 1: 컴파일 결과로 Jinja 동작 확인 (10분)

실제 실행 없이 Jinja가 어떻게 SQL로 변환되는지 확인합니다.

```sql
-- compile: 오브젝트 생성 없이 변환된 SQL만 반환
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='compile --select fct_revenue_by_nation';
```

출력된 SQL에서 확인할 사항:
- `{{ source('tpch', 'lineitem') }}` → 실제 테이블 경로로 치환됨
- `{{ ref('stg_orders') }}` → `dbt_workshop_db.workshop_staging.stg_orders`로 치환됨
- `{{ dbt_utils.generate_surrogate_key(...) }}` → `MD5(...)` SQL로 치환됨
- `{{ safe_divide(...) }}` → `IFF(... = 0, NULL, ...)` SQL로 치환됨

### Step 2: surrogate key를 활용한 팩트 테이블 실행 (15분)

```sql
-- fct_revenue_by_nation 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='run --select fct_revenue_by_nation';
```

```sql
-- 결과 확인
SELECT
    nation_name,
    region_name,
    sum(total_net_revenue)     AS total_revenue,
    sum(order_count)           AS total_orders,
    avg(avg_order_revenue)     AS avg_revenue_per_order
FROM dbt_workshop_db.workshop_marts.fct_revenue_by_nation
GROUP BY 1, 2
ORDER BY total_revenue DESC;
```

```sql
-- surrogate key가 고유한지 확인
SELECT
    count(*)                   AS total_rows,
    count(DISTINCT revenue_key) AS distinct_keys
FROM dbt_workshop_db.workshop_marts.fct_revenue_by_nation;
-- total_rows = distinct_keys 이어야 함
```

### Step 3: 런타임 변수(--vars) 활용 (15분)

모델에서 `{{ var('target_date') }}` 같은 런타임 변수를 사용할 수 있습니다.

**`solution/models/marts/fct_revenue_by_nation.sql`에 변수 추가 예시:**

```sql
-- 모델 내부에서 변수 사용
where orders.order_date >= '{{ var("start_date", "1992-01-01") }}'
```

```sql
-- 변수를 넘기면서 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='run --select fct_revenue_by_nation --vars {\"start_date\": \"1995-01-01\"}';
```

### Step 4: 매크로 동작 이해 (10분)

`solution/macros/` 폴더의 3개 매크로를 GitHub에서 확인합니다.

```sql
-- GitHub에서 매크로 파일 내용 확인
SELECT $1
FROM @dbt_workshop_db.workshop.dbt_workshop_repo/branches/main/lab03_jinja_macros/solution/macros/safe_divide.sql
    (FILE_FORMAT => (TYPE = 'CSV' FIELD_DELIMITER = NONE RECORD_DELIMITER = '\n'));
```

**`limit_in_dev` 매크로 — target 분기:**

```sql
{% macro limit_in_dev(row_limit=1000) %}
    {% if target.name != 'prod' %}
        limit {{ row_limit }}
    {% endif %}
{% endmacro %}
```

`target.name`이 `dev`이면 `LIMIT 1000`이 추가되고,  
`prod`이면 아무것도 추가되지 않습니다.

---

## 검증 체크리스트

- [ ] `compile` 결과에서 `{{ ref(...) }}`가 실제 테이블 경로로 치환됨 확인
- [ ] `compile` 결과에서 `{{ safe_divide(...) }}`가 `IFF(...)` SQL로 치환됨 확인
- [ ] `fct_revenue_by_nation` 실행 성공 및 `revenue_key` 컬럼이 MD5 해시값임 확인
- [ ] `total_rows = distinct_keys` (고유성 검증) 확인
- [ ] `--vars` 옵션으로 다른 날짜 범위 실행 결과 비교

---

## 도전 과제

1. `dbt_utils.star()` 매크로를 사용하여 `stg_lineitem`에서 `L_COMMENT` 컬럼을 제외한  
   나머지를 모두 SELECT하는 모델을 작성해보세요.
2. `format_currency` 매크로를 수정하여 통화 단위(USD, KRW 등)를  
   파라미터로 받아 컬럼 suffix에 붙이도록 개선해보세요.
3. `target.name == 'prod'` 조건을 활용해 개발 환경에서만  
   최근 3개월 데이터만 처리하는 모델을 작성해보세요.

---

[← Lab 02](../lab02_materialization/LAB.md) | [Lab 04 →](../lab04_testing/LAB.md)

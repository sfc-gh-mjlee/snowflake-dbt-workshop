# Lab 01: dbt 프로젝트 설정 & Git Integration

**소요 시간:** 약 45분  
**목표:** dbt 프로젝트 구조를 이해하고, Snowflake Git Integration을 통해 GitHub 저장소와 연결한다.  
첫 번째 staging 모델을 Snowsight에서 실행한다.

---

## 이론 (15분)

### Snowflake 네이티브 dbt 아키텍처

```
GitHub 저장소 (코드 편집)
    │  push
    ▼
Snowflake Git Repository Stage (코드 동기화)
    │  snow dbt deploy (강사/CI)
    ▼
DBT PROJECT 오브젝트 (Snowflake 내부)
    │  EXECUTE DBT PROJECT (Snowsight)
    ▼
결과 테이블/뷰 (dbt_workshop_db.workshop.*)
```

- **코드 편집**: GitHub 웹 에디터 또는 로컬 에디터
- **배포**: 강사 또는 GitHub Actions이 `snow dbt deploy` 1회 실행
- **실행**: 수강자가 Snowsight 워크시트에서 SQL로 실행
- **로컬 dbt 설치 불필요**

### dbt 프로젝트 핵심 구조

```
tpch_workshop/                ← 프로젝트 루트
├── dbt_project.yml           ← 프로젝트 전역 설정
├── profiles.yml              ← Snowflake 연결 설정 (credentials 없음!)
├── packages.yml              ← 외부 패키지 목록
├── models/
│   ├── staging/              ← 원천 → 표준화 레이어 (view)
│   └── marts/                ← 최종 분석 테이블 (table/incremental)
├── tests/                    ← Singular 테스트 SQL
├── macros/                   ← 재사용 Jinja 함수
└── snapshots/                ← SCD Type 2 이력 관리
```

### profiles.yml — Snowflake 네이티브 dbt 주의사항

Snowflake 네이티브 dbt에서 `profiles.yml`은 **프로젝트 폴더 내**에 위치하며,  
`password`, `authenticator`, `env_var()` 같은 인증 정보를 **절대 포함하지 않습니다**.  
Snowflake가 실행 컨텍스트에서 연결을 직접 처리합니다.

```yaml
# profiles.yml (dbt_project.yml과 같은 폴더에 위치)
tpch_workshop:
  target: dev
  outputs:
    dev:
      type: snowflake
      role: dbt_workshop_role
      warehouse: dbt_workshop_wh
      database: dbt_workshop_db
      schema: workshop
      threads: 4
```

### source() vs ref()

```sql
-- source(): sources.yml에 정의된 원천 테이블 참조
SELECT * FROM {{ source('tpch', 'orders') }}
-- → SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS

-- ref(): 다른 dbt 모델 참조 (DAG 의존성 자동 추적)
SELECT * FROM {{ ref('stg_orders') }}
-- → dbt_workshop_db.workshop.stg_orders
```

---

## 실습

### Step 1: Git Integration 확인 (5분)

Snowsight 워크시트에서 Git Repository가 정상 연결됐는지 확인합니다.

```sql
-- Git Repository 목록 확인
SHOW GIT REPOSITORIES IN SCHEMA dbt_workshop_db.workshop;

-- 최신 코드 동기화
ALTER GIT REPOSITORY dbt_workshop_db.workshop.dbt_workshop_repo FETCH;

-- 프로젝트 파일 목록 확인
LS @dbt_workshop_db.workshop.dbt_workshop_repo/branches/main/lab01_project_setup/solution/;
```

### Step 2: 배포된 프로젝트 확인 (5분)

```sql
-- 배포된 dbt 프로젝트 목록
SHOW DBT PROJECTS IN SCHEMA dbt_workshop_db.workshop;

-- 프로젝트 상세 정보
DESCRIBE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop;

-- 버전 목록
SHOW VERSIONS IN DBT PROJECT dbt_workshop_db.workshop.tpch_workshop;
```

### Step 3: dbt_project.yml & sources.yml 코드 리뷰 (10분)

GitHub에서 직접 파일을 읽어볼 수 있습니다.

```sql
-- dbt_project.yml 내용 확인
SELECT $1
FROM @dbt_workshop_db.workshop.dbt_workshop_repo/branches/main/lab01_project_setup/solution/dbt_project.yml
    (FILE_FORMAT => (TYPE = 'CSV' FIELD_DELIMITER = NONE RECORD_DELIMITER = '\n'));
```

**`dbt_project.yml` 핵심 설정:**

```yaml
models:
  tpch_workshop:
    staging:
      +materialized: view    # staging은 뷰로 생성
      +schema: staging
    marts:
      +materialized: table   # marts는 테이블로 생성
      +schema: marts
```

**`models/staging/_sources.yml` 핵심 설정:**

```yaml
sources:
  - name: tpch
    database: SNOWFLAKE_SAMPLE_DATA
    schema: TPCH_SF1
    tables:
      - name: orders
      - name: customer
      - name: lineitem
      ...
```

### Step 4: 첫 번째 모델 실행 (10분)

**staging 레이어만 실행:**

```sql
-- Snowsight 워크시트에서 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='run --select staging';
```

실행 결과 확인:
```sql
-- 생성된 뷰 목록 확인
SHOW VIEWS IN SCHEMA dbt_workshop_db.workshop_staging;

-- stg_orders 내용 미리보기
SELECT * FROM dbt_workshop_db.workshop_staging.stg_orders LIMIT 10;

-- 원천 데이터와 비교
SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS LIMIT 10;
-- 컬럼명이 표준화되었는지 확인 (O_ORDERKEY → order_id 등)
```

### Step 5: 소스 테스트 실행 (5분)

```sql
-- staging 테스트 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='test --select staging';
```

예상 출력:
```
PASS=10 WARN=0 ERROR=0 SKIP=0 TOTAL=10
```

### Step 6: 모델 미리보기 (5분)

오브젝트를 생성하지 않고 모델 결과를 미리 확인합니다.

```sql
-- show: 실제 테이블/뷰 생성 없이 결과만 미리보기
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop
    ARGS='show --select stg_orders';
```

---

## 스키마 명명 규칙 이해

`dbt_project.yml`의 `+schema` 설정에 따라 실제 생성 스키마가 결정됩니다.

| 설정 | profiles.yml schema | 실제 생성 스키마 |
|------|---------------------|-----------------|
| `+schema: staging` | `workshop` | `workshop_staging` |
| `+schema: marts` | `workshop` | `workshop_marts` |
| (없음) | `workshop` | `workshop` |

```sql
-- 생성된 모든 스키마 확인
SHOW SCHEMAS IN DATABASE dbt_workshop_db;
```

---

## 검증 체크리스트

- [ ] `SHOW DBT PROJECTS` 에서 `tpch_workshop` 확인
- [ ] `EXECUTE DBT PROJECT ... ARGS='run --select staging'` 성공
- [ ] `dbt_workshop_db.workshop_staging.stg_orders` 뷰 생성 확인
- [ ] `stg_orders` 컬럼명이 소문자 스네이크케이스로 변환됨 확인
- [ ] `EXECUTE DBT PROJECT ... ARGS='test --select staging'` PASS 확인

---

## 도전 과제

1. `stg_suppliers`, `stg_nations`, `stg_regions` 모델을 `solution/` 코드를 참고하여 직접 이해해보세요.  
   원천 컬럼명과 표준화된 컬럼명의 매핑 패턴을 파악하세요.
2. `EXECUTE DBT PROJECT ... ARGS='compile --select stg_orders'`를 실행하면 무슨 일이 일어날까요?  
   Jinja가 순수 SQL로 어떻게 변환되는지 확인해보세요.
3. `sources.yml`에 `loaded_at_field`와 `freshness` 설정을 추가하면 무엇을 할 수 있을까요?

---

[← 워크샵 홈](../README.md) | [Lab 02 →](../lab02_materialization/LAB.md)

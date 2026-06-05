# Lab 01: dbt 프로젝트 설정 & Snowflake 연동

**소요 시간:** 약 45분  
**목표:** dbt 프로젝트를 처음부터 구성하고, Snowflake에 연결하여 첫 번째 staging 모델을 실행한다.

---

## 이론 (15분)

### dbt 프로젝트 핵심 구조

```
my_dbt_project/
├── dbt_project.yml        ← 프로젝트 전역 설정 (이름, 경로, materialization 기본값 등)
├── profiles.yml           ← 연결 정보 (보통 ~/.dbt/profiles.yml 에 위치)
├── packages.yml           ← 외부 패키지 목록
├── models/                ← SQL 모델 파일들
│   ├── staging/           ← 원천 → 표준화 레이어
│   ├── intermediate/      ← 재사용 가능한 중간 변환
│   └── marts/             ← 최종 분석 테이블
├── tests/                 ← Singular 테스트 SQL
├── macros/                ← 재사용 가능한 Jinja 함수
├── snapshots/             ← SCD Type 2 스냅샷
└── seeds/                 ← 정적 CSV 데이터
```

### 레이어 설계 원칙

| 레이어 | 역할 | Materialization |
|--------|------|-----------------|
| **Staging** | 원천 1:1 매핑, 컬럼명/타입 표준화 | view (기본) |
| **Intermediate** | 비즈니스 로직 캡슐화, join 처리 | view or ephemeral |
| **Marts** | BI/분석가 직접 사용, 집계·팩트·디멘전 | table or incremental |

### Snowflake 연결 방식

dbt는 `profiles.yml`에서 연결 정보를 읽습니다.

```yaml
# ~/.dbt/profiles.yml
my_project:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: <org>-<account>        # ex) myorg-myaccount
      user: dbt_workshop_user
      password: Workshop1234!
      role: dbt_workshop_role
      warehouse: dbt_workshop_wh
      database: dbt_workshop_db
      schema: dev_<your_name>         # 개인 스키마로 격리
      threads: 4
```

> **Tip:** `account` 형식은 Snowflake URL에서 확인:  
> `https://<account>.snowflakecomputing.com` → `account` 값은 `<account>`

### source() vs ref()

```sql
-- source(): 원천 데이터 참조 (sources.yml에 정의된 테이블)
SELECT * FROM {{ source('tpch', 'orders') }}

-- ref(): 다른 dbt 모델 참조 (DAG 의존성 자동 추적)
SELECT * FROM {{ ref('stg_orders') }}
```

---

## 실습

### Step 1: 프로젝트 초기화 (5분)

```bash
# 작업 디렉토리로 이동
cd ~/projects

# dbt 프로젝트 초기화
dbt init tpch_workshop

# 생성된 구조 확인
cd tpch_workshop
ls -la
```

`dbt init` 실행 시 인터랙티브 프롬프트:
- **database adapter** → `snowflake` 선택
- 나머지 연결 정보 입력

### Step 2: dbt_project.yml 수정 (5분)

`dbt_project.yml`을 아래와 같이 수정하세요:

```yaml
name: 'tpch_workshop'
version: '1.0.0'
config-version: 2

profile: 'tpch_workshop'

model-paths: ["models"]
test-paths: ["tests"]
snapshot-paths: ["snapshots"]
macro-paths: ["macros"]
seed-paths: ["seeds"]

target-path: "target"
clean-targets: ["target", "dbt_packages"]

models:
  tpch_workshop:
    staging:
      +materialized: view
      +schema: staging
    marts:
      +materialized: table
      +schema: marts
```

> **포인트:** `+schema: staging` 설정 시 실제 생성 스키마는  
> `<profile_schema>_staging` 형식이 됩니다 (ex: `dev_mjlee_staging`)

### Step 3: profiles.yml 설정 (5분)

`~/.dbt/profiles.yml` 파일을 생성/수정합니다:

```yaml
tpch_workshop:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: "<YOUR_ACCOUNT>"      # ← 본인 계정으로 변경
      user: dbt_workshop_user
      password: Workshop1234!
      role: dbt_workshop_role
      warehouse: dbt_workshop_wh
      database: dbt_workshop_db
      schema: "dev_{{ env_var('DBT_USER', 'default') }}"
      threads: 4
      client_session_keep_alive: False
```

```bash
# 연결 테스트
dbt debug
```

예상 출력:
```
All checks passed!
```

### Step 4: sources.yml 작성 (10분)

`models/staging/_sources.yml` 파일을 생성합니다:

```yaml
version: 2

sources:
  - name: tpch
    description: "TPC-H 벤치마크 데이터셋 (Snowflake 샘플 DB)"
    database: SNOWFLAKE_SAMPLE_DATA
    schema: TPCH_SF1
    tables:
      - name: orders
        description: "주문 헤더 테이블 (150만 건)"
        columns:
          - name: O_ORDERKEY
            description: "주문 고유 키"
            tests:
              - unique
              - not_null
          - name: O_CUSTKEY
            description: "고객 FK"
          - name: O_ORDERSTATUS
            description: "주문 상태 (O=Open, F=Fulfilled, P=Partial)"
          - name: O_TOTALPRICE
            description: "주문 총액"
          - name: O_ORDERDATE
            description: "주문 일자"

      - name: customer
        description: "고객 마스터 테이블 (15만 건)"
        columns:
          - name: C_CUSTKEY
            description: "고객 고유 키"
            tests:
              - unique
              - not_null
          - name: C_NAME
            description: "고객명"
          - name: C_ACCTBAL
            description: "계좌 잔액"
          - name: C_MKTSEGMENT
            description: "시장 세그먼트"
          - name: C_NATIONKEY
            description: "국가 FK"

      - name: lineitem
        description: "주문 상세 라인 테이블 (600만 건)"
        columns:
          - name: L_ORDERKEY
            description: "주문 FK"
          - name: L_PARTKEY
            description: "부품 FK"
          - name: L_SUPPKEY
            description: "공급업체 FK"
          - name: L_QUANTITY
            description: "수량"
          - name: L_EXTENDEDPRICE
            description: "확장 가격 (수량 × 단가)"
          - name: L_DISCOUNT
            description: "할인율 (0.00 ~ 0.10)"
          - name: L_SHIPDATE
            description: "배송일"

      - name: supplier
        description: "공급업체 마스터 (1만 건)"
        columns:
          - name: S_SUPPKEY
            tests:
              - unique
              - not_null
          - name: S_NAME
          - name: S_NATIONKEY

      - name: nation
        description: "국가 코드 테이블 (25건)"
        columns:
          - name: N_NATIONKEY
            tests:
              - unique
              - not_null
          - name: N_NAME
          - name: N_REGIONKEY

      - name: region
        description: "지역 코드 테이블 (5건)"
        columns:
          - name: R_REGIONKEY
            tests:
              - unique
              - not_null
          - name: R_NAME
```

### Step 5: Staging 모델 작성 (10분)

**`models/staging/stg_orders.sql`**

```sql
with source as (
    select * from {{ source('tpch', 'orders') }}
),

renamed as (
    select
        -- PK
        o_orderkey       as order_id,

        -- FK
        o_custkey        as customer_id,

        -- 속성
        o_orderstatus    as order_status,
        o_totalprice     as order_total_price,
        o_orderdate      as order_date,
        o_orderpriority  as order_priority,
        o_clerk          as clerk_name,
        o_shippriority   as ship_priority,
        o_comment        as order_comment

    from source
)

select * from renamed
```

**`models/staging/stg_customers.sql`**

```sql
with source as (
    select * from {{ source('tpch', 'customer') }}
),

renamed as (
    select
        -- PK
        c_custkey        as customer_id,

        -- FK
        c_nationkey      as nation_id,

        -- 속성
        c_name           as customer_name,
        c_address        as customer_address,
        c_phone          as phone_number,
        c_acctbal        as account_balance,
        c_mktsegment     as market_segment,
        c_comment        as customer_comment

    from source
)

select * from renamed
```

### Step 6: 모델 실행 & 확인 (5분)

```bash
# staging 레이어만 실행
dbt run --select staging

# 소스 테스트 실행
dbt test --select source:tpch

# 문서 생성 및 확인
dbt docs generate
dbt docs serve
```

브라우저에서 `http://localhost:8080` 접속 → DAG 및 컬럼 설명 확인

---

## 검증 체크리스트

- [ ] `dbt debug` 성공 (All checks passed)
- [ ] `dbt run --select staging` 성공 (2개 모델 생성)
- [ ] Snowflake에서 `DEV_<NAME>_STAGING.STG_ORDERS` 뷰 확인
- [ ] `dbt test --select source:tpch` 성공
- [ ] `dbt docs serve`로 lineage 그래프 확인

---

## 도전 과제

1. `stg_suppliers.sql`, `stg_nations.sql`, `stg_regions.sql`을 직접 작성해보세요.
2. `profiles.yml`에서 `schema`를 환경변수로 관리하도록 수정해보세요.  
   (`DBT_USER` 환경변수 활용)
3. `dbt source freshness` 명령어를 실행하려면 sources.yml에 무엇을 추가해야 할까요?

---

[← 워크샵 홈](../README.md) | [Lab 02 →](../lab02_materialization/LAB.md)

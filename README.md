# dbt on Snowflake 워크샵

중급~고급 데이터 엔지니어/분석가를 위한 핸즈온 워크샵입니다.  
Snowflake 샘플 데이터(`SNOWFLAKE_SAMPLE_DATA.TPCH_SF1`)를 활용하여  
실제 운영 수준의 dbt 프로젝트를 단계적으로 구축합니다.

---

## 워크샵 구성

| Lab | 주제 | 소요 시간 |
|-----|------|-----------|
| [Lab 01](./lab01_project_setup/LAB.md) | 프로젝트 설정 & Snowflake 연동 | ~45분 |
| [Lab 02](./lab02_materialization/LAB.md) | Materialization 심화 | ~60분 |
| [Lab 03](./lab03_jinja_macros/LAB.md) | Jinja & 매크로 | ~60분 |
| [Lab 04](./lab04_testing/LAB.md) | 테스트 & 데이터 품질 | ~45분 |
| [Lab 05](./lab05_cicd/LAB.md) | CI/CD & 배포 | ~45분 |

---

## 사전 요구 사항

### 1. 도구 설치

```bash
# Python 3.9+ 확인
python --version

# dbt-snowflake 설치
pip install dbt-snowflake

# 설치 확인
dbt --version
```

### 2. Snowflake 계정 준비

워크샵에서 사용할 Snowflake 리소스를 생성합니다.  
아래 SQL을 Snowflake 워크시트에서 실행하세요 (ACCOUNTADMIN 권한 필요):

```sql
-- 워크샵 전용 역할 & 유저 생성
CREATE ROLE IF NOT EXISTS dbt_workshop_role;
CREATE USER IF NOT EXISTS dbt_workshop_user
    PASSWORD = 'Workshop1234!'
    DEFAULT_ROLE = dbt_workshop_role
    DEFAULT_WAREHOUSE = dbt_workshop_wh;

-- 웨어하우스 생성
CREATE WAREHOUSE IF NOT EXISTS dbt_workshop_wh
    WAREHOUSE_SIZE = 'X-SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE;

-- 데이터베이스 생성
CREATE DATABASE IF NOT EXISTS dbt_workshop_db;

-- 권한 부여
GRANT ROLE dbt_workshop_role TO USER dbt_workshop_user;
GRANT USAGE ON WAREHOUSE dbt_workshop_wh TO ROLE dbt_workshop_role;
GRANT ALL ON DATABASE dbt_workshop_db TO ROLE dbt_workshop_role;
GRANT USAGE ON DATABASE SNOWFLAKE_SAMPLE_DATA TO ROLE dbt_workshop_role;
GRANT USAGE ON SCHEMA SNOWFLAKE_SAMPLE_DATA.TPCH_SF1 TO ROLE dbt_workshop_role;
GRANT SELECT ON ALL TABLES IN SCHEMA SNOWFLAKE_SAMPLE_DATA.TPCH_SF1 TO ROLE dbt_workshop_role;
```

### 3. 샘플 데이터 구조 이해

이 워크샵은 TPC-H 벤치마크 데이터셋을 사용합니다.

```
SNOWFLAKE_SAMPLE_DATA.TPCH_SF1
├── CUSTOMER   (150,000 rows)  -- 고객 정보
├── ORDERS     (1,500,000 rows) -- 주문 헤더
├── LINEITEM   (6,001,215 rows) -- 주문 상세
├── SUPPLIER   (10,000 rows)   -- 공급업체
├── PART       (200,000 rows)  -- 부품
├── PARTSUPP   (800,000 rows)  -- 부품-공급업체 매핑
├── NATION     (25 rows)       -- 국가
└── REGION     (5 rows)        -- 지역
```

**ERD 요약:**
```
REGION ──< NATION ──< CUSTOMER ──< ORDERS ──< LINEITEM >── PART
                  └──< SUPPLIER >────────────────────────── PARTSUPP
```

---

## 최종 목표 아키텍처 (Layered Data Warehouse)

```
Source (SNOWFLAKE_SAMPLE_DATA)
    │
    ▼
[Staging Layer]          -- 원천 데이터를 그대로 가져오되 컬럼명/타입 표준화
stg_orders
stg_customers
stg_lineitem
stg_suppliers
stg_nations
stg_regions
    │
    ▼
[Intermediate Layer]     -- 재사용 가능한 비즈니스 로직 조각
int_orders_enriched
    │
    ▼
[Marts Layer]            -- 분석가/BI 도구가 직접 사용하는 테이블
dim_customers
dim_suppliers
fct_orders
fct_revenue_by_nation
```

---

## 각 Lab solution 디렉토리 안내

각 Lab 폴더의 `solution/` 디렉토리에는 완성된 코드가 들어 있습니다.  
먼저 직접 작성해보고, 막히면 참고하세요.

---

## 유용한 dbt 명령어 빠른 참조

```bash
dbt debug                    # 연결 테스트
dbt run                      # 모든 모델 실행
dbt run --select staging     # staging 폴더만 실행
dbt run --select +fct_orders # fct_orders와 upstream 모두 실행
dbt test                     # 모든 테스트 실행
dbt build                    # run + test 동시 실행
dbt docs generate            # 문서 생성
dbt docs serve               # 문서 브라우저에서 열기
dbt snapshot                 # 스냅샷 실행
dbt source freshness         # 소스 신선도 확인
```

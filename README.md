# dbt on Snowflake 워크샵

중급~고급 데이터 엔지니어/분석가를 위한 핸즈온 워크샵입니다.  
Snowflake 샘플 데이터(`SNOWFLAKE_SAMPLE_DATA.TPCH_SF1`)를 활용하여  
실제 운영 수준의 dbt 프로젝트를 단계적으로 구축합니다.

> **이 워크샵은 Snowflake 네이티브 dbt를 사용합니다.**  
> dbt가 Snowflake 내부에서 실행되므로 로컬에 dbt 설치가 필요 없습니다.  
> 실습은 **Snowsight 워크시트**에서 SQL만으로 진행합니다.

---

## 워크샵 구성

| Lab | 주제 | 소요 시간 |
|-----|------|-----------|
| [Lab 01](./lab01_project_setup/LAB.md) | 프로젝트 설정 & Git Integration | ~45분 |
| [Lab 02](./lab02_materialization/LAB.md) | Materialization 심화 | ~60분 |
| [Lab 03](./lab03_jinja_macros/LAB.md) | Jinja & 매크로 | ~60분 |
| [Lab 04](./lab04_testing/LAB.md) | 테스트 & 데이터 품질 | ~45분 |
| [Lab 05](./lab05_cicd/LAB.md) | 스케줄링 & 자동 배포 | ~45분 |

---

## 사전 요구 사항

### 1. 도구 (수강자)

**별도 설치 불필요** — Snowsight 접속만 있으면 됩니다.

- Snowflake 계정 접속 URL 및 사용자 정보 (강사 제공)
- 웹 브라우저 (Chrome / Firefox 권장)

> 강사는 사전에 dbt 프로젝트를 배포해 둡니다. 배포 방법은 [강사 가이드](#강사-가이드-사전-배포)를 참고하세요.

---

### 2. Snowflake 환경 설정 (ACCOUNTADMIN 필요)

Snowsight 워크시트에서 아래 SQL을 실행합니다.

```sql
-- ① 역할 & 웨어하우스 & DB 생성
CREATE ROLE      IF NOT EXISTS dbt_workshop_role;
CREATE WAREHOUSE IF NOT EXISTS dbt_workshop_wh
    WAREHOUSE_SIZE = 'X-SMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;
CREATE DATABASE  IF NOT EXISTS dbt_workshop_db;
CREATE SCHEMA    IF NOT EXISTS dbt_workshop_db.workshop;

-- ② 권한 부여
GRANT ROLE dbt_workshop_role TO ROLE SYSADMIN;
GRANT USAGE  ON WAREHOUSE dbt_workshop_wh                      TO ROLE dbt_workshop_role;
GRANT ALL    ON DATABASE  dbt_workshop_db                      TO ROLE dbt_workshop_role;
GRANT ALL    ON SCHEMA    dbt_workshop_db.workshop             TO ROLE dbt_workshop_role;
GRANT USAGE  ON DATABASE  SNOWFLAKE_SAMPLE_DATA                TO ROLE dbt_workshop_role;
GRANT USAGE  ON SCHEMA    SNOWFLAKE_SAMPLE_DATA.TPCH_SF1       TO ROLE dbt_workshop_role;
GRANT SELECT ON ALL TABLES IN SCHEMA SNOWFLAKE_SAMPLE_DATA.TPCH_SF1 TO ROLE dbt_workshop_role;
```

---

### 3. Git Integration 설정 (ACCOUNTADMIN 필요)

GitHub 저장소를 Snowflake에 연결합니다.

```sql
-- ① GitHub Personal Access Token을 Secret으로 저장
CREATE OR REPLACE SECRET dbt_workshop_db.workshop.github_token
    TYPE = GENERIC_STRING
    SECRET_STRING = '<GitHub PAT 입력>';  -- repo 권한 필요

-- ② API Integration 생성
CREATE OR REPLACE API INTEGRATION dbt_workshop_git_api
    API_PROVIDER = git_https_api
    API_ALLOWED_PREFIXES = ('https://github.com/sfc-gh-mjlee/')
    ALLOWED_AUTHENTICATION_SECRETS = (dbt_workshop_db.workshop.github_token)
    ENABLED = TRUE;

-- ③ Git Repository Stage 생성
CREATE OR REPLACE GIT REPOSITORY dbt_workshop_db.workshop.dbt_workshop_repo
    API_INTEGRATION = dbt_workshop_git_api
    GIT_CREDENTIALS = dbt_workshop_db.workshop.github_token
    ORIGIN = 'https://github.com/sfc-gh-mjlee/snowflake-dbt-workshop.git';

-- ④ 최신 코드 동기화
ALTER GIT REPOSITORY dbt_workshop_db.workshop.dbt_workshop_repo FETCH;

-- ⑤ 파일 목록 확인
LS @dbt_workshop_db.workshop.dbt_workshop_repo/branches/main/;
```

---

### 4. 샘플 데이터 구조 이해

이 워크샵은 TPC-H 벤치마크 데이터셋을 사용합니다.

```
SNOWFLAKE_SAMPLE_DATA.TPCH_SF1
├── CUSTOMER   (150,000 rows)   -- 고객 정보
├── ORDERS     (1,500,000 rows) -- 주문 헤더
├── LINEITEM   (6,001,215 rows) -- 주문 상세
├── SUPPLIER   (10,000 rows)    -- 공급업체
├── PART       (200,000 rows)   -- 부품
├── PARTSUPP   (800,000 rows)   -- 부품-공급업체 매핑
├── NATION     (25 rows)        -- 국가
└── REGION     (5 rows)         -- 지역
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
[Staging Layer]          -- 원천 데이터 표준화 (view)
stg_orders / stg_customers / stg_lineitem / stg_suppliers
    │
    ▼
[Marts Layer]            -- 분석가/BI 도구가 직접 사용하는 테이블
dim_customers            (table)
fct_orders               (incremental)
fct_revenue_by_nation    (table)
snap_customers           (snapshot / SCD Type 2)
```

---

## 각 Lab solution 디렉토리 안내

각 Lab 폴더의 `solution/` 디렉토리에는 완성된 코드가 들어 있습니다.  
먼저 직접 작성해보고, 막히면 참고하세요.

---

## Snowsight에서 dbt 실행 — 빠른 참조

> 모든 명령은 **Snowsight 워크시트**에서 실행합니다.

```sql
-- 모든 모델 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='run';

-- 특정 레이어만 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='run --select staging';

-- 특정 모델 + upstream 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='run --select +fct_orders';

-- 테스트 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='test';

-- run + test 동시 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='build';

-- 스냅샷 실행
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='snapshot';

-- 문서 생성
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='docs generate';

-- 증분 모델 전체 재처리
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='run --full-refresh';

-- 배포된 프로젝트 목록 확인
SHOW DBT PROJECTS IN SCHEMA dbt_workshop_db.workshop;
```

---

## 강사 가이드: 사전 배포

수강자 실습 전, 강사가 dbt 프로젝트를 Snowflake에 배포합니다.  
로컬 PC 또는 GitHub Actions에서 1회 실행합니다.

```bash
# Snowflake CLI 설치 (강사 PC)
pip install snowflake-cli

# Snowflake 연결 설정
snow connection add

# GitHub 저장소 클론
git clone https://github.com/sfc-gh-mjlee/snowflake-dbt-workshop.git
cd snowflake-dbt-workshop/lab01_project_setup/solution

# dbt 프로젝트 배포
snow dbt deploy tpch_workshop \
  --source . \
  --database dbt_workshop_db \
  --schema workshop

# 배포 확인
snow dbt list --in schema workshop --database dbt_workshop_db
```

코드 변경 후 재배포도 동일한 명령어를 사용합니다 (새 버전으로 자동 등록).

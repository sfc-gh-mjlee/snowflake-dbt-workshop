# Lab 05: 스케줄링 & 자동 배포

**소요 시간:** 약 45분  
**목표:** Snowflake Task로 dbt 실행을 자동화하고, GitHub Actions로 코드 변경 시 프로젝트를 자동 배포하는 파이프라인을 구성한다.

---

## 이론 (20분)

### 전체 운영 워크플로우

```
개발자 코드 수정
    │ git push to main
    ▼
GitHub Actions
    │ snow dbt deploy (자동 배포)
    ▼
DBT PROJECT 오브젝트 업데이트 (Snowflake)
    │ Snowflake Task (스케줄)
    ▼
EXECUTE DBT PROJECT 자동 실행
    │
    ▼
결과 테이블 갱신
```

### Snowflake Task vs GitHub Actions 역할 분리

| 역할 | 도구 | 트리거 |
|------|------|--------|
| **코드 배포** | GitHub Actions | git push to main |
| **정기 실행** | Snowflake Task | CRON 스케줄 |
| **수동 실행** | Snowsight 워크시트 | 즉시 실행 |

### EXECUTE DBT PROJECT 문법 심화

```sql
-- 기본 실행
EXECUTE DBT PROJECT <db>.<schema>.<project> ARGS='<command>';

-- 특정 dbt 버전 지정
EXECUTE DBT PROJECT <db>.<schema>.<project>
    DBT_VERSION='1.9.4'
    ARGS='run';

-- 환경별 target 지정
EXECUTE DBT PROJECT <db>.<schema>.<project>
    ARGS='run --target prod';
```

---

## 실습

### Step 1: Snowflake Task로 정기 실행 설정 (15분)

**일별 자동 실행 Task 생성:**

```sql
-- ① 전체 빌드 Task (매일 06:00 UTC)
CREATE OR REPLACE TASK dbt_workshop_db.workshop.run_dbt_daily
    WAREHOUSE   = dbt_workshop_wh
    SCHEDULE    = 'USING CRON 0 6 * * * UTC'
    COMMENT     = 'dbt 워크샵 프로젝트 일별 실행'
AS
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='build';

-- ② Task 활성화 (기본은 비활성)
ALTER TASK dbt_workshop_db.workshop.run_dbt_daily RESUME;

-- ③ Task 상태 확인
SHOW TASKS IN SCHEMA dbt_workshop_db.workshop;
```

**Task 즉시 수동 실행 (테스트용):**

```sql
EXECUTE TASK dbt_workshop_db.workshop.run_dbt_daily;
```

**실행 이력 확인:**

```sql
SELECT
    name,
    state,
    scheduled_time,
    completed_time,
    error_message
FROM TABLE(
    INFORMATION_SCHEMA.TASK_HISTORY(
        TASK_NAME => 'run_dbt_daily',
        SCHEDULED_TIME_RANGE_START => dateadd('day', -1, current_timestamp())
    )
)
ORDER BY scheduled_time DESC;
```

### Step 2: 단계별 Task 체인 구성 (15분)

실제 운영에서는 단계별로 실행 순서를 제어합니다.

```sql
-- ① 소스 신선도 체크 Task (루트)
CREATE OR REPLACE TASK dbt_workshop_db.workshop.dbt_check_freshness
    WAREHOUSE = dbt_workshop_wh
    SCHEDULE  = 'USING CRON 0 5 * * * UTC'
AS
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='run --select staging';

-- ② Staging 완료 후 Marts 실행 (이전 Task 완료 시 트리거)
CREATE OR REPLACE TASK dbt_workshop_db.workshop.dbt_run_marts
    WAREHOUSE   = dbt_workshop_wh
    AFTER       dbt_workshop_db.workshop.dbt_check_freshness
AS
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='run --select marts';

-- ③ Marts 완료 후 테스트 실행
CREATE OR REPLACE TASK dbt_workshop_db.workshop.dbt_run_tests
    WAREHOUSE   = dbt_workshop_wh
    AFTER       dbt_workshop_db.workshop.dbt_run_marts
AS
EXECUTE DBT PROJECT dbt_workshop_db.workshop.tpch_workshop ARGS='test --store-failures';

-- ④ 전체 Task 체인 활성화
ALTER TASK dbt_workshop_db.workshop.dbt_run_tests    RESUME;
ALTER TASK dbt_workshop_db.workshop.dbt_run_marts    RESUME;
ALTER TASK dbt_workshop_db.workshop.dbt_check_freshness RESUME;

-- ⑤ Task 그래프 확인
SELECT *
FROM TABLE(INFORMATION_SCHEMA.TASK_DEPENDENTS(
    TASK_NAME => 'dbt_workshop_db.workshop.dbt_check_freshness',
    RECURSIVE => TRUE
));
```

### Step 3: GitHub Actions 자동 배포 설정 (10분)

`solution/.github/workflows/dbt_deploy.yml` 구조를 확인합니다.

```sql
-- GitHub에서 워크플로우 파일 확인
SELECT $1
FROM @dbt_workshop_db.workshop.dbt_workshop_repo/branches/main/lab05_cicd/solution/.github/workflows/dbt_deploy.yml
    (FILE_FORMAT => (TYPE = 'CSV' FIELD_DELIMITER = NONE RECORD_DELIMITER = '\n'));
```

**핵심 워크플로우 구조:**

```yaml
name: dbt Deploy to Snowflake

on:
  push:
    branches: [ main ]
    paths:
      - 'lab*/solution/**'   # dbt 관련 파일 변경 시만 실행

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Snowflake CLI
        run: pip install snowflake-cli

      - name: Configure Snowflake connection
        run: |
          snow connection add workshop \
            --account   ${{ secrets.SNOWFLAKE_ACCOUNT }} \
            --user      ${{ secrets.SNOWFLAKE_USER }} \
            --password  ${{ secrets.SNOWFLAKE_PASSWORD }} \
            --role      dbt_workshop_role \
            --warehouse dbt_workshop_wh \
            --database  dbt_workshop_db

      - name: Deploy dbt project
        run: |
          snow dbt deploy tpch_workshop \
            --source lab01_project_setup/solution \
            --database dbt_workshop_db \
            --schema workshop \
            --connection workshop

      - name: Verify deployment
        run: snow dbt list --in schema workshop --database dbt_workshop_db --connection workshop
```

**GitHub Secrets 설정 (저장소 → Settings → Secrets):**

```
SNOWFLAKE_ACCOUNT   : <org>-<account>
SNOWFLAKE_USER      : dbt_workshop_user
SNOWFLAKE_PASSWORD  : Workshop1234!
```

---

## 운영 모니터링

### 실행 로그 확인

```sql
-- 최근 dbt 실행 이력 (Task 기반)
SELECT
    name,
    state,
    scheduled_time,
    completed_time,
    datediff('second', scheduled_time, completed_time) AS duration_sec,
    error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => dateadd('day', -7, current_timestamp())
))
WHERE name LIKE '%DBT%'
ORDER BY scheduled_time DESC;
```

### Task 비활성화 (실습 종료 후)

```sql
-- 비용 발생 방지를 위해 Task 비활성화
ALTER TASK dbt_workshop_db.workshop.dbt_check_freshness SUSPEND;
ALTER TASK dbt_workshop_db.workshop.dbt_run_marts       SUSPEND;
ALTER TASK dbt_workshop_db.workshop.dbt_run_tests       SUSPEND;
ALTER TASK dbt_workshop_db.workshop.run_dbt_daily       SUSPEND;
```

---

## 검증 체크리스트

- [ ] `run_dbt_daily` Task 생성 및 RESUME 상태 확인
- [ ] `EXECUTE TASK` 수동 실행 성공
- [ ] Task 이력에서 실행 시간 확인
- [ ] 3단계 Task 체인 의존관계 확인 (`TASK_DEPENDENTS`)
- [ ] GitHub Actions 워크플로우 구조 이해
- [ ] 실습 종료 후 Task SUSPEND 완료

---

## 도전 과제

1. 실패 알림 Task를 추가해보세요.  
   `dbt_run_tests`가 실패하면 `SYSTEM$SEND_EMAIL()`로 알림을 보내는 Task를 연결하세요.
2. `DBT_VERSION='1.9.4'`를 `EXECUTE DBT PROJECT`에 추가하면 어떤 효과가 있나요?  
   버전을 고정하는 것이 왜 운영에서 중요한가요?
3. Snowflake Git Integration을 사용하면 GitHub Actions 없이도  
   코드 동기화를 할 수 있습니다. 어떤 SQL 명령으로 최신 코드를 가져올 수 있나요?

---

[← Lab 04](../lab04_testing/LAB.md) | [← 워크샵 홈](../README.md)

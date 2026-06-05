# Lab 05: CI/CD & 배포

**소요 시간:** 약 45분  
**목표:** dev/prod 환경 분리 전략을 구성하고, GitHub Actions를 활용한 dbt Slim CI 파이프라인을 구축한다.

---

## 이론 (20분)

### 환경 분리 전략

운영 수준의 dbt 프로젝트는 최소 dev/prod 두 환경을 분리합니다.

```
개발자 로컬
    │ dbt run --target dev
    ▼
dev_<name>_staging.*      (개발 스키마)
dev_<name>_marts.*

    CI (PR 오픈 시 자동 실행)
    │ dbt build --target ci --select state:modified+
    ▼
ci_<pr_number>_staging.*  (임시 스키마)
ci_<pr_number>_marts.*

    CD (main 브랜치 머지 후 자동 실행)
    │ dbt build --target prod
    ▼
prod_staging.*            (운영 스키마)
prod_marts.*
```

### Slim CI: state:modified+ 선택자

dbt의 가장 강력한 CI 최적화 기법입니다.

```bash
# 1. 현재 prod 상태를 artifacts로 다운로드
dbt ls --target prod   # manifest.json 생성

# 2. PR의 변경된 모델과 downstream만 실행
dbt build --select state:modified+
          --defer
          --state path/to/prod/artifacts/
```

**동작 원리:**
```
main branch (prod)
  stg_orders → fct_orders → rpt_monthly_sales  ← 변경 없음
  stg_customers → dim_customers               ← 변경 없음

PR branch
  stg_orders (변경됨!)
     ↓ state:modified+
  stg_orders → fct_orders → rpt_monthly_sales  ← 이것만 실행
```

**--defer 옵션:**  
CI에서 직접 실행하지 않는 upstream 모델은  
prod 환경의 테이블을 그대로 참조합니다. (CI 비용 절약)

### dbt Cloud vs dbt Core + GitHub Actions

| | dbt Cloud | dbt Core + GH Actions |
|---|---|---|
| **설정 난이도** | 낮음 (UI 기반) | 중간 (YAML 작성 필요) |
| **비용** | 유료 (무료 플랜 있음) | GitHub Actions 비용만 |
| **Slim CI** | 내장 지원 | 수동 구현 필요 |
| **스케줄링** | UI에서 클릭 | cron 직접 설정 |
| **CI 환경 격리** | 자동 | 수동 스키마 관리 |
| **적합한 케이스** | 소규모~중규모 팀 | 자체 인프라 선호 팀 |

### dbt Cloud Jobs 핵심 설정 (개요)

```
Job: Daily Production Run
├── Environment: Production
├── Commands:
│   ├── dbt source freshness
│   ├── dbt build --exclude tag:raw
│   └── dbt test --store-failures
├── Schedule: 0 6 * * * (매일 06:00 UTC)
├── Generate docs: ✅
└── Notifications: Slack #data-alerts

Job: CI Check (PR 기반)
├── Environment: CI
├── Trigger: Pull Request
├── Commands:
│   └── dbt build --select state:modified+ --defer --state last-successful
└── Fail fast: ✅
```

---

## 실습

### Step 1: profiles.yml 멀티 환경 설정 (5분)

**`~/.dbt/profiles.yml` (멀티 환경 버전)**

```yaml
tpch_workshop:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: "{{ env_var('SNOWFLAKE_ACCOUNT') }}"
      user: "{{ env_var('SNOWFLAKE_USER') }}"
      password: "{{ env_var('SNOWFLAKE_PASSWORD') }}"
      role: dbt_workshop_role
      warehouse: dbt_workshop_wh
      database: dbt_workshop_db
      schema: "dev_{{ env_var('DBT_USER', 'local') }}"
      threads: 4

    ci:
      type: snowflake
      account: "{{ env_var('SNOWFLAKE_ACCOUNT') }}"
      user: "{{ env_var('SNOWFLAKE_USER') }}"
      password: "{{ env_var('SNOWFLAKE_PASSWORD') }}"
      role: dbt_workshop_role
      warehouse: dbt_workshop_wh
      database: dbt_workshop_db
      schema: "ci_{{ env_var('PR_NUMBER', 'local') }}"  # PR별 격리
      threads: 8

    prod:
      type: snowflake
      account: "{{ env_var('SNOWFLAKE_ACCOUNT') }}"
      user: "{{ env_var('SNOWFLAKE_USER') }}"
      private_key_path: "{{ env_var('SNOWFLAKE_PRIVATE_KEY_PATH') }}"
      role: dbt_workshop_role
      warehouse: dbt_workshop_wh
      database: dbt_workshop_db
      schema: prod
      threads: 8
```

**로컬 환경 변수 설정 (.envrc 또는 .env 파일):**

```bash
# .env (git에 절대 커밋 금지! .gitignore에 추가 필수)
export SNOWFLAKE_ACCOUNT="myorg-myaccount"
export SNOWFLAKE_USER="dbt_workshop_user"
export SNOWFLAKE_PASSWORD="Workshop1234!"
export DBT_USER="mjlee"
```

### Step 2: .gitignore 설정 (5분)

**`.gitignore`** (dbt 프로젝트 루트):

```
# dbt
target/
dbt_packages/
logs/

# 환경변수 & 비밀
.env
.env.*
profiles.yml   # ~/.dbt/profiles.yml은 절대 repo에 넣지 마세요!
*.pem
*.p8

# OS
.DS_Store
*.swp
```

### Step 3: GitHub Actions - PR CI 워크플로우 (15분)

**`.github/workflows/dbt_ci.yml`**

```yaml
name: dbt CI

on:
  pull_request:
    branches: [ main ]
    paths:
      - 'models/**'
      - 'tests/**'
      - 'macros/**'
      - 'snapshots/**'
      - 'dbt_project.yml'
      - 'packages.yml'

env:
  DBT_PROFILES_DIR: ./
  SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
  SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
  SNOWFLAKE_PASSWORD: ${{ secrets.SNOWFLAKE_PASSWORD }}
  PR_NUMBER: ${{ github.event.pull_request.number }}

jobs:
  dbt-ci:
    name: dbt Build & Test
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - name: Checkout PR branch
        uses: actions/checkout@v4

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
          cache: 'pip'

      - name: Install dbt
        run: pip install dbt-snowflake==1.8.*

      - name: Install dbt packages
        run: dbt deps

      - name: Download prod artifacts (for Slim CI)
        # prod manifest를 캐시 또는 스토리지에서 다운로드
        # 실제 운영에서는 S3/GCS 또는 dbt Cloud artifact API 사용
        run: |
          mkdir -p ./prod-artifacts
          # 예시: AWS S3에서 다운로드
          # aws s3 cp s3://my-bucket/dbt/manifest.json ./prod-artifacts/
          echo '{"metadata": {}, "nodes": {}, "sources": {}}' > ./prod-artifacts/manifest.json

      - name: dbt debug (연결 확인)
        run: dbt debug --target ci

      - name: dbt build (Slim CI - 변경된 모델과 downstream만)
        run: |
          dbt build \
            --target ci \
            --select state:modified+ \
            --defer \
            --state ./prod-artifacts/ \
            --fail-fast

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: dbt-test-results-pr-${{ github.event.pull_request.number }}
          path: |
            target/run_results.json
            target/manifest.json

      - name: Cleanup CI schema
        if: always()
        run: |
          dbt run-operation drop_schema \
            --args "{schema: ci_${{ github.event.pull_request.number }}}" \
            --target ci
```

### Step 4: GitHub Actions - Production 배포 워크플로우 (10분)

**`.github/workflows/dbt_prod.yml`**

```yaml
name: dbt Production Deploy

on:
  push:
    branches: [ main ]
  schedule:
    - cron: '0 6 * * *'   # 매일 06:00 UTC 자동 실행

env:
  DBT_PROFILES_DIR: ./
  SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
  SNOWFLAKE_USER: ${{ secrets.SNOWFLAKE_USER }}
  SNOWFLAKE_PASSWORD: ${{ secrets.SNOWFLAKE_PASSWORD }}

jobs:
  dbt-production:
    name: dbt Production Run
    runs-on: ubuntu-latest
    timeout-minutes: 60
    environment: production   # GitHub Environment 보호 규칙 적용

    steps:
      - uses: actions/checkout@v4

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
          cache: 'pip'

      - name: Install dbt
        run: pip install dbt-snowflake==1.8.*

      - name: Install dbt packages
        run: dbt deps

      - name: dbt source freshness
        run: dbt source freshness --target prod
        continue-on-error: true   # freshness 실패해도 계속 진행 (경고만)

      - name: dbt build (전체)
        run: |
          dbt build \
            --target prod \
            --exclude tag:raw \
            --store-failures

      - name: dbt docs generate
        run: dbt docs generate --target prod

      - name: Upload artifacts to storage
        # prod manifest.json을 저장소에 업로드 (Slim CI에서 사용)
        run: |
          echo "Upload manifest.json to artifact storage"
          # aws s3 cp target/manifest.json s3://my-bucket/dbt/manifest.json

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: dbt-prod-artifacts
          path: |
            target/manifest.json
            target/run_results.json
            target/catalog.json
          retention-days: 30

      - name: Notify on failure
        if: failure()
        run: |
          echo "::error::dbt production run failed!"
          # curl -X POST ${{ secrets.SLACK_WEBHOOK_URL }} \
          #   -H 'Content-type: application/json' \
          #   --data '{"text":"dbt prod run FAILED! Check GitHub Actions."}'
```

### Step 5: drop_schema 매크로 추가 (CI 정리용) (5분)

**`macros/drop_schema.sql`**

```sql
{% macro drop_schema(schema) %}
    {% set sql %}
        DROP SCHEMA IF EXISTS {{ target.database }}.{{ schema }} CASCADE
    {% endset %}
    {% do run_query(sql) %}
    {{ log("Dropped schema: " ~ schema, info=True) }}
{% endmacro %}
```

---

## CI/CD 파이프라인 전체 흐름

```
개발자 작업
    │ git checkout -b feature/new-model
    │ # 모델 작성 및 로컬 dbt run
    │ git push origin feature/new-model
    ▼
GitHub PR 생성
    │ (자동 트리거)
    ▼
[CI: dbt_ci.yml]
    ├── dbt build --select state:modified+ --defer
    ├── 테스트 통과 ✅ → PR merge 가능
    └── 테스트 실패 ❌ → PR blocked, 수정 필요
    ▼
PR merge to main
    │ (자동 트리거)
    ▼
[CD: dbt_prod.yml]
    ├── dbt source freshness
    ├── dbt build --target prod
    ├── manifest.json S3 업로드 (다음 Slim CI에서 사용)
    └── 실패 시 Slack 알림
```

---

## GitHub Secrets 설정 방법

GitHub 저장소 → Settings → Secrets and variables → Actions:

```
SNOWFLAKE_ACCOUNT    : myorg-myaccount
SNOWFLAKE_USER       : dbt_workshop_user
SNOWFLAKE_PASSWORD   : Workshop1234!
SLACK_WEBHOOK_URL    : https://hooks.slack.com/...  (선택)
AWS_ACCESS_KEY_ID    : ...  (artifact 저장소 사용 시)
AWS_SECRET_ACCESS_KEY: ...
```

---

## 검증 체크리스트

- [ ] `profiles.yml`에 dev/ci/prod 3개 타겟 설정
- [ ] `.gitignore`에 `profiles.yml`, `.env`, `target/` 포함
- [ ] `dbt_ci.yml`: PR 트리거, `state:modified+`, `--defer` 옵션 포함
- [ ] `dbt_prod.yml`: `main` push 및 cron 트리거 포함
- [ ] `drop_schema` 매크로 작성 (CI 환경 정리용)
- [ ] GitHub Secrets 설정 방법 이해

---

## 도전 과제

1. `dbt_ci.yml`에 PR comment로 테스트 결과를 자동 게시하는 step을 추가해보세요.  
   (GitHub API 또는 `actions/github-script` 활용)
2. CI에서 `--fail-fast` 대신 `--no-fail-fast`를 사용하면 어떤 trade-off가 있나요?
3. dbt Cloud의 "Continuous Integration" 기능과 직접 구현한 GitHub Actions의 장단점을 정리해보세요.

---

[← Lab 04](../lab04_testing/LAB.md) | [← 워크샵 홈](../README.md)

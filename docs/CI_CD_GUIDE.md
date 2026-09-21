# CI/CD Pipeline Guide: Blueprint Agent

This guide describes the Continuous Integration and Continuous Deployment (CI/CD) pipelines configured for the **Blueprint Agent** repository.

The repository includes support for both **GitHub Actions** and **Google Cloud Build**, with dedicated stages for linting, pytest unit testing, pytest integration testing, container verification, staging deployment, and gated production deployment.

---

## Architecture Overview

```
                          ┌──────────────────────────┐
                          │   Developer PR / Push    │
                          └─────────────┬────────────┘
                                        │
                    ┌───────────────────┴───────────────────┐
                    ▼                                       ▼
       ┌─────────────────────────┐             ┌─────────────────────────┐
       │   GitHub Actions (CI)   │             │    Cloud Build (CI)     │
       │  .github/workflows/     │             │      .cloudbuild/       │
       │     pr_checks.yaml      │             │     pr_checks.yaml      │
       └────────────┬────────────┘             └────────────┬────────────┘
                    │                                       │
                    ├─ Ruff & Ty Linting                    ├─ Ruff & Ty Linting
                    ├─ Pytest Unit Tests                    ├─ Pytest Unit Tests
                    ├─ Pytest Integration Tests             ├─ Pytest Integration Tests
                    └─ Docker Image Build Check             └─ Docker Image Build Check
                                        │
                                  Merge to main
                                        │
                    ┌───────────────────┴───────────────────┐
                    ▼                                       ▼
       ┌─────────────────────────┐             ┌─────────────────────────┐
       │ Deploy to Staging (CD)  │             │ Deploy to Staging (CD)  │
       │  .github/workflows/     │             │      .cloudbuild/       │
       │       staging.yaml      │             │       staging.yaml      │
       └────────────┬────────────┘             └────────────┬────────────┘
                    │                                       │
                    │ Deploy Agent Runtime                  │ Deploy Agent Runtime
                    ▼                                       ▼
       ┌─────────────────────────┐             ┌─────────────────────────┐
       │ Deploy to Prod (Gated)  │             │ Deploy to Prod (Gated)  │
       │  .github/workflows/     │             │      .cloudbuild/       │
       │   deploy-to-prod.yaml   │             │   deploy-to-prod.yaml   │
       │  (Environment Approval) │             │   (Approval Required)   │
       └─────────────────────────┘             └─────────────────────────┘
```

---

## Option 1: GitHub Actions CI/CD Pipeline

The GitHub Actions implementation consists of modular workflows in `.github/workflows/` as well as a standalone all-in-one workflow mirroring `cloudbuild.yaml`:

### 1. Workflows

| Workflow | File | Trigger | Key Actions |
|---|---|---|---|
| **PR Checks (CI)** | [`.github/workflows/pr_checks.yaml`](file:///.github/workflows/pr_checks.yaml) | Pull Request to `main` | `ruff check`, `ty check`, `codespell`, `pytest tests/unit`, `pytest tests/integration`, Docker build |
| **Staging Deploy (CD)** | [`.github/workflows/staging.yaml`](file:///.github/workflows/staging.yaml) | Push/Merge to `main` | WIF Auth, `uvx google-agents-cli deploy` (Staging), verifies status, triggers Prod workflow |
| **Production Deploy (CD)** | [`.github/workflows/deploy-to-prod.yaml`](file:///.github/workflows/deploy-to-prod.yaml) | `workflow_call` or manual `workflow_dispatch` | Protected by `environment: production` (requires reviewer approval), deploys to Production Agent Runtime |
| **Standalone / All-in-One** | [`githubactions.yaml`](file:///githubactions.yaml) / [`.github/workflows/githubactions.yaml`](file:///.github/workflows/githubactions.yaml) | Push/PR to `main` or manual `workflow_dispatch` | Direct equivalent of `cloudbuild.yaml` with the exact same 6 sequential steps (`install-dependencies`, `lint`, `pytest-unit`, `pytest-integration`, `docker-build`, `deploy-agent-runtime`) |

### 2. Workload Identity Federation (WIF) Setup

GitHub Actions authenticates to Google Cloud without storing long-lived service account keys using Workload Identity Federation:

1. Create a Workload Identity Pool:
   ```bash
   gcloud iam workload-identity-pools create "blueprint-agent-pool" \
     --project="PROJECT_ID" \
     --location="global" \
     --display-name="GitHub Actions Pool"
   ```

2. Create an OIDC Provider:
   ```bash
   gcloud iam workload-identity-pools providers create-oidc "blueprint-agent-oidc" \
     --project="PROJECT_ID" \
     --location="global" \
     --workload-identity-pool="blueprint-agent-pool" \
     --display-name="GitHub OIDC Provider" \
     --issuer-uri="https://token.actions.githubusercontent.com" \
     --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
     --attribute-condition="attribute.repository == 'GITHUB_ORG/blueprint-agent'"
   ```

3. Grant the CI/CD Service Account `roles/iam.workloadIdentityUser` binding for the GitHub repository.

*(Note: If you use the provided Terraform module in `deployment/terraform/cicd/`, this is provisioned automatically.)*

### 3. Required GitHub Secrets & Variables

Configure the following in **GitHub Repository Settings > Secrets and variables > Actions**:

#### Variables (`vars`):
- `GCP_PROJECT_NUMBER`: GCP Project Number of the CI/CD project.
- `CICD_PROJECT_ID`: GCP Project ID where the CI/CD runner operates.
- `STAGING_PROJECT_ID`: GCP Project ID for Staging deployment.
- `PROD_PROJECT_ID`: GCP Project ID for Production deployment.
- `REGION`: Target GCP region (e.g. `us-central1`).
- `APP_SERVICE_ACCOUNT_STAGING`: Runtime Service Account email for staging (e.g., `blueprint-agent-app@STAGING_PROJECT.iam.gserviceaccount.com`).
- `APP_SERVICE_ACCOUNT_PROD`: Runtime Service Account email for production (e.g., `blueprint-agent-app@PROD_PROJECT.iam.gserviceaccount.com`).
- `LOGS_BUCKET_NAME_STAGING`: GCS Bucket for Staging telemetry/logs.
- `LOGS_BUCKET_NAME_PROD`: GCS Bucket for Production telemetry/logs.

#### Secrets (`secrets`):
- `WIF_POOL_ID`: Name of the WIF pool (e.g., `blueprint-agent-pool`).
- `WIF_PROVIDER_ID`: Name of the WIF provider (e.g., `blueprint-agent-oidc`).
- `GCP_SERVICE_ACCOUNT`: CI/CD Runner Service Account email (e.g., `blueprint-agent-cicd-runner@PROJECT_ID.iam.gserviceaccount.com`).

#### GitHub Environment Approval:
- Go to **Settings > Environments > production**.
- Enable **Required reviewers** and assign designated approval team members.

---

## Option 2: Google Cloud Build CI/CD Pipeline

The Cloud Build implementation provides config files in `.cloudbuild/` and a root `cloudbuild.yaml`:

### 1. Build Configurations

| Configuration | File | Purpose |
|---|---|---|
| **PR Checks** | [`.cloudbuild/pr_checks.yaml`](file:///.cloudbuild/pr_checks.yaml) | Validates PRs: `ruff`, `ty`, `codespell`, `pytest tests/unit`, `pytest tests/integration`, Docker build |
| **Staging Deployment** | [`.cloudbuild/staging.yaml`](file:///.cloudbuild/staging.yaml) | Triggered on `main` push: deploys to staging and triggers prod trigger with commit SHA |
| **Production Deployment** | [`.cloudbuild/deploy-to-prod.yaml`](file:///.cloudbuild/deploy-to-prod.yaml) | Production release trigger with `approval_config: approval_required: true` |
| **Standalone / All-in-One** | [`cloudbuild.yaml`](file:///cloudbuild.yaml) | Direct CLI build with `gcloud builds submit` |

### 2. Setting Up Cloud Build Triggers

1. **Connect GitHub Repository**:
   Connect your GitHub repository to Cloud Build using Cloud Build GitHub App (2nd-gen repository connection).

2. **Create PR Check Trigger**:
   ```bash
   gcloud builds triggers create github \
     --name="pr-blueprint-agent" \
     --region="us-central1" \
     --repo-name="blueprint-agent" \
     --repo-owner="YOUR_GITHUB_ORG" \
     --pull-request-pattern="^main$" \
     --build-config=".cloudbuild/pr_checks.yaml" \
     --service-account="projects/PROJECT_ID/serviceAccounts/blueprint-agent-cicd-runner@PROJECT_ID.iam.gserviceaccount.com"
   ```

3. **Create Staging CD Trigger**:
   ```bash
   gcloud builds triggers create github \
     --name="cd-blueprint-agent" \
     --region="us-central1" \
     --repo-name="blueprint-agent" \
     --repo-owner="YOUR_GITHUB_ORG" \
     --branch-pattern="^main$" \
     --build-config=".cloudbuild/staging.yaml" \
     --service-account="projects/PROJECT_ID/serviceAccounts/blueprint-agent-cicd-runner@PROJECT_ID.iam.gserviceaccount.com"
   ```

4. **Create Production Trigger with Manual Approval**:
   ```bash
   gcloud builds triggers create manual \
     --name="deploy-blueprint-agent" \
     --region="us-central1" \
     --build-config=".cloudbuild/deploy-to-prod.yaml" \
     --require-approval \
     --service-account="projects/PROJECT_ID/serviceAccounts/blueprint-agent-cicd-runner@PROJECT_ID.iam.gserviceaccount.com"
   ```

---

## Pytest Testing in CI/CD

The test suite in `tests/` is separated into unit and integration suites:

### Running Locally
```bash
# Run unit tests only (fast, no cloud/network dependency)
uv run pytest tests/unit -v

# Run integration tests (requires GCP credentials / Vertex AI access)
uv run pytest tests/integration -v

# Run all tests
uv run pytest tests/unit tests/integration -v
```

### Integration Test Configuration in CI/CD
The integration tests (`tests/integration/test_agent.py` and `tests/integration/test_server_e2e.py`) test the full ADK streaming pipeline and FastAPI/A2A endpoints.

In CI/CD pipelines, the following environment variables are supplied:
```bash
INTEGRATION_TEST=TRUE
GOOGLE_CLOUD_PROJECT=<PROJECT_ID>
GOOGLE_CLOUD_LOCATION=global
GOOGLE_GENAI_USE_ENTERPRISE=true
MODEL=gemini-3.5-flash-lite
```

---

## Automated Setup with gcloud (Direct Implementation on svc-project-gke02)

To provision and configure all services, service accounts, IAM roles, storage buckets, BigQuery telemetry, and WIF on `svc-project-gke02` using the `gcloud` CLI directly:

### 1. Run the Implementation Script
The automated script [`scripts/implement_gcloud.sh`](../scripts/implement_gcloud.sh) performs the entire setup:

```bash
PROJECT_ID=svc-project-gke02 REGION=us-central1 GITHUB_REPO=YOUR_GITHUB_ORG/blueprint-agent ./scripts/implement_gcloud.sh
```

### 2. Manual Step-by-Step with gcloud

If you prefer to run commands individually:

```bash
# 1. Set project
gcloud config set project svc-project-gke02

# 2. Enable APIs
gcloud services enable \
  aiplatform.googleapis.com \
  cloudbuild.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  bigqueryconnection.googleapis.com \
  logging.googleapis.com \
  cloudtrace.googleapis.com \
  monitoring.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  artifactregistry.googleapis.com \
  serviceusage.googleapis.com

# 3. Create Service Accounts
gcloud iam service-accounts create blueprint-agent-app \
  --display-name="Blueprint Agent Application Service Account"

gcloud iam service-accounts create blueprint-agent-cicd-runner \
  --display-name="Blueprint Agent CI/CD Runner Service Account"

# 4. Assign IAM Roles to App SA
for role in roles/aiplatform.user roles/logging.logWriter roles/cloudtrace.agent roles/storage.admin roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding svc-project-gke02 \
    --member="serviceAccount:blueprint-agent-app@svc-project-gke02.iam.gserviceaccount.com" \
    --role="$role"
done

# 5. Assign IAM Roles to CI/CD SA
for role in roles/cloudbuild.builds.builder roles/aiplatform.user roles/storage.admin roles/logging.logWriter roles/cloudtrace.agent roles/artifactregistry.writer roles/iam.serviceAccountUser roles/iam.serviceAccountTokenCreator; do
  gcloud projects add-iam-policy-binding svc-project-gke02 \
    --member="serviceAccount:blueprint-agent-cicd-runner@svc-project-gke02.iam.gserviceaccount.com" \
    --role="$role"
done

# 6. Create Buckets
gcloud storage buckets create gs://svc-project-gke02-blueprint-agent-logs \
  --project=svc-project-gke02 --location=us-central1 --uniform-bucket-level-access

gcloud storage buckets create gs://svc-project-gke02-terraform-state \
  --project=svc-project-gke02 --location=us-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://svc-project-gke02-terraform-state --versioning

# 7. Create BigQuery Dataset & Logging Sink
bq --project_id=svc-project-gke02 --location=us-central1 mk -d blueprint_agent_telemetry

gcloud logging sinks create blueprint-agent-genai-logs \
  bigquery.googleapis.com/projects/svc-project-gke02/datasets/blueprint_agent_telemetry \
  --log-filter='labels."event.name"="gen_ai.client.inference.operation.details" AND (labels."gen_ai.input.messages_ref" =~ ".*blueprint-agent.*" OR labels."gen_ai.output.messages_ref" =~ ".*blueprint-agent.*")' \
  --use-partitioned-tables

# 8. Deploy to Agent Runtime
./scripts/deploy_agent.sh
```

---

## Production Deployment Verification & Endpoints

The agent has been deployed to **Production Agent Runtime** in `svc-project-gke02` (us-central1):

| Resource | Value |
|---|---|
| **Project ID** | `svc-project-gke02` (Number: `887823107167`) |
| **Region** | `us-central1` |
| **Reasoning Engine ID** | `5604788560134668288` |
| **Full Resource ID** | `projects/887823107167/locations/us-central1/reasoningEngines/5604788560134668288` |
| **Service Account** | `blueprint-agent-app@svc-project-gke02.iam.gserviceaccount.com` |
| **Console URL** | [Vertex AI Agent Engine Console](https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/us-central1/agent-engines/5604788560134668288?project=svc-project-gke02) |
| **Agent Card URL** | `https://us-central1-aiplatform.googleapis.com/reasoningEngines/v1/projects/887823107167/locations/us-central1/reasoningEngines/5604788560134668288/api/a2a/blueprint_agent/.well-known/agent-card.json` |
| **A2A Endpoint** | `https://us-central1-aiplatform.googleapis.com/reasoningEngines/v1/projects/887823107167/locations/us-central1/reasoningEngines/5604788560134668288/api/a2a/blueprint_agent` |

### Testing the Production Deployment

#### 1. Fetch Agent Card:
```bash
TOKEN=$(gcloud auth print-access-token)
curl -s -H "Authorization: Bearer ${TOKEN}" \
  https://us-central1-aiplatform.googleapis.com/reasoningEngines/v1/projects/887823107167/locations/us-central1/reasoningEngines/5604788560134668288/api/a2a/blueprint_agent/.well-known/agent-card.json | jq .
```

#### 2. Query Agent (A2A JSON-RPC):
```bash
TOKEN=$(gcloud auth print-access-token)
curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "message/send",
    "params": {
      "message": {
        "messageId": "msg-001",
        "role": "user",
        "parts": [{"text": "What is the weather in Tokyo?"}]
      }
    },
    "id": 1
  }' \
  https://us-central1-aiplatform.googleapis.com/reasoningEngines/v1/projects/887823107167/locations/us-central1/reasoningEngines/5604788560134668288/api/a2a/blueprint_agent | jq .
```

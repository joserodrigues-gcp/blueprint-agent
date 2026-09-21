#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ==============================================================================
# Blueprint Agent: GCP Infrastructure & CI/CD Setup Script using gcloud
# Target Project: svc-project-gke02
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration Variables
# ------------------------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:-svc-project-gke02}"
REGION="${REGION:-us-central1}"
PROJECT_NAME="blueprint-agent"
APP_SA_NAME="${PROJECT_NAME}-app"
APP_SA_EMAIL="${APP_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CICD_SA_NAME="${PROJECT_NAME}-cicd-runner"
CICD_SA_EMAIL="${CICD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
LOGS_BUCKET="${PROJECT_ID}-${PROJECT_NAME}-logs"
STATE_BUCKET="${PROJECT_ID}-terraform-state"
BQ_DATASET="${PROJECT_NAME//-/_}_telemetry"
WIF_POOL_NAME="${PROJECT_NAME}-pool"
WIF_PROVIDER_NAME="${PROJECT_NAME}-oidc"
GITHUB_REPO="${GITHUB_REPO:-YOUR_GITHUB_ORG/blueprint-agent}"

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

echo "=============================================================================="
echo " Setting up Blueprint Agent Infrastructure & CI/CD using gcloud"
echo " Project: ${PROJECT_ID} | Region: ${REGION}"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Set Project Context
# ------------------------------------------------------------------------------
log_info "Configuring active gcloud project to ${PROJECT_ID}..."
gcloud config set project "${PROJECT_ID}" --quiet

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
log_info "Project Number: ${PROJECT_NUMBER}"

# ------------------------------------------------------------------------------
# 2. Enable Required APIs
# ------------------------------------------------------------------------------
log_info "Enabling required Google Cloud APIs..."
SERVICES=(
  "aiplatform.googleapis.com"
  "cloudbuild.googleapis.com"
  "storage.googleapis.com"
  "bigquery.googleapis.com"
  "bigqueryconnection.googleapis.com"
  "logging.googleapis.com"
  "cloudtrace.googleapis.com"
  "monitoring.googleapis.com"
  "iam.googleapis.com"
  "iamcredentials.googleapis.com"
  "sts.googleapis.com"
  "artifactregistry.googleapis.com"
  "serviceusage.googleapis.com"
)

gcloud services enable "${SERVICES[@]}" --project="${PROJECT_ID}"
log_success "All required Google Cloud APIs enabled."

# ------------------------------------------------------------------------------
# 3. Create Service Accounts
# ------------------------------------------------------------------------------
log_info "Creating Service Accounts..."

# Application Service Account
if gcloud iam service-accounts describe "${APP_SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  log_info "App Service Account ${APP_SA_EMAIL} already exists."
else
  gcloud iam service-accounts create "${APP_SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Blueprint Agent Application Service Account" \
    --description="Runtime identity for Blueprint Agent on Agent Runtime"
  log_success "Created App Service Account: ${APP_SA_EMAIL}"
fi

# CI/CD Runner Service Account
if gcloud iam service-accounts describe "${CICD_SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  log_info "CI/CD Runner Service Account ${CICD_SA_EMAIL} already exists."
else
  gcloud iam service-accounts create "${CICD_SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Blueprint Agent CI/CD Runner Service Account" \
    --description="Identity for executing CI/CD pipelines in Cloud Build and GitHub Actions"
  log_success "Created CI/CD Runner Service Account: ${CICD_SA_EMAIL}"
fi

# ------------------------------------------------------------------------------
# 4. Assign IAM Roles
# ------------------------------------------------------------------------------
log_info "Assigning IAM roles..."

# App Service Account roles
APP_ROLES=(
  "roles/aiplatform.user"
  "roles/logging.logWriter"
  "roles/cloudtrace.agent"
  "roles/storage.admin"
  "roles/serviceusage.serviceUsageConsumer"
)

for role in "${APP_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${APP_SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet &>/dev/null
done
log_success "Assigned roles to App Service Account (${APP_SA_EMAIL})."

# CI/CD Runner Service Account roles
CICD_ROLES=(
  "roles/cloudbuild.builds.builder"
  "roles/aiplatform.user"
  "roles/storage.admin"
  "roles/logging.logWriter"
  "roles/cloudtrace.agent"
  "roles/artifactregistry.writer"
  "roles/iam.serviceAccountUser"
  "roles/iam.serviceAccountTokenCreator"
)

for role in "${CICD_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CICD_SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet &>/dev/null
done
log_success "Assigned roles to CI/CD Runner Service Account (${CICD_SA_EMAIL})."

# ------------------------------------------------------------------------------
# 5. Create Cloud Storage Buckets
# ------------------------------------------------------------------------------
log_info "Provisioning Cloud Storage buckets..."

# Logs & Telemetry Bucket
if gcloud storage buckets describe "gs://${LOGS_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
  log_info "Logs bucket gs://${LOGS_BUCKET} already exists."
else
  gcloud storage buckets create "gs://${LOGS_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --default-storage-class=STANDARD
  log_success "Created bucket: gs://${LOGS_BUCKET}"
fi

# Terraform State Bucket (versioned)
if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
  log_info "Terraform state bucket gs://${STATE_BUCKET} already exists."
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --default-storage-class=STANDARD
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
  log_success "Created versioned state bucket: gs://${STATE_BUCKET}"
fi

# Grant App SA and CI/CD SA access to logs bucket
gcloud storage buckets add-iam-policy-binding "gs://${LOGS_BUCKET}" \
  --member="serviceAccount:${APP_SA_EMAIL}" \
  --role="roles/storage.admin" --quiet &>/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${LOGS_BUCKET}" \
  --member="serviceAccount:${CICD_SA_EMAIL}" \
  --role="roles/storage.admin" --quiet &>/dev/null

# ------------------------------------------------------------------------------
# 6. Setup BigQuery Telemetry Dataset & Log Sink
# ------------------------------------------------------------------------------
log_info "Configuring BigQuery Telemetry Dataset & Cloud Logging Sink..."

# Create dataset if not existing
if bq --project_id="${PROJECT_ID}" show "${BQ_DATASET}" &>/dev/null; then
  log_info "BigQuery dataset ${BQ_DATASET} already exists."
else
  bq --project_id="${PROJECT_ID}" --location="${REGION}" mk -d \
    --description="Dataset for GenAI telemetry data stored in GCS" \
    "${BQ_DATASET}"
  log_success "Created BigQuery dataset: ${BQ_DATASET}"
fi

# Create Log Sink
SINK_NAME="${PROJECT_NAME}-genai-logs"
SINK_FILTER='labels."event.name"="gen_ai.client.inference.operation.details" AND (labels."gen_ai.input.messages_ref" =~ ".*blueprint-agent.*" OR labels."gen_ai.output.messages_ref" =~ ".*blueprint-agent.*")'
SINK_DEST="bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${BQ_DATASET}"

if gcloud logging sinks describe "${SINK_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
  log_info "Logging sink ${SINK_NAME} already exists."
else
  gcloud logging sinks create "${SINK_NAME}" "${SINK_DEST}" \
    --project="${PROJECT_ID}" \
    --log-filter="${SINK_FILTER}" \
    --use-partitioned-tables
  log_success "Created Logging sink: ${SINK_NAME}"
fi

# Grant sink writer identity permission to BigQuery dataset
SINK_WRITER="$(gcloud logging sinks describe "${SINK_NAME}" --project="${PROJECT_ID}" --format='value(writerIdentity)')"
if [[ -n "${SINK_WRITER}" ]]; then
  bq add-iam-policy-binding \
    --member="${SINK_WRITER}" \
    --role="roles/bigquery.dataEditor" \
    "${PROJECT_ID}:${BQ_DATASET}" &>/dev/null || true
  log_success "Granted BigQuery Data Editor to sink writer identity: ${SINK_WRITER}"
fi

# ------------------------------------------------------------------------------
# 7. Setup Workload Identity Federation (GitHub Actions)
# ------------------------------------------------------------------------------
log_info "Setting up Workload Identity Federation for GitHub Actions..."

if gcloud iam workload-identity-pools describe "${WIF_POOL_NAME}" --project="${PROJECT_ID}" --location="global" &>/dev/null; then
  log_info "Workload Identity Pool ${WIF_POOL_NAME} already exists."
else
  gcloud iam workload-identity-pools create "${WIF_POOL_NAME}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --display-name="GitHub Actions Pool"
  log_success "Created Workload Identity Pool: ${WIF_POOL_NAME}"
fi

if gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${WIF_POOL_NAME}" &>/dev/null; then
  log_info "Workload Identity Provider ${WIF_PROVIDER_NAME} already exists."
else
  gcloud iam workload-identity-pools providers create-oidc "${WIF_PROVIDER_NAME}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${WIF_POOL_NAME}" \
    --display-name="GitHub OIDC Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="attribute.repository == '${GITHUB_REPO}'"
  log_success "Created Workload Identity Provider: ${WIF_PROVIDER_NAME}"
fi

# Allow GitHub Actions to impersonate CI/CD Runner Service Account
PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_NAME}/attribute.repository/${GITHUB_REPO}"

gcloud iam service-accounts add-iam-policy-binding "${CICD_SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${PRINCIPAL_SET}" \
  --quiet &>/dev/null

gcloud iam service-accounts add-iam-policy-binding "${CICD_SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="${PRINCIPAL_SET}" \
  --quiet &>/dev/null

log_success "Configured WIF impersonation for repository: ${GITHUB_REPO}"

# ------------------------------------------------------------------------------
# 8. Output Summary and Next Steps
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo -e "${GREEN} Implementation Complete for project ${PROJECT_ID}!${NC}"
echo "=============================================================================="
echo
echo "Google Cloud Resources Configured:"
echo "  - Project ID:                 ${PROJECT_ID}"
echo "  - Project Number:             ${PROJECT_NUMBER}"
echo "  - App Service Account:        ${APP_SA_EMAIL}"
echo "  - CI/CD Runner SA:            ${CICD_SA_EMAIL}"
echo "  - Logs/Completions Bucket:    gs://${LOGS_BUCKET}"
echo "  - State Bucket:               gs://${STATE_BUCKET}"
echo "  - BigQuery Dataset:           ${PROJECT_ID}:${BQ_DATASET}"
echo "  - Workload Identity Pool:     ${WIF_POOL_NAME}"
echo "  - Workload Identity Provider: ${WIF_PROVIDER_NAME}"
echo
echo "GitHub Actions Secrets & Variables to set:"
echo "  Variables (vars):"
echo "    GCP_PROJECT_NUMBER:          ${PROJECT_NUMBER}"
echo "    CICD_PROJECT_ID:             ${PROJECT_ID}"
echo "    STAGING_PROJECT_ID:          ${PROJECT_ID}"
echo "    PROD_PROJECT_ID:             ${PROJECT_ID}"
echo "    REGION:                      ${REGION}"
echo "    APP_SERVICE_ACCOUNT_STAGING: ${APP_SA_EMAIL}"
echo "    APP_SERVICE_ACCOUNT_PROD:    ${APP_SA_EMAIL}"
echo "    LOGS_BUCKET_NAME_STAGING:    ${LOGS_BUCKET}"
echo "    LOGS_BUCKET_NAME_PROD:       ${LOGS_BUCKET}"
echo "  Secrets (secrets):"
echo "    WIF_POOL_ID:                 ${WIF_POOL_NAME}"
echo "    WIF_PROVIDER_ID:             ${WIF_PROVIDER_NAME}"
echo "    GCP_SERVICE_ACCOUNT:         ${CICD_SA_EMAIL}"
echo
echo "Deploying the Agent Runtime:"
echo "  To deploy the agent locally using agents-cli:"
echo "    uvx google-agents-cli deploy \\"
echo "      --project \"${PROJECT_ID}\" \\"
echo "      --region \"${REGION}\" \\"
echo "      --service-account=\"${APP_SA_EMAIL}\" \\"
echo "      --update-env-vars=\"LOGS_BUCKET_NAME=${LOGS_BUCKET}\" \\"
echo "      --no-confirm-project"
echo
echo "  To run the build and test pipeline via Cloud Build:"
echo "    gcloud builds submit --config=cloudbuild.yaml \\"
echo "      --substitutions=_REGION=\"${REGION}\",_APP_SERVICE_ACCOUNT=\"${APP_SA_EMAIL}\",_LOGS_BUCKET_NAME=\"${LOGS_BUCKET}\""
echo "=============================================================================="

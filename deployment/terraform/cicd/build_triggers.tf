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

# Cloud Build 2nd-gen GitHub Connection (Optional for Cloud Build users)
resource "google_cloudbuildv2_connection" "github_connection" {
  count    = var.enable_cloud_build ? 1 : 0
  project  = var.cicd_runner_project_id
  location = var.region
  name     = var.host_connection_name

  github_config {
    app_installation_id = 0 # Updated via gcloud or terraform var when using Cloud Build app
    authorizer_credential {
      oauth_token_secret_version = "projects/${var.cicd_runner_project_id}/secrets/${var.project_name}-github-token/versions/latest"
    }
  }
  depends_on = [google_project_service.cicd_services]
}

resource "google_cloudbuildv2_repository" "repo" {
  count             = var.enable_cloud_build ? 1 : 0
  project           = var.cicd_runner_project_id
  location          = var.region
  name              = var.repository_name
  parent_connection = google_cloudbuildv2_connection.github_connection[0].name
  remote_uri        = "https://github.com/${var.repository_owner}/${var.repository_name}.git"
}

# 1. PR Checks Trigger (Cloud Build)
resource "google_cloudbuild_trigger" "pr_checks" {
  count           = var.enable_cloud_build ? 1 : 0
  name            = "pr-${var.project_name}"
  project         = var.cicd_runner_project_id
  location        = var.region
  description     = "Trigger for PR checks"
  service_account = google_service_account.cicd_runner_sa.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.repo[0].id
    pull_request {
      branch = "main"
    }
  }

  filename = ".cloudbuild/pr_checks.yaml"
  included_files = [
    "blueprint_agent/**",
    "tests/**",
    "deployment/**",
    "Dockerfile",
    "pyproject.toml",
    "uv.lock"
  ]
  include_build_logs = "INCLUDE_BUILD_LOGS_WITH_STATUS"
  depends_on         = [google_project_service.cicd_services, google_service_account.cicd_runner_sa]
}

# 2. CD Pipeline Trigger - Staging (Cloud Build)
resource "google_cloudbuild_trigger" "cd_pipeline" {
  count           = var.enable_cloud_build ? 1 : 0
  name            = "cd-${var.project_name}"
  project         = var.cicd_runner_project_id
  location        = var.region
  service_account = google_service_account.cicd_runner_sa.id
  description     = "Trigger for CD pipeline (Staging)"

  repository_event_config {
    repository = google_cloudbuildv2_repository.repo[0].id
    push {
      branch = "main"
    }
  }

  filename = ".cloudbuild/staging.yaml"
  included_files = [
    "blueprint_agent/**",
    "tests/**",
    "deployment/**",
    "Dockerfile",
    "pyproject.toml",
    "uv.lock"
  ]
  include_build_logs = "INCLUDE_BUILD_LOGS_WITH_STATUS"
  substitutions = {
    _PROJECT_NAME                = var.project_name
    _STAGING_PROJECT_ID          = var.staging_project_id
    _LOGS_BUCKET_NAME_STAGING    = google_storage_bucket.logs_data_bucket[var.staging_project_id].name
    _APP_SERVICE_ACCOUNT_STAGING = google_service_account.app_sa["staging"].email
    _REGION                      = var.region
  }
  depends_on = [google_project_service.cicd_services, google_service_account.cicd_runner_sa]
}

# 3. Deploy to Production Trigger (Cloud Build - with approval gate)
resource "google_cloudbuild_trigger" "deploy_to_prod_pipeline" {
  count           = var.enable_cloud_build ? 1 : 0
  name            = "deploy-${var.project_name}"
  project         = var.cicd_runner_project_id
  location        = var.region
  description     = "Trigger for deployment to production (requires approval)"
  service_account = google_service_account.cicd_runner_sa.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.repo[0].id
  }
  filename           = ".cloudbuild/deploy-to-prod.yaml"
  include_build_logs = "INCLUDE_BUILD_LOGS_WITH_STATUS"

  approval_config {
    approval_required = true
  }

  substitutions = {
    _PROJECT_NAME             = var.project_name
    _PROD_PROJECT_ID          = var.prod_project_id
    _LOGS_BUCKET_NAME_PROD    = google_storage_bucket.logs_data_bucket[var.prod_project_id].name
    _APP_SERVICE_ACCOUNT_PROD = google_service_account.app_sa["prod"].email
    _REGION                   = var.region
  }
  depends_on = [google_project_service.cicd_services, google_service_account.cicd_runner_sa]
}

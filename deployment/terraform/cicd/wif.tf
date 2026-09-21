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

data "google_project" "cicd_project" {
  project_id = var.cicd_runner_project_id
}

resource "google_iam_workload_identity_pool" "github_pool" {
  count                     = var.enable_github_actions ? 1 : 0
  workload_identity_pool_id = "${var.project_name}-pool"
  project                   = var.cicd_runner_project_id
  display_name              = "GitHub Actions Pool"
  depends_on                = [google_project_service.cicd_services]
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  count                              = var.enable_github_actions ? 1 : 0
  workload_identity_pool_provider_id = "${var.project_name}-oidc"
  project                            = var.cicd_runner_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool[0].workload_identity_pool_id
  display_name                       = "GitHub OIDC Provider"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }
  attribute_condition = "attribute.repository == '${var.repository_owner}/${var.repository_name}'"
  depends_on          = [google_project_service.cicd_services]
}

resource "google_service_account_iam_member" "github_oidc_access" {
  count              = var.enable_github_actions ? 1 : 0
  service_account_id = google_service_account.cicd_runner_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.cicd_project.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github_pool[0].workload_identity_pool_id}/attribute.repository/${var.repository_owner}/${var.repository_name}"
  depends_on         = [google_project_service.cicd_services]
}

resource "google_service_account_iam_member" "github_sa_impersonation" {
  count              = var.enable_github_actions ? 1 : 0
  service_account_id = google_service_account.cicd_runner_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.cicd_project.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github_pool[0].workload_identity_pool_id}/attribute.repository/${var.repository_owner}/${var.repository_name}"
  depends_on         = [google_project_service.cicd_services]
}

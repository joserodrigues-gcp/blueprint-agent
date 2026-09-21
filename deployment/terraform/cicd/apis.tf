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

locals {
  cicd_services = [
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "serviceusage.googleapis.com",
    "aiplatform.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
    "monitoring.googleapis.com",
  ]

  deploy_services = [
    "aiplatform.googleapis.com",
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
    "monitoring.googleapis.com",
    "storage.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
  ]
}

# Enable APIs on CI/CD runner project
resource "google_project_service" "cicd_services" {
  for_each           = toset(local.cicd_services)
  project            = var.cicd_runner_project_id
  service            = each.key
  disable_on_destroy = false
}

# Enable APIs on Deployment projects (staging, prod)
resource "google_project_service" "deploy_project_services" {
  for_each = {
    for pair in setproduct(keys(local.deploy_project_ids), local.deploy_services) :
    "${pair[0]}-${pair[1]}" => {
      project_id = local.deploy_project_ids[pair[0]]
      service    = pair[1]
    }
  }

  project            = each.value.project_id
  service            = each.value.service
  disable_on_destroy = false
}

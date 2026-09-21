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

# Logs and Artifacts bucket for each deployment project (staging, prod)
resource "google_storage_bucket" "logs_data_bucket" {
  for_each                    = local.deploy_project_ids
  name                        = "${each.value}-${var.project_name}-logs"
  location                    = var.region
  project                     = each.value
  force_destroy               = false
  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.deploy_project_services]
}

# Grant Application SA Storage Admin on the logs bucket
resource "google_storage_bucket_iam_member" "app_sa_storage_admin" {
  for_each = local.deploy_project_ids
  bucket   = google_storage_bucket.logs_data_bucket[each.key].name
  role     = "roles/storage.admin"
  member   = "serviceAccount:${google_service_account.app_sa[each.key].email}"
}

# Grant CI/CD Runner SA Storage Admin on each bucket
resource "google_storage_bucket_iam_member" "cicd_runner_storage_admin" {
  for_each = local.deploy_project_ids
  bucket   = google_storage_bucket.logs_data_bucket[each.key].name
  role     = "roles/storage.admin"
  member   = "serviceAccount:${google_service_account.cicd_runner_sa.email}"
}

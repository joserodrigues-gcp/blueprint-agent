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

output "cicd_runner_sa_email" {
  value       = google_service_account.cicd_runner_sa.email
  description = "The email of the CI/CD runner service account."
}

output "app_sa_emails" {
  value = {
    for k, sa in google_service_account.app_sa : k => sa.email
  }
  description = "The emails of the application service accounts for staging and prod."
}

output "logs_bucket_names" {
  value = {
    for k, bucket in google_storage_bucket.logs_data_bucket : k => bucket.name
  }
  description = "Names of the logs and artifacts buckets for staging and prod."
}

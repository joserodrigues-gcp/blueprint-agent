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
  deploy_project_ids = {
    staging = var.staging_project_id
    prod    = var.prod_project_id
  }

  all_project_ids = distinct([
    var.cicd_runner_project_id,
    var.staging_project_id,
    var.prod_project_id
  ])

  dummy_source_b64 = trimspace(file("${path.module}/../shared/dummy_source.b64"))
}

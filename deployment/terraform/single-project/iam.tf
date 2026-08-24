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

# The projects this configuration grants access in, each under a short name.
#
# A single-project deployment has exactly one entry, so the map looks like overhead. It
# is what lets the IAM resources below be written once and repeated with for_each. A
# multi-project layout adds entries here — say `staging = var.staging_project_id` — and
# every binding follows automatically, with nothing duplicated per project.
locals {
  project_ids = {
    default = var.project_id
  }
}


# Get the project number
data "google_project" "project" {
  project_id = var.project_id
}

# Lets Cloud Build turn the agent's source into a container image, which is the step
# `agents-cli deploy` triggers before Agent Runtime can start it.
#
# Builds run as the Compute Engine default service account. The builder role is what
# lets that account read the uploaded source, write build logs, and push the finished
# image. Without it a deploy fails in the build, before the engine is ever updated.
resource "google_project_iam_member" "default_compute_sa_storage_object_creator" {
  project    = var.project_id
  role       = "roles/cloudbuild.builds.builder"
  member     = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  depends_on = [resource.google_project_service.services]
}

# Agent service account
resource "google_service_account" "app_sa" {
  account_id   = "${var.project_name}-app"
  display_name = "${var.project_name} Agent Service Account"
  project      = var.project_id
  depends_on   = [resource.google_project_service.services]
}

# Grants the agent's service account every role in var.app_sa_roles, in every project.
#
# A google_project_iam_member holds one role, so for_each builds one per project-and-role
# pair, with setproduct forming the pairs. Each instance is keyed by name rather than list
# position — "default,roles/aiplatform.user" — so adding or removing a role leaves the
# others untouched.
resource "google_project_iam_member" "app_sa_roles" {
  for_each = {
    for pair in setproduct(keys(local.project_ids), var.app_sa_roles) :
    join(",", pair) => {
      project = local.project_ids[pair[0]]
      role    = pair[1]
    }
  }

  project    = each.value.project
  role       = each.value.role
  member     = "serviceAccount:${google_service_account.app_sa.email}"
  depends_on = [resource.google_project_service.services]
}


# Lets the agent write its own metrics — token usage, latency, tool calls — to Cloud
# Monitoring.
#
# This role is granted here rather than added to var.app_sa_roles, because that list is
# also applied to the Agent Platform service agent below. Only the agent needs it.
resource "google_project_iam_member" "app_sa_metric_writer" {
  # Grants the role once in every project. for_each walks the map above, and each.value
  # holds that entry's project id.
  for_each = local.project_ids

  project    = each.value
  role       = "roles/monitoring.metricWriter"
  member     = "serviceAccount:${google_service_account.app_sa.email}"
  depends_on = [resource.google_project_service.services]
}


# Grant required permissions to the Agent Platform service agent for Agent Runtime.
# The service agent is still provisioned under its previous name, gcp-sa-aiplatform.
resource "google_project_iam_member" "vertex_ai_sa_permissions" {
  for_each = {
    for pair in setproduct(keys(local.project_ids), var.app_sa_roles) :
    join(",", pair) => pair[1]
  }

  project = var.project_id
  role    = each.value
  member  = google_project_service_identity.vertex_sa.member
  depends_on = [resource.google_project_service.services]
}


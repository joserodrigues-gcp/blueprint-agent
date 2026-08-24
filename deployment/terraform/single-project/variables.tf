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

variable "project_name" {
  type        = string
  description = "Project name used as a base for resource naming"
  default     = "blueprint-agent"
}

variable "project_id" {
  type        = string
  description = "Google Cloud Project ID for resource deployment."
}

# Where the agent runtime and its supporting resources are created.
#
# There is no default. Each environment sets its own region in vars/env.tfvars, and
# Terraform asks for the value if that file is not passed — the same way it asks for
# project_id.
variable "region" {
  type        = string
  description = "Google Cloud region for resource deployment."
}

# Narrows which telemetry logs are exported to BigQuery.
#
# The log sink in telemetry.tf currently declares its own filter. Point that filter at
# this variable to make it take effect.
variable "telemetry_logs_filter" {
  type        = string
  description = "Log Sink filter for capturing telemetry data. Captures logs with the `traceloop.association.properties.log_type` attribute set to `tracing`."
  default     = "labels.service_name=\"blueprint-agent\" labels.type=\"agent_telemetry\""
}

variable "app_sa_roles" {
  description = "List of roles to assign to the application service account"
  type        = list(string)
  default = [

    "roles/aiplatform.user",
    "roles/logging.logWriter",
    "roles/cloudtrace.agent",
    "roles/storage.admin",
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

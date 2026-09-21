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

# 1. BigQuery dataset for telemetry external tables (per deploy project)
resource "google_bigquery_dataset" "telemetry_dataset" {
  for_each      = local.deploy_project_ids
  project       = each.value
  dataset_id    = replace("${var.project_name}_telemetry", "-", "_")
  friendly_name = "${var.project_name} Telemetry (${each.key})"
  location      = var.region
  description   = "Dataset for GenAI telemetry data stored in GCS"
  depends_on    = [google_project_service.deploy_project_services]
}

# 2. BigQuery connection for accessing GCS telemetry data
resource "google_bigquery_connection" "genai_telemetry_connection" {
  for_each      = local.deploy_project_ids
  project       = each.value
  location      = var.region
  connection_id = "${var.project_name}-genai-telemetry"
  friendly_name = "${var.project_name} GenAI Telemetry Connection (${each.key})"

  cloud_resource {}

  depends_on = [google_project_service.deploy_project_services]
}

# 3. Wait for the BigQuery connection service account to propagate in IAM
resource "time_sleep" "wait_for_bq_connection_sa" {
  for_each        = local.deploy_project_ids
  create_duration = "10s"

  depends_on = [google_bigquery_connection.genai_telemetry_connection]
}

# 4. Grant the BigQuery connection SA access to read from the logs bucket
resource "google_storage_bucket_iam_member" "telemetry_connection_access" {
  for_each = local.deploy_project_ids
  bucket   = google_storage_bucket.logs_data_bucket[each.key].name
  role     = "roles/storage.objectViewer"
  member   = "serviceAccount:${google_bigquery_connection.genai_telemetry_connection[each.key].cloud_resource[0].service_account_id}"

  depends_on = [time_sleep.wait_for_bq_connection_sa]
}

# 5. Log Sinks — route GenAI logs directly to BigQuery
resource "google_logging_project_sink" "genai_logs_to_bq" {
  for_each    = local.deploy_project_ids
  name        = "${var.project_name}-genai-logs"
  project     = each.value
  destination = "bigquery.googleapis.com/projects/${each.value}/datasets/${google_bigquery_dataset.telemetry_dataset[each.key].dataset_id}"
  filter      = "labels.\"event.name\"=\"gen_ai.client.inference.operation.details\" AND (labels.\"gen_ai.input.messages_ref\" =~ \".*${var.project_name}.*\" OR labels.\"gen_ai.output.messages_ref\" =~ \".*${var.project_name}.*\")"

  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }

  depends_on = [google_bigquery_dataset.telemetry_dataset]
}

# 6. Grant log sink SA write access to the BigQuery dataset
resource "google_bigquery_dataset_iam_member" "genai_logs_bq_writer" {
  for_each   = local.deploy_project_ids
  project    = each.value
  dataset_id = google_bigquery_dataset.telemetry_dataset[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.genai_logs_to_bq[each.key].writer_identity
}

# 7. Completions External Table (GCS-based)
resource "google_bigquery_table" "completions_external_table" {
  for_each            = local.deploy_project_ids
  project             = each.value
  dataset_id          = google_bigquery_dataset.telemetry_dataset[each.key].dataset_id
  table_id            = "completions"
  deletion_protection = false

  external_data_configuration {
    autodetect            = false
    source_format         = "NEWLINE_DELIMITED_JSON"
    source_uris           = ["gs://${google_storage_bucket.logs_data_bucket[each.key].name}/completions/*"]
    connection_id         = google_bigquery_connection.genai_telemetry_connection[each.key].name
    ignore_unknown_values = true
    max_bad_records       = 1000
  }

  schema = jsonencode([
    {
      name = "parts"
      type = "RECORD"
      mode = "REPEATED"
      fields = [
        { name = "type", type = "STRING", mode = "NULLABLE" },
        { name = "content", type = "STRING", mode = "NULLABLE" },
        { name = "mime_type", type = "STRING", mode = "NULLABLE" },
        { name = "uri", type = "STRING", mode = "NULLABLE" },
        { name = "data", type = "BYTES", mode = "NULLABLE" },
        { name = "id", type = "STRING", mode = "NULLABLE" },
        { name = "name", type = "STRING", mode = "NULLABLE" },
        { name = "arguments", type = "JSON", mode = "NULLABLE" },
        { name = "response", type = "JSON", mode = "NULLABLE" }
      ]
    },
    { name = "role", type = "STRING", mode = "NULLABLE" },
    { name = "index", type = "INTEGER", mode = "NULLABLE" }
  ])

  depends_on = [
    google_storage_bucket.logs_data_bucket,
    google_bigquery_connection.genai_telemetry_connection,
    google_storage_bucket_iam_member.telemetry_connection_access
  ]
}

# 8. GenAI Log Export Table (pre-created)
resource "google_bigquery_table" "genai_logs_table" {
  for_each            = local.deploy_project_ids
  project             = each.value
  dataset_id          = google_bigquery_dataset.telemetry_dataset[each.key].dataset_id
  table_id            = "aiplatform_googleapis_com_reasoning_engine_stdout"
  deletion_protection = false
  description         = "GenAI inference logs exported directly from Cloud Logging"

  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  schema = file("${path.module}/../shared/genai_logs_schema.json")

  lifecycle {
    ignore_changes = [schema]
  }

  depends_on = [google_bigquery_dataset.telemetry_dataset]
}

# 9. Completions View (Joins BQ log export with GCS completions)
resource "google_bigquery_table" "completions_view" {
  for_each            = local.deploy_project_ids
  project             = each.value
  dataset_id          = google_bigquery_dataset.telemetry_dataset[each.key].dataset_id
  table_id            = "completions_view"
  description         = "View of GenAI completion logs joined with the GCS prompt/response external table"
  deletion_protection = false

  view {
    query = templatefile("${path.module}/../shared/completions.sql", {
      project_id                 = each.value
      dataset_id                 = google_bigquery_dataset.telemetry_dataset[each.key].dataset_id
      completions_external_table = google_bigquery_table.completions_external_table[each.key].table_id
      genai_logs_table           = google_bigquery_table.genai_logs_table[each.key].table_id
    })
    use_legacy_sql = false
  }

  depends_on = [
    google_bigquery_table.completions_external_table,
    google_bigquery_table.genai_logs_table,
    google_logging_project_sink.genai_logs_to_bq
  ]
}

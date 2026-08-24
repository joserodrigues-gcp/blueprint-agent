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
  dummy_source_b64 = trimspace(file("${path.module}/../shared/dummy_source.b64"))
}

resource "google_vertex_ai_reasoning_engine" "app" {
  display_name = var.project_name
  description  = "Agent deployed via Terraform"
  region       = var.region
  project      = var.project_id

  spec {
    agent_framework = "google-adk"
    service_account = google_service_account.app_sa.email

    deployment_spec {
      min_instances         = 1
      max_instances         = 10
      container_concurrency = 9

      resource_limits = {
        cpu    = "4"
        memory = "8Gi"
      }

      # Environment variables for the deployed agent.
      #
      # Terraform sets these when it creates the runtime, and then stops managing them —
      # see the lifecycle block at the end of this file. Editing a value here has no
      # effect on an agent that already exists.
      #
      # To change one on a running agent, either add that key to `.env` and redeploy, or
      # run:
      #   agents-cli deploy --update-env-vars KEY=VALUE
      # Both leave the other variables untouched.

      # Bucket the agent keeps session artifacts in — files a user uploads, files a tool
      # produces. Without it artifacts live in memory and are lost when an instance
      # restarts. Read in blueprint_agent/app_utils/services.py.
      env {
        name  = "LOGS_BUCKET_NAME"
        value = google_storage_bucket.logs_data_bucket.name
      }

      # Where the model is served from, not where the agent runs. `global` is Gemini's
      # multi-region endpoint; the agent's own region comes from var.region.
      #
      # There is no GOOGLE_CLOUD_PROJECT beside it: Agent Runtime provides the project
      # itself, and rejects the deployment if this block tries to set it.
      env {
        name  = "GOOGLE_CLOUD_LOCATION"
        value = "global"
      }

      # Sends model calls through Agent Platform instead of the Gemini Developer API.
      # Agent Platform accepts the service account above as the caller's identity; the
      # Developer API would need an API key.
      #
      # This is the current name for GOOGLE_GENAI_USE_VERTEXAI. The old name still works
      # but raises a DeprecationWarning, and when both are set this one decides.
      env {
        name  = "GOOGLE_GENAI_USE_ENTERPRISE"
        value = "true"
      }

      # Name this agent's telemetry is filed under. It becomes the service.name attribute
      # on every span, metric and log, which is how you pick the agent's data out in Cloud
      # Trace and Cloud Monitoring.
      env {
        name  = "OTEL_SERVICE_NAME"
        value = "blueprint-agent"
      }

      # Keeps prompt and response text out of traces and logs. NO_CONTENT is the strictest
      # of four settings — the others are EVENT_ONLY, SPAN_ONLY and SPAN_AND_EVENT.
      #
      # The text is still captured. The completion hook below writes it to Cloud Storage,
      # and the telemetry carries a gs:// reference in place of the text.
      env {
        name  = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"
        value = "NO_CONTENT"
      }

      # Keeps that same text out of the spans ADK creates itself. Those spans predate the
      # OpenTelemetry GenAI conventions and answer to their own switch, which is on until
      # something sets it to false.
      env {
        name  = "ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS"
        value = "false"
      }

      # Emits the current OpenTelemetry GenAI attribute names rather than the older ones.
      # The BigQuery pipeline depends on it: the log sink in telemetry.tf selects
      # gen_ai.client.inference.operation.details, an event only these conventions produce.
      env {
        name  = "OTEL_SEMCONV_STABILITY_OPT_IN"
        value = "gen_ai_latest_experimental"
      }

      # Writes each uploaded file as newline-delimited JSON. The completions external
      # table in telemetry.tf reads the bucket as NEWLINE_DELIMITED_JSON, so the default
      # of `json` would leave that table unable to parse its own source files.
      env {
        name  = "OTEL_INSTRUMENTATION_GENAI_UPLOAD_FORMAT"
        value = "jsonl"
      }

      # Turns on the upload hook, which sends prompts and responses to Cloud Storage.
      # Without it the content is recorded nowhere, since the capture setting above keeps
      # it out of spans and logs.
      env {
        name  = "OTEL_INSTRUMENTATION_GENAI_COMPLETION_HOOK"
        value = "upload"
      }

      # Prefix the hook writes under. Each model call produces up to three objects:
      #
      #   <uuid>_inputs.jsonl              the prompt
      #   <uuid>_outputs.jsonl             the response
      #   <hash>_system_instruction.jsonl  the system instruction, named by content hash
      #                                    so identical instructions upload once
      #
      # The completions external table in telemetry.tf reads this same prefix, and each
      # log record's gen_ai.*_ref attributes name the exact objects for that call.
      env {
        name  = "OTEL_INSTRUMENTATION_GENAI_UPLOAD_BASE_PATH"
        value = "gs://${google_storage_bucket.logs_data_bucket.name}/completions"
      }

      # Master switch for shipping telemetry to Google Cloud. It puts the exporters in
      # place that send traces to Cloud Trace and logs to Cloud Logging, and it turns on
      # the request metrics Agent Runtime reports for the engine.
      #
      # The same variable controls local runs: blueprint_agent/fast_api_app.py reads it
      # into the otel_to_cloud argument of get_fast_api_app.
      env {
        name  = "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY"
        value = "true"
      }

      # Sends the agent's own metrics to Cloud Monitoring: token usage, model and agent
      # latency, tool and inference call counts. The managed telemetry enabled above
      # reports request counts and container utilisation, but none of these.
      #
      # Note this is the metrics-only endpoint. The general-purpose
      # OTEL_EXPORTER_OTLP_ENDPOINT would redirect traces as well, and they would then
      # be exported twice.
      env {
        name  = "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"
        value = "https://telemetry.googleapis.com/v1/metrics"
      }

      # Tells the exporter above to authenticate as the runtime's service account.
      # Required: without it the metrics are sent unauthenticated and rejected with a
      # 403, which is the only sign that anything is wrong.
      #
      # The named provider comes from opentelemetry-exporter-credential-provider-gcp,
      # a dependency in pyproject.toml.
      env {
        name  = "OTEL_PYTHON_EXPORTER_OTLP_HTTP_METRICS_CREDENTIAL_PROVIDER"
        value = "gcp_http_credentials"
      }
    }

    source_code_spec {
      inline_source {
        source_archive = local.dummy_source_b64
      }
      image_spec {}
    }
  }

  # Two things share this resource: Terraform creates it, and `agents-cli deploy` (or the
  # CI/CD pipeline) fills it with the real agent.
  #
  # Terraform goes first, using the placeholder archive above, so the runtime and
  # everything referring to it exist before there is any code to deploy. The placeholder
  # is a source archive rather than a container image, because a deploy that ships source
  # cannot replace an image.
  #
  # Everything the deploy writes is listed below, so Terraform leaves it alone and no
  # later `apply` undoes a deployment:
  #
  #   container_spec, source_code_spec  the agent's code and image
  #   deployment_spec                   env vars, CPU, memory, scaling
  #   class_methods                     the API the deploy publishes for the agent
  #                                     (get_session, stream_query, and so on)
  lifecycle {
    ignore_changes = [
      spec[0].container_spec,
      spec[0].source_code_spec,
      spec[0].deployment_spec,
      spec[0].class_methods,
    ]
  }

  # Make dependencies conditional to avoid errors.
  depends_on = [google_project_service.services]
}

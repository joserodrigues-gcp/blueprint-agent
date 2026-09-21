#!/usr/bin/env bash
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

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-svc-project-gke02}"
REGION="${REGION:-us-central1}"
PROJECT_NAME="blueprint-agent"
APP_SA_EMAIL="${PROJECT_NAME}-app@${PROJECT_ID}.iam.gserviceaccount.com"
LOGS_BUCKET="${PROJECT_ID}-${PROJECT_NAME}-logs"

echo "=============================================================================="
echo " Deploying ${PROJECT_NAME} to Google Cloud Agent Runtime"
echo " Project: ${PROJECT_ID} | Region: ${REGION}"
echo " Service Account: ${APP_SA_EMAIL}"
echo " Logs Bucket: gs://${LOGS_BUCKET}"
echo "=============================================================================="

agents-cli deploy \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --service-account="${APP_SA_EMAIL}" \
  --update-env-vars="LOGS_BUCKET_NAME=${LOGS_BUCKET}" \
  --no-confirm-project "$@"

echo
echo "Verifying deployment status..."
agents-cli deploy --status \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --no-confirm-project || true

echo "Done."

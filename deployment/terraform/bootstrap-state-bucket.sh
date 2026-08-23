#!/usr/bin/env bash
# Create the GCS bucket that holds this project's Terraform state.
#
# Chicken-and-egg: the backend in single-project/backend.tf cannot initialise until its
# bucket exists, so the bucket cannot be a Terraform resource in that module. It is
# created here instead, out of band, the same way `agents-cli infra cicd` creates it
# (google/agents/cli/infra/_cicd_utils.py:577-600) — but with every setting stated
# rather than inherited from account defaults, so a second operator gets the same bucket.
#
# Idempotent: safe to re-run. Creates what is missing, reconciles what has drifted, and stops
# on the one kind of drift it cannot fix — a bucket already in the wrong location.
#
# Usage:
#   deployment/terraform/bootstrap-state-bucket.sh
#   PROJECT_ID=other-proj REGION=us-east1 deployment/terraform/bootstrap-state-bucket.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${TFVARS:-${SCRIPT_DIR}/single-project/vars/env.tfvars}"

# project_id and region come from the tfvars terraform itself reads, so this bucket
# cannot drift from the module whose state it holds — the bucket's --location must match
# the module's region, and its name is derived from the module's project_id. There are
# deliberately no fallback defaults: a wrong guess here creates a bucket in the wrong
# project or region, which is worse than stopping.
#
# .env is NOT a source, and this is the layer boundary the whole repo follows: .env is
# the agent process's runtime environment, tfvars is the infrastructure's inputs. Its
# GOOGLE_CLOUD_LOCATION=global is a Gemini serving endpoint, not a GCS location — the
# two are independent by design, not by accident. See "Where configuration lives" in
# README.md.
tfvar() {
  local key="$1" value
  value="$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\\1/p" \
    "${TFVARS}" | head -n1)"
  if [[ -z "${value}" ]]; then
    echo "error: no '${key}' in ${TFVARS}" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

if [[ ! -f "${TFVARS}" ]]; then
  echo "error: tfvars not found: ${TFVARS}" >&2
  exit 1
fi

PROJECT_ID="${PROJECT_ID:-$(tfvar project_id)}"
REGION="${REGION:-$(tfvar region)}"
# Name matches what `infra cicd` derives, so adopting CI/CD later needs no migration.
BUCKET="${BUCKET:-${PROJECT_ID}-terraform-state}"
# Keep 10 old state versions; versioning without this grows without bound.
NONCURRENT_VERSIONS_TO_KEEP="${NONCURRENT_VERSIONS_TO_KEEP:-10}"

echo "Source:  ${TFVARS}"
echo "Bucket:  gs://${BUCKET}"
echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Empty when the bucket does not exist, and also when it exists but is unreadable from here
# (a globally unique name taken by another project); the create below then fails with a 409.
existing_location="$(gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT_ID}" \
  --format='value(location)' 2>/dev/null || true)"

if [[ -n "${existing_location}" ]]; then
  # A bucket's location is fixed at creation, so this is the one setting below that cannot be
  # reconciled — it has to be a hard stop. Left unchecked, terraform would keep on holding its
  # state in a region the module does not use, and nothing would ever say so.
  if [[ "$(upper "${existing_location}")" != "$(upper "${REGION}")" ]]; then
    cat >&2 <<ERR
error: gs://${BUCKET} is in ${existing_location}, but ${TFVARS} says region = "${REGION}".
       A bucket's location is immutable, so this script cannot fix it. Either:
         - set region = "$(printf '%s' "${existing_location}" | tr '[:upper:]' '[:lower:]')" in ${TFVARS}, if that is where the module belongs; or
         - migrate the state and delete the bucket, then re-run to recreate it in ${REGION}; or
         - point this run elsewhere with BUCKET=<other-name>.
ERR
    exit 1
  fi
  echo "==> Exists in ${existing_location}; reconciling settings."
else
  echo "==> Creating."
  # --uniform-bucket-level-access: state is machine-owned; per-object ACLs have no use
  #   here and are a way to leak it.
  # --public-access-prevention: enforced, not merely inherited from the org policy.
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

# Applied on both paths, so re-running fixes a bucket created by hand or by an older
# version of this script. Each of these is idempotent on its own.
echo "==> Enabling versioning."
gcloud storage buckets update "gs://${BUCKET}" --project="${PROJECT_ID}" --versioning

echo "==> Enforcing uniform access and public access prevention."
gcloud storage buckets update "gs://${BUCKET}" --project="${PROJECT_ID}" \
  --uniform-bucket-level-access --public-access-prevention

echo "==> Setting lifecycle: keep ${NONCURRENT_VERSIONS_TO_KEEP} noncurrent versions."
lifecycle_json="$(mktemp)"
trap 'rm -f "${lifecycle_json}"' EXIT
cat >"${lifecycle_json}" <<EOF
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"numNewerVersions": ${NONCURRENT_VERSIONS_TO_KEEP}}
    }
  ]
}
EOF
gcloud storage buckets update "gs://${BUCKET}" --project="${PROJECT_ID}" \
  --lifecycle-file="${lifecycle_json}"

echo
echo "Done. gs://${BUCKET} is ready for:"
echo "  cd deployment/terraform/single-project && terraform init"

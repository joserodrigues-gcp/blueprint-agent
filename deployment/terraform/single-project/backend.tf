# Terraform state is kept in Cloud Storage instead of on disk. A workstation and a
# CI/CD pipeline then share one state file rather than each holding its own copy.
#
# The bucket name and prefix follow the layout a CI/CD pipeline expects:
#
#   bucket:  <project_id>-terraform-state
#   prefix:  <repo>/dev   for development, <repo>/prod for production
#
# Using that layout from the start means a pipeline can be added later without moving
# any state.
#
# The bucket is not created here. It has to exist before Terraform can initialise a
# backend that stores state inside it. Create it once with:
#
#   deployment/terraform/bootstrap-state-bucket.sh
#
# The script is safe to re-run.
terraform {
  backend "gcs" {
    bucket = "tim-platform-lab-terraform-state"
    prefix = "blueprint-agent/dev"
  }
}

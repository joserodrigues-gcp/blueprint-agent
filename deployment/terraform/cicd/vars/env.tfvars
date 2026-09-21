# Target Google Cloud Project IDs
# If using a single project for both staging and prod during development/lab,
# you can set all three to the same project ID.
staging_project_id     = "svc-project-gke02"
prod_project_id        = "svc-project-gke02"
cicd_runner_project_id = "svc-project-gke02"

region       = "us-central1"
project_name = "blueprint-agent"

# GitHub Configuration
repository_owner      = "joserodrigues-gcp"
repository_name       = "blueprint-agent"
create_repository     = false
enable_github_actions = true
enable_cloud_build    = false

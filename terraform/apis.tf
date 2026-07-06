# Every GCP API must be explicitly enabled before the service can be used.
# Forgetting this is the #1 first-run failure.
locals {
  services = [
    "bigquery.googleapis.com",
    "storage.googleapis.com",
    "run.googleapis.com",
    "workflows.googleapis.com",
    "workflowexecutions.googleapis.com",
    "cloudscheduler.googleapis.com",
    "dataform.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each = toset(local.services)
  project  = var.project_id
  service  = each.value

  # Keep APIs enabled even if this resource is destroyed — avoids breaking
  # other stacks that share the project.
  disable_on_destroy = false
}

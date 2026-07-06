# Orchestrator. Cloud Workflows is GCP's cheap, serverless state-machine service
# (first 5,000 internal steps/month free). It runs the ingest job, then — only
# if a new month was actually loaded — triggers the Dataform transforms.
resource "google_workflows_workflow" "pipeline" {
  name            = "taxi-pipeline"
  region          = var.region
  project         = var.project_id
  description     = "Daily: run ingest job, then (if new month) run Dataform transforms."
  service_account = google_service_account.workflow.email
  source_contents = file("${path.module}/../workflows/pipeline.yaml")

  user_env_vars = {
    INGEST_JOB    = google_cloud_run_v2_job.ingest.name
    TRANSFORM_JOB = google_cloud_run_v2_job.transform.name
    RAW_BUCKET    = local.raw_bucket
  }

  labels     = var.labels
  depends_on = [google_project_service.enabled]
}

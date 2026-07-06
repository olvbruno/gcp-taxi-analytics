# Daily trigger. Cloud Scheduler is GCP's managed cron.
# First 3 jobs/month are free. It POSTs to the Workflows Executions API using
# an OAuth token minted for the scheduler SA (which holds workflows.invoker).
resource "google_cloud_scheduler_job" "daily" {
  name      = "taxi-daily"
  project   = var.project_id
  region    = var.region
  schedule  = var.daily_schedule
  time_zone = var.scheduler_timezone

  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/workflows/${google_workflows_workflow.pipeline.name}/executions"

    # Empty argument set => the workflow resolves the latest un-loaded month.
    # To force a specific month, POST {"argument":"{\"target_month\":\"2023-02\"}"}.
    body = base64encode(jsonencode({}))

    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_workflows_workflow.pipeline]
}

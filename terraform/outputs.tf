output "raw_bucket" {
  description = "GCS bucket holding raw (bronze) parquet files."
  value       = google_storage_bucket.raw.name
}

output "ingest_image" {
  description = "Container image the Cloud Run job runs. Build+push this before applying the job."
  value       = local.ingest_image
}

output "ingest_job" {
  description = "Cloud Run job name."
  value       = google_cloud_run_v2_job.ingest.name
}

output "workflow" {
  description = "Cloud Workflow name (the orchestrator)."
  value       = google_workflows_workflow.pipeline.name
}

output "scheduler_job" {
  description = "Cloud Scheduler job name (daily trigger)."
  value       = google_cloud_scheduler_job.daily.name
}

output "transform_job" {
  description = "Cloud Run job that runs the Dataform transforms."
  value       = google_cloud_run_v2_job.transform.name
}

output "datasets" {
  description = "BigQuery datasets (medallion layers)."
  value = {
    bronze = google_bigquery_dataset.bronze.dataset_id
    silver = google_bigquery_dataset.silver.dataset_id
    gold   = google_bigquery_dataset.gold.dataset_id
  }
}

output "run_ingest_now_cmd" {
  description = "Convenience command to run one ingest manually."
  value       = "gcloud run jobs execute ${google_cloud_run_v2_job.ingest.name} --region ${var.region} --project ${var.project_id}"
}

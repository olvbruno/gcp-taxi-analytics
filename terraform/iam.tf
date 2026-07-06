data "google_project" "this" {
  project_id = var.project_id
}

# ---------------------------------------------------------------------------
# Service accounts (the workload identities the pipeline runs as).
# Cloud Run / Workflows / Scheduler each run AS an explicitly-attached SA —
# there is no implicit ambient identity, so the SA must be set on every resource.
# ---------------------------------------------------------------------------
resource "google_service_account" "ingest" {
  account_id   = "sa-taxi-ingest"
  display_name = "Taxi ingest (Cloud Run Job) runtime"
  project      = var.project_id
  depends_on   = [google_project_service.enabled]
}

resource "google_service_account" "workflow" {
  account_id   = "sa-taxi-workflow"
  display_name = "Taxi pipeline (Cloud Workflows) runtime"
  project      = var.project_id
  depends_on   = [google_project_service.enabled]
}

resource "google_service_account" "scheduler" {
  account_id   = "sa-taxi-scheduler"
  display_name = "Taxi daily trigger (Cloud Scheduler)"
  project      = var.project_id
  depends_on   = [google_project_service.enabled]
}

# ---- Ingest SA: write raw objects + load/query BigQuery ----
resource "google_storage_bucket_iam_member" "ingest_bucket" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ingest.email}"
}

resource "google_bigquery_dataset_iam_member" "ingest_bronze_editor" {
  dataset_id = google_bigquery_dataset.bronze.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.ingest.email}"
}

resource "google_project_iam_member" "ingest_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.ingest.email}"
}

# ---- Workflow SA: run the ingest job + trigger Dataform + write logs ----
# run.developer (scoped to just this job) is needed because the workflow executes
# the job WITH container overrides (TARGET_MONTH) -> run.jobs.runWithOverrides,
# which roles/run.invoker does not include.
resource "google_cloud_run_v2_job_iam_member" "workflow_invokes_ingest" {
  name     = google_cloud_run_v2_job.ingest.name
  location = var.region
  project  = var.project_id
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.workflow.email}"
}

# Run the transform job (with TARGET_MONTH override) => run.developer.
resource "google_cloud_run_v2_job_iam_member" "workflow_invokes_transform" {
  name     = google_cloud_run_v2_job.transform.name
  location = var.region
  project  = var.project_id
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.workflow.email}"
}

resource "google_project_iam_member" "workflow_run_viewer" {
  project = var.project_id
  role    = "roles/run.viewer"
  member  = "serviceAccount:${google_service_account.workflow.email}"
}

resource "google_project_iam_member" "workflow_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.workflow.email}"
}

# Read the ingest state file (_state/last_ingest.json) to decide whether to transform.
resource "google_storage_bucket_iam_member" "workflow_reads_state" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.workflow.email}"
}

# ---- Scheduler SA: start Workflow executions ----
# Workflow-level IAM isn't in the stable provider; grant workflows.invoker at
# project scope (single workflow in this project).
resource "google_project_iam_member" "scheduler_invokes_workflow" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.scheduler.email}"
}

# ---------------------------------------------------------------------------
# Dataform execution identity. The transform Cloud Run job (`dataform run`)
# runs AS this SA; it holds the BigQuery data access (read bronze, write
# silver/gold) + jobUser to run queries.
# ---------------------------------------------------------------------------
resource "google_service_account" "dataform" {
  account_id   = "sa-taxi-dataform"
  display_name = "Dataform execution SA (runs silver/gold BQ jobs)"
  project      = var.project_id
  depends_on   = [google_project_service.enabled]
}

locals {
  dataform_sa = "serviceAccount:${google_service_account.dataform.email}"
}

resource "google_bigquery_dataset_iam_member" "dataform_bronze_reader" {
  dataset_id = google_bigquery_dataset.bronze.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = local.dataform_sa
  depends_on = [google_project_service.enabled]
}

resource "google_bigquery_dataset_iam_member" "dataform_silver_editor" {
  dataset_id = google_bigquery_dataset.silver.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataEditor"
  member     = local.dataform_sa
  depends_on = [google_project_service.enabled]
}

resource "google_bigquery_dataset_iam_member" "dataform_gold_editor" {
  dataset_id = google_bigquery_dataset.gold.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataEditor"
  member     = local.dataform_sa
  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_member" "dataform_job_user" {
  project    = var.project_id
  role       = "roles/bigquery.jobUser"
  member     = local.dataform_sa
  depends_on = [google_project_service.enabled]
}

# (Removed: dataform_reads_raw. The zone lookup is now a NATIVE bronze table, so
# the transforms read BigQuery only — no GCS access needed by the Dataform SA.)

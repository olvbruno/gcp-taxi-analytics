# ---- Raw (bronze) landing bucket: immutable source-of-truth parquet files ----
resource "google_storage_bucket" "raw" {
  name     = local.raw_bucket
  location = var.region # regional, co-located with BigQuery datasets
  project  = var.project_id

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Raw files never change; version defensively and clean up noncurrent copies.
  versioning { enabled = true }

  lifecycle_rule {
    condition { num_newer_versions = 3 }
    action { type = "Delete" }
  }

  # Age out to cheaper storage classes — raw files are rarely re-read after load.
  lifecycle_rule {
    condition { age = 30 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  lifecycle_rule {
    condition { age = 365 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  labels     = var.labels
  depends_on = [google_project_service.enabled]
}

# ---- Artifact Registry repo for the ingest container image ----
resource "google_artifact_registry_repository" "taxi" {
  repository_id = local.ar_repo
  location      = local.ar_location
  format        = "DOCKER"
  description   = "Ingest job container images for the taxi pipeline."
  labels        = var.labels
  depends_on    = [google_project_service.enabled]
}

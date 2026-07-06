# Ingest job. A Cloud Run *Job* (not a Service) — it runs to completion and
# exits, which is the right shape for a scheduled batch download+load (a
# short-lived function would hit timeout/size limits on a 50 MB download).
#
# NOTE: the image (local.ingest_image) must be pushed to Artifact Registry
# BEFORE this resource is applied. See scripts/build_push.sh and the README
# "apply order" section.
resource "google_cloud_run_v2_job" "ingest" {
  name     = "taxi-ingest"
  location = var.region
  project  = var.project_id

  deletion_protection = false

  template {
    task_count = 1
    template {
      service_account = google_service_account.ingest.email
      timeout         = "900s"
      max_retries     = 1

      containers {
        image = local.ingest_image

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "REGION"
          value = var.region
        }
        env {
          name  = "RAW_BUCKET"
          value = local.raw_bucket
        }
        env {
          name  = "BRONZE_DATASET"
          value = local.ds_bronze
        }
        env {
          name  = "BRONZE_TABLE"
          value = "yellow_trips"
        }
        env {
          name  = "SOURCE_BASE_URL"
          value = var.source_base_url
        }
        env {
          name  = "ZONE_LOOKUP_URL"
          value = var.zone_lookup_url
        }
        env {
          name  = "SOURCE_START_MONTH"
          value = var.source_start_month
        }
      }
    }
  }

  labels     = var.labels
  depends_on = [google_artifact_registry_repository.taxi]
}

# Transform job: runs the bundled Dataform project (`dataform run`) against
# BigQuery as the sa-taxi-dataform SA. Keeps transforms in the monorepo without
# the managed-Dataform git-root constraint. Image built by scripts/build_push.sh.
resource "google_cloud_run_v2_job" "transform" {
  name     = "taxi-transform"
  location = var.region
  project  = var.project_id

  deletion_protection = false

  template {
    task_count = 1
    template {
      service_account = google_service_account.dataform.email
      timeout         = "1800s"
      max_retries     = 1

      containers {
        image = local.transform_image
        resources {
          limits = {
            cpu    = "1"
            memory = "2Gi"
          }
        }
        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "REGION"
          value = var.region
        }
      }
    }
  }

  labels     = var.labels
  depends_on = [google_artifact_registry_repository.taxi]
}

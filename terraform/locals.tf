locals {
  raw_bucket = coalesce(var.raw_bucket_name, "${var.project_id}-taxi-raw")

  # Artifact Registry repo + default ingest image tag.
  ar_repo                 = "taxi"
  ar_location             = var.region
  default_ingest_image    = "${var.region}-docker.pkg.dev/${var.project_id}/taxi/ingest:latest"
  default_transform_image = "${var.region}-docker.pkg.dev/${var.project_id}/taxi/transform:latest"
  ingest_image            = coalesce(var.ingest_image, local.default_ingest_image)
  transform_image         = coalesce(var.transform_image, local.default_transform_image)

  # Dataset names (regional, co-located with the bucket).
  ds_bronze = "taxi_bronze"
  ds_silver = "taxi_silver"
  ds_gold   = "taxi_gold"
}

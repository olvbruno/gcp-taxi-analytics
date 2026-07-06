variable "project_id" {
  description = "GCP project ID that hosts the whole pipeline."
  type        = string
}

variable "region" {
  description = "Single region for GCS bucket AND BigQuery datasets. They MUST be co-located (cross-region joins fail / cost egress). us-central1 is a low-cost Tier-1 region."
  type        = string
  default     = "us-central1"
}

variable "raw_bucket_name" {
  description = "Name of the GCS bucket for raw (bronze) files. Defaults to <project_id>-taxi-raw. Bucket names are globally unique."
  type        = string
  default     = ""
}

variable "ingest_image" {
  description = "Full container image URI for the Cloud Run ingest job. Defaults to the Artifact Registry path built by scripts/build_push.sh. Must be pushed BEFORE the Cloud Run job is applied."
  type        = string
  default     = ""
}

variable "transform_image" {
  description = "Full container image URI for the Cloud Run Dataform transform job. Defaults to the Artifact Registry path built by scripts/build_push.sh. Must be pushed BEFORE the job is applied."
  type        = string
  default     = ""
}

variable "daily_schedule" {
  description = "Cron for the daily pipeline trigger. Runs daily; a new source month only appears ~once/month, so most runs are cheap no-ops."
  type        = string
  default     = "0 9 * * *"
}

variable "scheduler_timezone" {
  description = "Timezone for Cloud Scheduler. NYC data is local wall-clock, so operate on NY time."
  type        = string
  default     = "America/New_York"
}

variable "source_base_url" {
  description = "Public base URL for the monthly Yellow Taxi parquet files."
  type        = string
  default     = "https://d37ci6vzurychx.cloudfront.net/trip-data"
}

variable "zone_lookup_url" {
  description = "Public URL for the taxi zone lookup CSV (static reference)."
  type        = string
  default     = "https://d37ci6vzurychx.cloudfront.net/misc/taxi_zone_lookup.csv"
}

variable "source_start_month" {
  description = "Earliest month the ingest job will consider (YYYY-MM). Bounds the HEAD-probe and the backfill loop."
  type        = string
  default     = "2023-01"
}

variable "labels" {
  description = "Labels applied to billable resources for cost attribution in billing reports."
  type        = map(string)
  default = {
    project = "taxi-analytics"
    managed = "terraform"
  }
}

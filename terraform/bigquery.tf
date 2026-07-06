# ---- Datasets (regional, co-located with the raw bucket) ----
resource "google_bigquery_dataset" "bronze" {
  dataset_id  = local.ds_bronze
  location    = var.region
  project     = var.project_id
  description = "Raw loaded taxi data (medallion: bronze). Loaded verbatim from parquet via free batch load."
  labels      = var.labels
  depends_on  = [google_project_service.enabled]
}

resource "google_bigquery_dataset" "silver" {
  dataset_id  = local.ds_silver
  location    = var.region
  project     = var.project_id
  description = "Cleaned + enriched taxi data (medallion: silver). Built by Dataform."
  labels      = var.labels
  depends_on  = [google_project_service.enabled]
}

resource "google_bigquery_dataset" "gold" {
  dataset_id  = local.ds_gold
  location    = var.region
  project     = var.project_id
  description = "Analytical marts answering the driver-earnings question (medallion: gold). Built by Dataform."
  labels      = var.labels
  depends_on  = [google_project_service.enabled]
}

# ---- Bronze fact table: unified schema across all years, drift-tolerant ----
# Numerics that drift INT<->DOUBLE across TLC years (passenger_count, RatecodeID,
# airport_fee) are stored as FLOAT64 (the superset); silver casts them.
# congestion_surcharge (from ~2019) and airport_fee (from ~2022) are absent in
# older files -> NULLABLE, so a name-mapped load leaves them NULL.
# Partitioned by _source_month (one partition per monthly file) => idempotent
# per-month reload via DELETE+INSERT, and only ~60 partitions over 5 years.
resource "google_bigquery_table" "yellow_trips" {
  dataset_id          = google_bigquery_dataset.bronze.dataset_id
  table_id            = "yellow_trips"
  project             = var.project_id
  deletion_protection = false
  description         = "Yellow taxi trips, one row per ride, loaded verbatim per monthly file."

  time_partitioning {
    type  = "MONTH"
    field = "_source_month"
  }
  clustering = ["pu_location_id"]

  # snake_case, conformed at ingest from the source's CamelCase columns.
  schema = jsonencode([
    { name = "vendor_id", type = "INTEGER", mode = "NULLABLE" },
    { name = "pickup_datetime", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "dropoff_datetime", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "passenger_count", type = "FLOAT", mode = "NULLABLE" },
    { name = "trip_distance", type = "FLOAT", mode = "NULLABLE" },
    { name = "rate_code_id", type = "FLOAT", mode = "NULLABLE" },
    { name = "store_and_fwd_flag", type = "STRING", mode = "NULLABLE" },
    { name = "pu_location_id", type = "INTEGER", mode = "NULLABLE" },
    { name = "do_location_id", type = "INTEGER", mode = "NULLABLE" },
    { name = "payment_type", type = "INTEGER", mode = "NULLABLE" },
    { name = "fare_amount", type = "FLOAT", mode = "NULLABLE" },
    { name = "extra", type = "FLOAT", mode = "NULLABLE" },
    { name = "mta_tax", type = "FLOAT", mode = "NULLABLE" },
    { name = "tip_amount", type = "FLOAT", mode = "NULLABLE" },
    { name = "tolls_amount", type = "FLOAT", mode = "NULLABLE" },
    { name = "improvement_surcharge", type = "FLOAT", mode = "NULLABLE" },
    { name = "total_amount", type = "FLOAT", mode = "NULLABLE" },
    { name = "congestion_surcharge", type = "FLOAT", mode = "NULLABLE" },
    { name = "airport_fee", type = "FLOAT", mode = "NULLABLE" },
    # ---- lineage / control columns added at ingest (keep the _ marker) ----
    { name = "_source_month", type = "DATE", mode = "REQUIRED", description = "First day of the file's month; partition key and idempotency key." },
    { name = "_source_file", type = "STRING", mode = "NULLABLE", description = "GCS URI of the source parquet." },
    { name = "_loaded_at", type = "TIMESTAMP", mode = "NULLABLE", description = "Ingest load timestamp; silver incremental watermark." },
  ])

  labels     = var.labels
  depends_on = [google_bigquery_dataset.bronze]
}

# ---- Taxi zone lookup: NATIVE, VERSIONED bronze table ----
# Loaded by the ingest job with hash-based change detection: one snapshot per
# real change. A native table (vs external) removes the GCS-read-at-query-time
# coupling and lets us keep version history.
resource "google_bigquery_table" "zone_lookup" {
  dataset_id          = google_bigquery_dataset.bronze.dataset_id
  table_id            = "zone_lookup"
  project             = var.project_id
  deletion_protection = false
  description         = "LocationID -> borough/zone reference, versioned (one snapshot per content change)."

  schema = jsonencode([
    { name = "location_id", type = "INTEGER", mode = "NULLABLE" },
    { name = "borough", type = "STRING", mode = "NULLABLE" },
    { name = "zone", type = "STRING", mode = "NULLABLE" },
    { name = "service_zone", type = "STRING", mode = "NULLABLE" },
    { name = "_content_hash", type = "STRING", mode = "NULLABLE", description = "md5 of the source CSV for this snapshot (change detection)." },
    { name = "_snapshot_date", type = "DATE", mode = "NULLABLE", description = "Date this snapshot was loaded." },
    { name = "_loaded_at", type = "TIMESTAMP", mode = "NULLABLE", description = "Load timestamp; latest snapshot = MAX(_loaded_at)." },
  ])

  labels     = var.labels
  depends_on = [google_bigquery_dataset.bronze]
}

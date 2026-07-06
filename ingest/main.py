"""Ingest job for the NYC Yellow Taxi pipeline (Cloud Run Job).

Responsibilities (bronze layer only — cleaning/enrichment is Dataform's job):

  1. Load the taxi-zone lookup as a versioned native bronze table (hash-based:
     new snapshot only when the CSV actually changed).
  2. Resolve which month to load:
       - TARGET_MONTH env set  -> load exactly that month (used for backfill).
       - otherwise             -> the OLDEST published month not yet in bronze
         (self-healing: a multi-month catch-up batch fills one month per run).
  3. Download that month's parquet from the public CloudFront URL to GCS (raw).
  4. Free BigQuery batch-load it into a landing table (schema autodetected).
  5. Atomically replace the month's partition in the unified bronze table via a
     dynamic, drift-tolerant INSERT ... SELECT (handles column presence + INT/
     FLOAT drift + the `Airport_fee` casing quirk across TLC years).
  6. Write a small state file so the orchestrator knows if a new month landed.

Idempotent: re-running a month DELETE+INSERTs its single partition inside one
BigQuery transaction, so there are never duplicates or half-written months.

Load a specific month manually (needs GCP creds/env):  python main.py --month 2023-01
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import os
import sys
import tempfile

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger("taxi-ingest")

# Unified bronze schema: canonical snake_case column -> BigQuery type. Order
# matters — it defines the INSERT column list. Must match terraform/bigquery.tf.
# The source parquet uses CamelCase (VendorID, PULocationID, tpep_*); we conform
# to snake_case at load time via name-normalized matching (+ SOURCE_ALIASES).
BRONZE_COLUMNS: dict[str, str] = {
    "vendor_id": "INT64",
    "pickup_datetime": "TIMESTAMP",
    "dropoff_datetime": "TIMESTAMP",
    "passenger_count": "FLOAT64",
    "trip_distance": "FLOAT64",
    "rate_code_id": "FLOAT64",
    "store_and_fwd_flag": "STRING",
    "pu_location_id": "INT64",
    "do_location_id": "INT64",
    "payment_type": "INT64",
    "fare_amount": "FLOAT64",
    "extra": "FLOAT64",
    "mta_tax": "FLOAT64",
    "tip_amount": "FLOAT64",
    "tolls_amount": "FLOAT64",
    "improvement_surcharge": "FLOAT64",
    "total_amount": "FLOAT64",
    "congestion_surcharge": "FLOAT64",
    "airport_fee": "FLOAT64",
}

# Source names that don't reduce to our snake_case name by just stripping
# underscores + lowercasing (everything else matches automatically).
SOURCE_ALIASES: dict[str, list[str]] = {
    "pickup_datetime": ["tpep_pickup_datetime"],
    "dropoff_datetime": ["tpep_dropoff_datetime"],
}

STATE_OBJECT = "_state/last_ingest.json"
ZONE_LOOKUP_OBJECT = "reference/taxi_zone_lookup.csv"


def _norm(name: str) -> str:
    """Normalize a column name for matching: lowercase, underscores removed."""
    return name.lower().replace("_", "")


# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested; no GCP calls)
# --------------------------------------------------------------------------- #
def month_str(d: dt.date) -> str:
    return d.strftime("%Y-%m")


def month_first_day(month: str) -> dt.date:
    return dt.datetime.strptime(month, "%Y-%m").date().replace(day=1)


def previous_month(d: dt.date) -> dt.date:
    first = d.replace(day=1)
    return (first - dt.timedelta(days=1)).replace(day=1)


def next_month(d: dt.date) -> dt.date:
    if d.month == 12:
        return d.replace(year=d.year + 1, month=1, day=1)
    return d.replace(month=d.month + 1, day=1)


def iter_months_asc(oldest: dt.date, newest: dt.date):
    """Yield month-first dates from oldest up to newest (inclusive)."""
    cur = oldest.replace(day=1)
    stop = newest.replace(day=1)
    while cur <= stop:
        yield cur
        cur = next_month(cur)


def source_url(base_url: str, month: str) -> str:
    return f"{base_url.rstrip('/')}/yellow_tripdata_{month}.parquet"


def raw_object_name(month: str) -> str:
    return f"yellow/yellow_tripdata_{month}.parquet"


def build_partition_replace_sql(
    bronze_fqtn: str,
    landing_fqtn: str,
    landing_columns: list[str],
) -> str:
    """Build the transactional DELETE+INSERT that replaces one month partition.

    Drift-tolerant + name-conforming: for each canonical snake_case bronze column
    we emit
      SAFE_CAST(`source` AS TYPE) AS `snake`   if a matching source column exists
          (matched by normalized name -> handles CamelCase `VendorID`->`vendor_id`,
           `Airport_fee`->`airport_fee`, and aliases like `tpep_pickup_datetime`->
           `pickup_datetime`)
      CAST(NULL AS TYPE) AS `snake`             otherwise (column absent in old files)
    Control columns (_source_month/_source_file/_loaded_at) come from params.
    """
    norm_to_actual = {_norm(c): c for c in landing_columns}

    select_exprs: list[str] = []
    for col, bqtype in BRONZE_COLUMNS.items():
        actual = None
        for candidate in [col, *SOURCE_ALIASES.get(col, [])]:
            actual = norm_to_actual.get(_norm(candidate))
            if actual:
                break
        if actual is not None:
            select_exprs.append(f"SAFE_CAST(`{actual}` AS {bqtype}) AS `{col}`")
        else:
            select_exprs.append(f"CAST(NULL AS {bqtype}) AS `{col}`")

    # Control columns.
    select_exprs.append("@source_month AS `_source_month`")
    select_exprs.append("@source_file AS `_source_file`")
    select_exprs.append("CURRENT_TIMESTAMP() AS `_loaded_at`")

    insert_cols = ", ".join(f"`{c}`" for c in BRONZE_COLUMNS) + (
        ", `_source_month`, `_source_file`, `_loaded_at`"
    )
    select_clause = ",\n         ".join(select_exprs)

    return f"""
BEGIN TRANSACTION;
DELETE FROM `{bronze_fqtn}` WHERE `_source_month` = @source_month;
INSERT INTO `{bronze_fqtn}` ({insert_cols})
  SELECT {select_clause}
  FROM `{landing_fqtn}`;
COMMIT TRANSACTION;
""".strip()


# --------------------------------------------------------------------------- #
# I/O helpers (network / GCP — thin wrappers so the core logic stays testable)
# --------------------------------------------------------------------------- #
def http_exists(url: str) -> bool:
    import requests

    try:
        r = requests.head(url, timeout=30, allow_redirects=True)
        return r.status_code == 200
    except requests.RequestException as e:
        log.warning("HEAD %s failed: %s", url, e)
        return False


def download(url: str, dest: str) -> None:
    import requests

    log.info("Downloading %s", url)
    with requests.get(url, stream=True, timeout=300) as r:
        r.raise_for_status()
        with open(dest, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
    log.info("Downloaded %.1f MB -> %s", os.path.getsize(dest) / 1e6, dest)


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
class Config:
    def __init__(self) -> None:
        self.project = os.environ["PROJECT_ID"]
        self.region = os.environ.get("REGION", "us-central1")
        self.raw_bucket = os.environ["RAW_BUCKET"]
        self.bronze_dataset = os.environ.get("BRONZE_DATASET", "taxi_bronze")
        self.bronze_table = os.environ.get("BRONZE_TABLE", "yellow_trips")
        self.zone_table = os.environ.get("ZONE_TABLE", "zone_lookup")
        self.source_base_url = os.environ["SOURCE_BASE_URL"]
        self.zone_lookup_url = os.environ["ZONE_LOOKUP_URL"]
        self.start_month = os.environ.get("SOURCE_START_MONTH", "2023-01")
        self.target_month = (os.environ.get("TARGET_MONTH") or "").strip() or None

    @property
    def bronze_fqtn(self) -> str:
        return f"{self.project}.{self.bronze_dataset}.{self.bronze_table}"

    @property
    def landing_fqtn(self) -> str:
        return f"{self.project}.{self.bronze_dataset}.{self.bronze_table}_landing"

    @property
    def zone_fqtn(self) -> str:
        return f"{self.project}.{self.bronze_dataset}.{self.zone_table}"

    @property
    def zone_landing_fqtn(self) -> str:
        return f"{self.project}.{self.bronze_dataset}.{self.zone_table}_landing"


# --------------------------------------------------------------------------- #
# GCP operations
# --------------------------------------------------------------------------- #
def load_zone_lookup(cfg: Config, bq, storage_client) -> None:
    """Load the taxi-zone lookup as a native, VERSIONED bronze table.

    Hash-based change detection: download the CSV, hash it, and only append a NEW
    snapshot when the content differs from the latest one already stored. So the
    table keeps one row-set per real change (not one per daily run), giving full
    version history at near-zero cost.
    """
    import hashlib

    import requests
    from google.cloud import bigquery

    csv_bytes = requests.get(cfg.zone_lookup_url, timeout=60).content
    content_hash = hashlib.md5(csv_bytes).hexdigest()

    # Keep the raw CSV in GCS too (audit / re-load source).
    storage_client.bucket(cfg.raw_bucket).blob(ZONE_LOOKUP_OBJECT).upload_from_string(
        csv_bytes, content_type="text/csv"
    )

    latest = next(
        iter(
            bq.query(
                f"SELECT _content_hash AS h FROM `{cfg.zone_fqtn}` "
                "ORDER BY _loaded_at DESC LIMIT 1"
            ).result()
        ),
        None,
    )
    if latest is not None and latest.h == content_hash:
        log.info("Zone lookup unchanged (hash %s…); no new snapshot.", content_hash[:8])
        return

    gcs_uri = f"gs://{cfg.raw_bucket}/{ZONE_LOOKUP_OBJECT}"
    bq.load_table_from_uri(
        gcs_uri,
        cfg.zone_landing_fqtn,
        job_config=bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=1,
            write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
            autodetect=True,
        ),
    ).result()

    bq.query(
        f"""
        INSERT INTO `{cfg.zone_fqtn}`
          (location_id, borough, zone, service_zone, _content_hash, _snapshot_date, _loaded_at)
        SELECT SAFE_CAST(LocationID AS INT64), CAST(Borough AS STRING),
               CAST(Zone AS STRING), CAST(service_zone AS STRING),
               @hash, CURRENT_DATE(), CURRENT_TIMESTAMP()
        FROM `{cfg.zone_landing_fqtn}`
        """,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("hash", "STRING", content_hash)]
        ),
    ).result()
    log.info("Loaded new zone-lookup snapshot (hash %s…).", content_hash[:8])


def loaded_months(cfg: Config, bq) -> set[str]:
    """All months already in bronze, as {'YYYY-MM'}. One cheap query."""
    try:
        return {
            row.m
            for row in bq.query(
                f"SELECT DISTINCT FORMAT_DATE('%Y-%m', `_source_month`) AS m "
                f"FROM `{cfg.bronze_fqtn}`"
            ).result()
        }
    except Exception as e:  # table missing/empty on first ever run
        log.info("Could not read loaded months (%s); assuming none.", e)
        return set()


def resolve_target_month(cfg: Config, bq) -> str | None:
    """Explicit TARGET_MONTH, else the OLDEST published month not yet in bronze.

    Oldest-first (not newest-first) makes the daily job SELF-HEALING: if the
    source delivers several months at once after a delay, successive daily runs
    fill the gap one month per day (and a permanently-missing source month is
    simply skipped, never blocking newer ones).
    """
    if cfg.target_month:
        return cfg.target_month

    today = dt.date.today()
    oldest = month_first_day(cfg.start_month)
    newest = today.replace(day=1)  # probe up to the current month (unpublished ones 404 and are skipped)
    done = loaded_months(cfg, bq)

    for d in iter_months_asc(oldest, newest):
        m = month_str(d)
        if m in done:
            continue
        if http_exists(source_url(cfg.source_base_url, m)):
            log.info("Oldest unloaded published month: %s", m)
            return m
    log.info("No unloaded published month in range; nothing to do.")
    return None


def load_month(cfg: Config, bq, storage_client, month: str) -> int:
    from google.cloud import bigquery

    url = source_url(cfg.source_base_url, month)
    if not http_exists(url):
        raise FileNotFoundError(f"Source file not found: {url}")

    # 1. Download -> GCS raw (immutable bronze file).
    with tempfile.TemporaryDirectory() as tmp:
        local = os.path.join(tmp, f"yellow_{month}.parquet")
        download(url, local)
        obj = raw_object_name(month)
        gcs_uri = f"gs://{cfg.raw_bucket}/{obj}"
        storage_client.bucket(cfg.raw_bucket).blob(obj).upload_from_filename(local)
        log.info("Uploaded to %s", gcs_uri)

    # 2. Free batch-load parquet -> landing (autodetect; schema varies by year).
    load_cfg = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.PARQUET,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        autodetect=True,
    )
    log.info("Loading %s into landing %s", gcs_uri, cfg.landing_fqtn)
    bq.load_table_from_uri(gcs_uri, cfg.landing_fqtn, job_config=load_cfg).result()
    landing = bq.get_table(cfg.landing_fqtn)
    landing_cols = [f.name for f in landing.schema]
    log.info("Landing loaded: %d rows, %d cols", landing.num_rows, len(landing_cols))

    # 3. Atomic partition replace into bronze (drift-tolerant, idempotent).
    sql = build_partition_replace_sql(cfg.bronze_fqtn, cfg.landing_fqtn, landing_cols)
    params = [
        bigquery.ScalarQueryParameter(
            "source_month", "DATE", month_first_day(month)
        ),
        bigquery.ScalarQueryParameter("source_file", "STRING", gcs_uri),
    ]
    bq.query(
        sql, job_config=bigquery.QueryJobConfig(query_parameters=params)
    ).result()

    rows = next(
        iter(
            bq.query(
                f"SELECT COUNT(1) AS n FROM `{cfg.bronze_fqtn}` "
                "WHERE `_source_month` = @m",
                job_config=bigquery.QueryJobConfig(
                    query_parameters=[
                        bigquery.ScalarQueryParameter(
                            "m", "DATE", month_first_day(month)
                        )
                    ]
                ),
            ).result()
        )
    ).n
    log.info("Bronze partition %s now has %d rows", month, rows)
    return rows


def write_state(cfg: Config, storage_client, status: str, month: str | None, rows: int) -> None:
    payload = {
        "status": status,  # "loaded" | "skipped"
        "month": month,
        "rows": rows,
        "at": dt.datetime.utcnow().isoformat() + "Z",
    }
    storage_client.bucket(cfg.raw_bucket).blob(STATE_OBJECT).upload_from_string(
        json.dumps(payload), content_type="application/json"
    )
    log.info("Wrote state: %s", payload)


# --------------------------------------------------------------------------- #
# Entrypoints
# --------------------------------------------------------------------------- #
def run(cfg: Config) -> dict:
    from google.cloud import bigquery, storage

    bq = bigquery.Client(project=cfg.project, location=cfg.region)
    storage_client = storage.Client(project=cfg.project)

    load_zone_lookup(cfg, bq, storage_client)

    month = resolve_target_month(cfg, bq)
    if month is None:
        write_state(cfg, storage_client, "skipped", None, 0)
        return {"status": "skipped"}

    log.info("Target month: %s", month)
    rows = load_month(cfg, bq, storage_client, month)
    write_state(cfg, storage_client, "loaded", month, rows)
    return {"status": "loaded", "month": month, "rows": rows}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Taxi ingest job")
    ap.add_argument("--month", help="YYYY-MM to load (overrides TARGET_MONTH env)")
    args = ap.parse_args(argv)

    if args.month:
        os.environ["TARGET_MONTH"] = args.month
    result = run(Config())
    log.info("Done: %s", result)
    return 0


if __name__ == "__main__":
    sys.exit(main())

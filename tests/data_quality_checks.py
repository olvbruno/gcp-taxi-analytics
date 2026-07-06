"""Cross-layer data-quality / reconciliation tests (run against live BigQuery).

Complements the Dataform assertions (which gate every transform run) with
end-to-end reconciliation across the star schema:
  - bronze integrity + source-truth row count
  - bronze -> silver (stg_trips) reconciliation (valid-row count matches exactly)
  - stg_trips internal accuracy (keys, derived columns)
  - gold fact_trip reconciles to stg_trips + zone dimension resolves
  - gold marts reconcile to fact_trip

Auth: Application Default Credentials (gcloud auth application-default login).
Usage:  PROJECT_ID=<proj> python tests/data_quality_checks.py
Exit code is non-zero if any check fails (CI-friendly).
"""
from __future__ import annotations

import os
import sys

from google.cloud import bigquery

PROJECT = os.environ.get("PROJECT_ID") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not PROJECT:
    sys.exit("set PROJECT_ID env var or pass project id as arg")

BQ = bigquery.Client(project=PROJECT)
FAILURES: list[str] = []


def rows(sql: str) -> list[dict]:
    return [dict(r) for r in BQ.query(sql).result()]


def check(name: str, sql: str, ok) -> None:
    r = rows(sql)
    passed = bool(ok(r))
    print(f"[{'PASS' if passed else 'FAIL'}] {name}")
    for row in r:
        print("        " + ", ".join(f"{k}={v}" for k, v in row.items()))
    if not passed:
        FAILURES.append(name)


# ---------------- BRONZE (raw source names kept) ----------------
check(
    "bronze: partition key never null; one source file per month",
    "SELECT COUNTIF(_source_month IS NULL) null_pk, "
    "COUNT(DISTINCT _source_file) files, COUNT(DISTINCT _source_month) months "
    "FROM `taxi_bronze.yellow_trips`",
    lambda r: r[0]["null_pk"] == 0 and r[0]["files"] == r[0]["months"],
)
check(
    "bronze: 2023-01 row count == known source truth (3,066,766)",
    "SELECT COUNT(*) n FROM `taxi_bronze.yellow_trips` WHERE _source_month = DATE '2023-01-01'",
    lambda r: r[0]["n"] == 3066766,
)

# ---------- BRONZE -> SILVER reconciliation (per month present in silver) ----------
check(
    "reconcile: bronze valid-rows == stg_trips rows, per month",
    """
    WITH sm AS (SELECT DISTINCT _source_month FROM `taxi_silver.stg_trips`),
    bronze_keep AS (
      SELECT _source_month AS m, COUNTIF(
        pickup_datetime IS NOT NULL
        AND dropoff_datetime > pickup_datetime
        AND TIMESTAMP_DIFF(dropoff_datetime, pickup_datetime, SECOND)/60.0 BETWEEN 1 AND 720
        AND fare_amount >= 0 AND total_amount >= 0 AND trip_distance >= 0
        AND pu_location_id IS NOT NULL
        AND DATE(pickup_datetime) >= _source_month
        AND DATE(pickup_datetime) < DATE_ADD(_source_month, INTERVAL 1 MONTH)
      ) AS keep
      FROM `taxi_bronze.yellow_trips`
      WHERE _source_month IN (SELECT _source_month FROM sm)
      GROUP BY 1
    ),
    silver_cnt AS (SELECT _source_month AS m, COUNT(*) AS n FROM `taxi_silver.stg_trips` GROUP BY 1)
    SELECT COUNTIF(b.keep != s.n) AS mismatched_months, COUNT(*) AS months_checked
    FROM bronze_keep b JOIN silver_cnt s USING (m)
    """,
    lambda r: r[0]["mismatched_months"] == 0 and r[0]["months_checked"] > 0,
)

# ---------------- SILVER internal accuracy ----------------
check(
    "stg_trips: unique key, no null keys, correct derived columns",
    """
    SELECT
      COUNT(*) - COUNT(DISTINCT trip_sk) AS dup_keys,
      COUNTIF(trip_sk IS NULL OR pickup_date IS NULL OR pu_location_id IS NULL OR driver_revenue IS NULL) AS null_keys,
      COUNTIF(ABS(driver_revenue - (fare_amount + tip_amount)) > 0.001) AS rev_mismatch,
      COUNTIF(trip_minutes < 1 OR trip_minutes > 720) AS bad_duration,
      COUNTIF(fare_amount < 0) AS neg_fare,
      COUNTIF(pickup_date < _source_month OR pickup_date >= DATE_ADD(_source_month, INTERVAL 1 MONTH)) AS out_of_month
    FROM `taxi_silver.stg_trips`
    """,
    lambda r: all(v == 0 for v in r[0].values()),
)

# ---------------- GOLD: fact reconciles to silver + dims resolve ----------------
check(
    "fact_trip: row count == stg_trips (LEFT JOIN to dims preserves grain)",
    "SELECT (SELECT COUNT(*) FROM `taxi_gold.fact_trip`) fact, "
    "(SELECT COUNT(*) FROM `taxi_silver.stg_trips`) silver",
    lambda r: r[0]["fact"] == r[0]["silver"],
)
check(
    "fact_trip: every pickup zone resolved in dim_zone (no unmatched FKs)",
    "SELECT COUNTIF(is_airport_pickup IS NULL) unmatched_pu_zone FROM `taxi_gold.fact_trip`",
    lambda r: r[0]["unmatched_pu_zone"] == 0,
)

# ---------------- GOLD marts reconcile to fact ----------------
check(
    "gold tipping_by_payment: SUM(trips) == fact_trip row count",
    "SELECT (SELECT SUM(trips) FROM `taxi_gold.tipping_by_payment`) gold, "
    "(SELECT COUNT(*) FROM `taxi_gold.fact_trip`) fact",
    lambda r: r[0]["gold"] == r[0]["fact"],
)
check(
    "gold hourly_pulse: SUM(trips) == fact rows (same mph filter)",
    "SELECT (SELECT SUM(trips) FROM `taxi_gold.hourly_pulse`) gold, "
    "(SELECT COUNT(*) FROM `taxi_gold.fact_trip` WHERE mph IS NOT NULL AND mph BETWEEN 0 AND 80) fact",
    lambda r: r[0]["gold"] == r[0]["fact"],
)
check(
    "gold airport_economics JFK median ~= recomputed from fact (approx-quantile tolerance)",
    "SELECT (SELECT median_driver_revenue FROM `taxi_gold.airport_economics` WHERE segment='JFK pickup') mart, "
    "(SELECT APPROX_QUANTILES(driver_revenue,100)[OFFSET(50)] FROM `taxi_gold.fact_trip` WHERE pu_location_id=132) recomputed",
    lambda r: abs(float(r[0]["mart"]) - float(r[0]["recomputed"])) <= 0.5,
)
check(
    "gold zone_hour_earnings: every published cell honors trips>=30 suppression",
    "SELECT COUNTIF(trips < 30) violating, COUNT(*) total FROM `taxi_gold.zone_hour_earnings`",
    lambda r: r[0]["violating"] == 0,
)

print()
if FAILURES:
    print(f"{len(FAILURES)} check(s) FAILED: {FAILURES}")
    sys.exit(1)
print("All data-quality checks passed.")

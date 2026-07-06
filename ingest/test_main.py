"""Unit tests for the ingest pure logic (no GCP calls)."""
import datetime as dt

import main


def test_previous_month_crosses_year():
    assert main.previous_month(dt.date(2023, 1, 15)) == dt.date(2022, 12, 1)
    assert main.previous_month(dt.date(2023, 3, 31)) == dt.date(2023, 2, 1)


def test_next_month_crosses_year():
    assert main.next_month(dt.date(2023, 12, 15)) == dt.date(2024, 1, 1)
    assert main.next_month(dt.date(2023, 1, 31)) == dt.date(2023, 2, 1)


def test_iter_months_asc_inclusive():
    got = list(main.iter_months_asc(dt.date(2023, 1, 1), dt.date(2023, 3, 10)))
    assert got == [dt.date(2023, 1, 1), dt.date(2023, 2, 1), dt.date(2023, 3, 1)]


def test_month_first_day():
    assert main.month_first_day("2023-01") == dt.date(2023, 1, 1)


def test_url_helpers():
    base = "https://x/trip-data"
    assert main.source_url(base, "2023-01") == "https://x/trip-data/yellow_tripdata_2023-01.parquet"
    assert main.source_url(base + "/", "2023-01").endswith("yellow_tripdata_2023-01.parquet")
    assert main.raw_object_name("2023-01") == "yellow/yellow_tripdata_2023-01.parquet"


def test_partition_replace_sql_is_transactional():
    cols = list(main.BRONZE_COLUMNS.keys())
    sql = main.build_partition_replace_sql("p.d.t", "p.d.t_landing", cols)
    assert "BEGIN TRANSACTION;" in sql
    assert "COMMIT TRANSACTION;" in sql
    assert "DELETE FROM `p.d.t` WHERE `_source_month` = @source_month;" in sql
    assert "INSERT INTO `p.d.t`" in sql
    assert "@source_month AS `_source_month`" in sql
    assert "CURRENT_TIMESTAMP() AS `_loaded_at`" in sql


def test_partition_replace_sql_conforms_source_names_to_snake_case():
    # Real TLC source spellings: CamelCase + capital-A Airport_fee + tpep_ prefix.
    cols = ["VendorID", "PULocationID", "RatecodeID", "tpep_pickup_datetime", "Airport_fee"]
    sql = main.build_partition_replace_sql("p.d.t", "p.d.t_landing", cols)
    assert "SAFE_CAST(`VendorID` AS INT64) AS `vendor_id`" in sql
    assert "SAFE_CAST(`PULocationID` AS INT64) AS `pu_location_id`" in sql
    assert "SAFE_CAST(`RatecodeID` AS FLOAT64) AS `rate_code_id`" in sql
    assert "SAFE_CAST(`tpep_pickup_datetime` AS TIMESTAMP) AS `pickup_datetime`" in sql
    assert "SAFE_CAST(`Airport_fee` AS FLOAT64) AS `airport_fee`" in sql


def test_partition_replace_sql_nulls_missing_columns():
    # Old file lacking congestion_surcharge/airport_fee -> emitted as typed NULL.
    cols = ["VendorID", "trip_distance"]
    sql = main.build_partition_replace_sql("p.d.t", "p.d.t_landing", cols)
    assert "CAST(NULL AS FLOAT64) AS `congestion_surcharge`" in sql
    assert "CAST(NULL AS FLOAT64) AS `airport_fee`" in sql
    assert "SAFE_CAST(`trip_distance` AS FLOAT64) AS `trip_distance`" in sql


def test_all_bronze_columns_appear_in_insert():
    cols = list(main.BRONZE_COLUMNS.keys())
    sql = main.build_partition_replace_sql("p.d.t", "p.d.t_landing", cols)
    for c in main.BRONZE_COLUMNS:
        assert f"`{c}`" in sql

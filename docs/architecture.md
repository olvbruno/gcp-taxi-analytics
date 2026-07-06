# Architecture & GCP service choices

This doc explains **what** runs and **why** each GCP service was picked over the
alternatives.

## Services at a glance

| Concern | Service | Why |
| --- | --- | --- |
| Object storage (raw files) | **Cloud Storage (GCS)** | Regional bucket co-located with BigQuery for free loads. |
| SQL warehouse / query engine | **BigQuery** | Serverless, pay-per-query, 1 TiB/mo free. No cluster to size or pay for idle. |
| Table catalog | **BigQuery** (built-in) | BQ is its own catalog. |
| Batch compute / ETL | **Cloud Run Job** (ingest) + **BigQuery SQL** (transforms) | ELT: do transforms *in* the warehouse; avoid a Spark cluster entirely. |
| Transform framework | **Dataform** | GCP-native, free, SQL + DAG + tests. See below. |
| Orchestration / state machine | **Cloud Workflows** | Serverless, ~free at this scale. |
| Cron / scheduler | **Cloud Scheduler** | 3 free jobs. |
| Workload identity | **Service account** (attached per resource) | Each resource runs as an explicitly-attached SA. |
| IaC | **Terraform** | Best GCP provider support; reproducible. |
| Container registry | **Artifact Registry** | Holds the ingest + transform images. |
| Image build | **Cloud Build** | Build in-cloud; no local Docker needed on Windows. |

## The pipeline

```
Cloud Scheduler (daily, NY time)
   └─► Cloud Workflows: "taxi-pipeline"
          ├─ 1. run Cloud Run Job "taxi-ingest"
          │      • resolve newest un-loaded month
          │      • download parquet ► GCS raw/ (immutable bronze file)
          │      • FREE BigQuery load ► landing table
          │      • atomic DELETE+INSERT ► bronze.yellow_trips (one month partition)
          │      • write _state/last_ingest.json
          ├─ 2. read the state file
          └─ 3. if a NEW month was loaded → run the transform job (Cloud Run
                 job that runs `dataform run` as sa-taxi-dataform):
                 • silver.stg_trips + stg_zone (clean, incremental MERGE)
                 • gold star: fact_trip + 5 dims + 7 marts
                 • assertions      (data-quality gate)
```

## Why these services (and not the alternatives)

**BigQuery (ELT), not Dataflow or Dataproc.**
The data is tiny — ~50 MB / ~3 M rows per month. A `bq load` (free) plus a SQL
`MERGE` does everything cleaning/enrichment needs. Dataflow (Beam) and Dataproc
(Spark) both spin up **worker VMs you pay for** to do what BigQuery does for
$0 inside the free tier. They earn their keep at 100s of GB–TB per run or for
true streaming; here they are pure cost with no benefit.

**Cloud Run Job, not Cloud Functions or Dataflow, for ingest.**
The ingest step is "download a 50 MB file and kick off a load job." A Cloud Run
*Job* (run-to-completion, up to 60 min, generous memory) fits batch download far
better than a Function (short timeout, smaller limits). It's billed only for the
seconds it runs — ~2 min/day — which stays inside the Cloud Run free tier.

**Dataform, not dbt or raw scheduled queries.**
- *Dataform* is GCP-native and **free** (you pay only the underlying BigQuery
  compute, ~$0 here). It gives a dependency DAG, incremental tables, and
  **built-in assertions** (data-quality tests) with zero extra infrastructure.
- *dbt Core* is great but needs a **runner** (Cloud Run/Composer) or paid dbt
  Cloud — an extra moving part Dataform makes unnecessary.
- *Scheduled queries* have no DAG, no tests, no lineage — too thin for a
  "production-robust" bar.

  *How it runs here:* managed Dataform-from-Git requires the Dataform project to
  sit at a **git repo root**, but this is a monorepo (`dataform/` is a subdir).
  So instead of a second repo, the project is bundled into a container and run by
  the `taxi-transform` Cloud Run job (`dataform run`, as `sa-taxi-dataform`).
  Same Dataform benefits, one source of truth, no git-root constraint.

**Cloud Workflows, not Cloud Composer (Airflow).**
A Composer environment carries a **standing GKE + Cloud SQL footprint costing
~$300–500+/month even when idle** — over 100× this entire pipeline's bill.
Cloud Workflows is serverless and effectively free at this volume, and the DAG
here (ingest → maybe-transform) is simple enough that Workflows is plenty.

## What makes it robust

- **Incremental & idempotent.** Bronze is partitioned by `_source_month`; a
  reload DELETE+INSERTs a single partition inside one BigQuery transaction —
  no dupes, no half-written months. Silver is a Dataform incremental MERGE keyed
  on a trip fingerprint, so re-runs converge.
- **Gated transforms.** The expensive SQL only runs when a *new* month actually
  landed (the Workflow checks the ingest state file), so 29 of 30 daily runs are
  near-zero-cost no-ops.
- **Schema-drift tolerant.** The ingest builds the bronze INSERT dynamically from
  each file's real columns (handles missing `airport_fee`/`congestion_surcharge`
  in old years, INT↔FLOAT drift, and the `Airport_fee` casing quirk).
- **Data-quality as a gate.** Dataform assertions (uniqueness, non-null,
  row conditions, gold sanity) fail the run if the data is wrong.
- **Least privilege.** Three scoped service accounts; no broad roles.
- **Fully reproducible.** Everything is Terraform + versioned SQL/code.

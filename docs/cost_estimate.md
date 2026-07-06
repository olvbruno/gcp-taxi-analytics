# Cost estimate (production: 5 years of data, daily runs)

**Bottom line: ≈ $0–$2 / month.** Everything except a sliver of BigQuery storage
fits inside GCP's Always-Free tier, and that sliver drops to ~$0 with
compressed-storage billing.

## Pricing used (2026, us-central1)

| Service | Rate | Always-Free tier |
| --- | --- | --- |
| BigQuery on-demand query | **$6.25 / TiB** scanned | 1 TiB / month |
| BigQuery active storage | $0.02 / GB-month | 10 GiB |
| BigQuery long-term storage (90+ days untouched) | $0.01 / GB-month | (auto) |
| BigQuery batch load from GCS | **$0.00** | — |
| GCS Standard (single region) | $0.020 / GB-month | 5 GB |
| Cloud Run Jobs | vCPU $0.000024/s, mem $0.0000025/GiB-s | 180k vCPU-s, 360k GiB-s |
| Cloud Workflows | $0.01 / 1,000 internal steps | 5,000 steps/mo |
| Cloud Scheduler | $0.10 / job/mo | 3 jobs |

> Note: the old "$5/TB" number is stale — BigQuery on-demand is now
> **$6.25 per TiB** (binary TiB). Batch loads are free; **never** use streaming
> inserts here (they bill per byte).

## Assumptions

- 60 monthly files, ~3 M rows each → **~180 M rows / ~3 GB parquet** over 5 years.
- BigQuery logical (uncompressed) storage ~150 B/row → bronze ~27 GB + silver
  ~30 GB + tiny gold ≈ **~60 GB logical** (~6–10 GB *physical*/compressed).
- Daily Scheduler run; a new month appears ~once/month, so ~29 of 30 runs do
  near-zero work (ingest no-op, transforms skipped).

## Monthly cost in steady state

| Service | Basis | Monthly |
| --- | --- | --- |
| BigQuery query | New-month transform scans ~1 partition (~0.2 GB); monthly gold rebuild scans silver (~0.03 TiB). Total ≪ 1 TiB free. | **$0.00** |
| BigQuery storage | ~60 GB logical − 10 GB free, mostly long-term ($0.01). | **~$0.50–$1.00** (logical) / **~$0** (physical billing) |
| GCS Standard | ~3 GB @ $0.020 | **~$0.06** |
| Cloud Run Jobs | ~30 runs × ~120 s × 1 vCPU/1 GiB ≈ 3.6k vCPU-s — under free tier | **$0.00** |
| Cloud Workflows | ~30 runs × ~20 steps = ~600 steps ≪ 5,000 free | **$0.00** |
| Cloud Scheduler | 1 job (3 free) | **$0.00** |
| **Total** | | **≈ $0–$2 / month** |

## One-time backfill (5 years)

Also effectively **free**: loads are $0, and scanning ~30 GB a handful of times
during backfill is a rounding error against the 1 TiB/month query allowance. The
backfill loops the ingest job over 60 months (see `scripts/backfill.sh`).

## How the design keeps cost near zero

1. **Load, don't stream** — batch loads from GCS are free.
2. **Transform in BigQuery** — no Dataflow/Dataproc/Composer VMs.
3. **Partition + cluster** — silver/gold read only the new month's partitions.
4. **Gate the transforms** — SQL runs only when a new month lands, not daily.
5. **Single region** — co-located GCS + BQ ⇒ free loads, no egress.
6. **`require_partition_filter` guard** — an accidental full-table `SELECT *`
   can't silently scan (and bill) 5 years at once.

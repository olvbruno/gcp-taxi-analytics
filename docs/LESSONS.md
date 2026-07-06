# NYC Taxi Analytics on GCP — a guided walkthrough

A teaching companion to this repo, written for someone who **knows AWS and is new
to GCP**. It explains not just *what* is here but *why* each decision was made,
component by component. Read top to bottom, or jump to a lesson.

The project answers one business question — **"how should a new NYC taxi driver
maximize earnings?"** — with a cost-optimized, incremental, production-robust GCP
data pipeline. Everything is Infrastructure-as-Code (Terraform), transforms are
SQL (Dataform), and the whole thing runs for ≈ **$0–2/month**.

| # | Lesson | The question it answers |
|---|---|---|
| 1 | [Repo structure](#lesson-1--repo-structure) | Where does everything live, and why this layout? |
| 2 | [Terraform / IaC](#lesson-2--terraform--iac) | How is the cloud defined as code? |
| 3 | [The ingest job](#lesson-3--the-ingest-job) | How does a raw month get into the lake? |
| 4 | [Data model: medallion → star](#lesson-4--the-data-model-medallion--star) | Why bronze/silver/gold + a Kimball star? |
| 5 | [Dataform](#lesson-5--dataform-how-sqlx-files-become-a-pipeline) | How does SQL become an ordered, tested pipeline? |
| 6 | [Orchestration](#lesson-6--orchestration-cloud-workflows--cloud-scheduler) | How does "daily" happen, and why is it cheap? |
| 7 | [Data quality](#lesson-7--data-quality) | How do we *prove* each layer is correct? |
| 8 | [Cost model](#lesson-8--cost-model) | Why ~$0–2/month, and what would break that? |
| 9 | [Visualizing the results](#lesson-9--visualizing-the-results-local-notebook) | How does the star become the earnings story? |

---

## Lesson 1 — Repo structure

The repo is organized by **role in the pipeline**, not by technology. Each
top-level folder is one concern, so you can reason about (and change) one part
without touching the others.

```
gcp-taxi-analytics/
├─ README.md              # the main deliverable: services + why, cost, findings
├─ terraform/             # ALL cloud infrastructure as code (Lesson 2)
├─ ingest/                # Python Cloud Run job: source → bronze (Lesson 3)
├─ dataform/              # SQL transforms: bronze → silver → gold (Lessons 4–5)
├─ workflows/             # Cloud Workflows orchestration YAML (Lesson 6)
├─ tests/                 # cross-layer data-quality reconciliation (Lesson 7)
├─ analysis/             # standalone analytical queries + results
├─ scripts/              # bootstrap.sh, build_push.sh, backfill.sh (operator tasks)
└─ docs/                 # architecture, data_model, cost_estimate, findings, this file
```

**Why this shape:**

- **One folder = one job.** `ingest/` is *only* about getting raw data in;
  `dataform/` is *only* about transforming it. This mirrors the pipeline stages,
  so "where do I fix X?" has an obvious answer.
- **Infra is separated from logic.** `terraform/` describes *what cloud resources
  exist*; `ingest/` and `dataform/` describe *what they do*. You can read the
  whole system's topology from `terraform/` alone.
- **Code and its tests sit together.** `ingest/test_main.py` next to
  `ingest/main.py`; `tests/` holds the cross-layer checks that need a live
  warehouse.
- **`scripts/` = the human runbook.** The handful of things an operator runs by
  hand (first-time bootstrap, building images, backfilling history) are captured
  as scripts, not tribal knowledge.

The mental model: **read `terraform/` to learn the *nouns* (what exists), read
`ingest/` + `dataform/` to learn the *verbs* (what happens).**

---

## Lesson 2 — Terraform / IaC

Everything in the cloud is declared in `terraform/`. There are no click-ops; if
it exists in GCP, it's because a `.tf` file says so. This is the GCP equivalent
of CloudFormation/CDK — but Terraform has the best GCP provider support, so it's
the standard choice.

### The file layout (one concern per file)

| File | What it declares | AWS analogy |
|---|---|---|
| `providers.tf` | the `google` + `google-beta` providers, ADC auth | provider/credential config |
| `backend.tf` | remote **state** in a GCS bucket | S3+DynamoDB TF backend |
| `variables.tf` / `locals.tf` | inputs + computed values | Parameters / Mappings |
| `apis.tf` | which GCP APIs to enable | (no AWS equivalent — GCP gates services) |
| `storage.tf` | the GCS raw bucket | S3 bucket |
| `bigquery.tf` | datasets + bronze tables | Glue DB + tables |
| `iam.tf` | service accounts + role grants | IAM roles + policies |
| `cloudrun.tf` | the ingest + transform jobs | ECS/Batch task defs |
| `workflows.tf` | the orchestrator | Step Functions state machine |
| `scheduler.tf` | the daily cron | EventBridge Scheduler rule |
| `dataform.tf` | the Dataform repository resource | — |
| `outputs.tf` | handy values after apply | Stack Outputs |

### Three GCP-specific things that surprise AWS people

**1. You must *enable APIs* before using services.** In AWS, S3 and Lambda just
work. In GCP, every service is behind a project-level API switch. That's what
`apis.tf` does — `google_project_service` for BigQuery, Cloud Run, Workflows,
etc. Everything else `depends_on` these being enabled (you'll see
`depends_on = [google_project_service.enabled]` throughout `iam.tf`).

**2. There's no implicit "instance role."** In AWS an EC2/Lambda has an instance
profile attached by convention. In GCP, a workload runs **as a service account
that you attach explicitly**. So `iam.tf` creates one SA per component and wires
its permissions by hand:

```hcl
resource "google_service_account" "ingest"    { account_id = "sa-taxi-ingest" }
resource "google_service_account" "workflow"   { account_id = "sa-taxi-workflow" }
resource "google_service_account" "scheduler"  { account_id = "sa-taxi-scheduler" }
resource "google_service_account" "dataform"   { account_id = "sa-taxi-dataform" }
```

Four **least-privilege** identities, each granted only what it needs:
- `sa-taxi-ingest` → write the raw bucket, edit bronze, run BQ jobs.
- `sa-taxi-workflow` → run the two jobs, read the state file, write logs.
- `sa-taxi-scheduler` → start workflow executions (nothing else).
- `sa-taxi-dataform` → read bronze, write silver+gold, run BQ jobs.

This is the "call it out in docs" gotcha from the plan: the
Scheduler→Workflow→Run chain needs **explicit invoker grants** at each hop —
the AWS habit of assuming an ambient role bites you here.

**3. `google-beta` is a real, separate provider.** Some resources (Dataform)
only exist in the beta provider, so `providers.tf` declares both.

### State, and why `.tfvars.example` not `.tfvars`

`backend.tf` keeps Terraform **state** in a GCS bucket, not on your laptop — so
the deployment has one source of truth and can be run/repaired from anywhere.

`terraform/terraform.tfvars.example` is committed; the real `terraform.tfvars`
(with your actual project id, billing values) is **git-ignored**. Terraform
auto-loads `terraform.tfvars` for variable values — the `.example` documents the
shape without leaking real values into a public repo. (This is also why
`*.tfplan` and `*.tfstate` are git-ignored: a plan file and state can contain
resource details you don't want public.)

Auth is via **ADC** (`gcloud auth application-default login`) — Terraform runs as
*you* locally. The first `terraform apply` is the moment real cloud resources
(and spend) get created, which is why it's an explicit approval gate.

---

## Lesson 3 — The ingest job

`ingest/main.py` is a small Python program that runs as a **Cloud Run Job**
(run-to-completion container, ~2 min/day). Its entire responsibility is the
**bronze layer**: get one month of raw data in, faithfully. It does *not* clean
or enrich — that's Dataform's job.

### The six responsibilities (from the module docstring)

1. Load the taxi-zone lookup as a **versioned** native bronze table (hash-based).
2. **Resolve which month to load.**
3. Download that month's parquet from the public CloudFront URL → GCS.
4. Free BigQuery **batch-load** it into a landing table (schema autodetected).
5. Atomically **replace that month's partition** in the unified bronze table.
6. Write a small **state file** so the orchestrator knows if a new month landed.

### Idea A — idempotent partition replace

The core of correctness. `build_partition_replace_sql()` emits a single BigQuery
**transaction**:

```sql
BEGIN TRANSACTION;
DELETE FROM `…yellow_trips` WHERE `_source_month` = @source_month;
INSERT INTO `…yellow_trips` (…) SELECT … FROM `…yellow_trips_landing`;
COMMIT TRANSACTION;
```

Bronze is partitioned by `_source_month` (one partition per source file). A
re-run DELETE+INSERTs *only that one month's partition*, inside one transaction —
so there are never duplicates and never a half-written month. **Run any month
twice → identical result.** This is idempotency at the bronze layer (silver gets
its own version of this via Dataform's MERGE in Lesson 5).

### Idea B — schema-drift tolerance + name conforming

NYC TLC files are inconsistent across years: CamelCase names (`VendorID`,
`PULocationID`), a `tpep_` prefix on the timestamps, a capital-A `Airport_fee`,
and columns that simply don't exist in older files (`airport_fee`,
`congestion_surcharge`). Loading them into one uniform table means the ingest
has to *conform names and tolerate missing columns dynamically*.

The trick is name-normalization. `_norm(name) = name.lower().replace("_", "")`
collapses `VendorID`, `vendor_id`, and `VENDOR_ID` to the same key. So for each
canonical snake_case bronze column, the ingest:

```python
if a matching source column exists (by normalized name, or a known alias):
    SAFE_CAST(`SourceName` AS TYPE) AS `snake_name`
else:
    CAST(NULL AS TYPE) AS `snake_name`      # column absent in old files
```

`SOURCE_ALIASES` handles the two that don't reduce cleanly
(`tpep_pickup_datetime` → `pickup_datetime`). `SAFE_CAST` absorbs INT↔FLOAT
drift. The result: **every year's file lands in the same clean snake_case
schema**, and a missing column becomes a typed `NULL` instead of a crash.

### Idea C — the versioned zone lookup (hash-based)

`load_zone_lookup()` treats the tiny reference CSV as **versioned reference
data**. It downloads the CSV, `md5`-hashes it, compares to the latest
`_content_hash` already stored, and **appends a new snapshot only when the
content actually changed**. So the table holds one row-set per *real* change —
full version history at near-zero cost — instead of a new copy every daily run.
(This replaced an earlier external-table design; making it a native table means
the transforms read BigQuery only, no GCS access needed downstream.)

### Idea D — the self-healing month resolver

`resolve_target_month()` decides what to load:

- If `TARGET_MONTH` is set (backfill) → load exactly that month.
- Otherwise → load the **oldest published month not yet in bronze**.

The oldest-first choice is deliberate and makes the daily job **self-healing**:

```python
for d in iter_months_asc(oldest, newest):        # walk forward from start_month
    if month_str(d) in loaded_months(...):        # one cheap DISTINCT query
        continue
    if http_exists(source_url(...)):              # HEAD probe (skip unpublished)
        return month_str(d)                        # first gap that's published
```

If the source goes quiet for months and then dumps several at once, successive
daily runs fill the gap **one month per day** — and a month the source *never*
publishes is simply skipped (a HEAD 404), never blocking newer months. A
newest-first design would have loaded the latest and left a permanent hole.

### Idea E — the state file (the baton)

At the end, `write_state()` writes `_state/last_ingest.json` to GCS:
`{"status": "loaded"|"skipped", "month": "...", "rows": N}`. The orchestrator
reads this to decide whether to run the (expensive) transforms. This is how the
Python world hands off to the SQL world — covered in Lesson 6.

> **Why a Cloud Run Job, not a Cloud Function or Dataflow?** The task is
> "download a 50 MB file and kick off a load." A Function has short timeouts and
> smaller limits; Dataflow/Dataproc spin up worker VMs you pay for. A Cloud Run
> *Job* is built for run-to-completion batch work, billed only for the seconds it
> runs (~2 min/day → inside the free tier).

---

## Lesson 4 — The data model: medallion → star

Two design patterns are stacked here, and the key insight is that they solve
*different* problems:

- **Medallion (bronze → silver → gold)** — a *maturity* pattern. Each layer is
  more trustworthy than the last.
- **Kimball star (fact + dimensions)** — a *modeling* pattern that lives **inside**
  gold. It's about how a BI tool and an analyst think.

### The medallion layers

| Layer | Dataset | The one promise | AWS analogy |
|---|---|---|---|
| **Bronze** | `taxi_bronze` | *"This is faithfully what the source gave us."* | S3 raw + Glue table |
| **Silver** | `taxi_silver` | *"Every row here is valid, typed, and self-describing."* | cleaned/conformed Glue table |
| **Gold** | `taxi_gold` | *"This is the business model — integrated and ready to query."* | curated marts / Redshift |

**Bronze — faithful copy.** `bronze.yellow_trips` is the source unchanged in
*meaning* — only names conformed to snake_case at load. No rows dropped, no math.
Bronze is your **replay buffer**: discover a cleaning bug next year and you
re-derive silver from bronze without re-downloading 5 years of parquet.

**Silver — valid, typed, self-derived.** Two rules define `stg_trips`:

1. *Every row is valid.* The final `WHERE` drops the garbage NYC TLC is famous
   for — nulls, `dropoff <= pickup`, sub-minute meter glitches, >12h durations,
   negative money, and stray out-of-month rows (the files literally contain 2008
   timestamps). **The dirt is filtered once, here** — no downstream query needs
   guards again.
2. *Self-derived only, NO cross-table joins.* Every derived column comes from the
   same row: `trip_minutes`, `mph`, `pickup_hour`, `driver_revenue`,
   `earnings_per_hour`, `tip_pct`, `is_card`. It keeps `pu_location_id` /
   `do_location_id` as **foreign keys** — it does *not* join the zone table.
   That join is gold's job.

> **Why the strict no-join rule?** It keeps each source independently
> reprocessable and the layer boundaries clean. If silver joined zones, a change
> to the zone table would force a silver rebuild — entangling two things that
> should move independently.

The single most important line in silver:
`driver_revenue = fare_amount + tip_amount`. Taxes, tolls, and surcharges pass
*through* the driver; the money they keep is meter fare + tip. Every earnings
number in the project descends from this one definition.

**Gold — the integrated business model.** Where joins finally happen, and where
the star schema lives.

### The Kimball star (inside gold)

A star splits the world into two kinds of tables:

- **A fact** — the *events*, at one grain, mostly **numbers + foreign keys**.
  Big, tall, append-heavy.
- **Dimensions** — the *descriptive context* you slice by. Small, wide, textual.

```
                 dim_date
                    │
   dim_vendor ──┐   │   ┌── dim_payment_type
                └── fact_trip ──┘
   dim_rate_code ──┘   │   └── dim_zone  (joined twice: pickup + dropoff)
```

**The fact: `fact_trip`.** Its **grain** is *one row per completed ride* — the
single most important fact about any fact table. It holds three kinds of columns:

1. **Foreign keys** — `pu_location_id`, `do_location_id`, `vendor_id`,
   `rate_code_id`, `payment_type`, `pickup_date`.
2. **Measures** (the numbers you aggregate) — `driver_revenue`,
   `earnings_per_hour`, `tip_pct`, `trip_minutes`, `mph`, `fare_amount …
   total_amount`.
3. **Degenerate dimensions** — `pickup_hour`, `pickup_dow`, `is_weekend`. Too
   tiny to deserve their own table, so they live on the fact.

The *only* join `fact_trip` does is to `dim_zone`, to resolve airport flags —
the medallion boundary in action (silver refused; gold's first act is exactly
that join). It's **materialized** (not a view) because BI plugs into it: compute
once per new month, read cheaply forever.

**The dimensions** turn skinny codes into human labels:

| Dim | Key | What it adds |
|---|---|---|
| `dim_zone` | `location_id` | borough, zone, service_zone, is_airport, airport_name |
| `dim_date` | `date_key` | year, quarter, month_name, day_name, is_weekend |
| `dim_payment_type` | `payment_type` | payment_method (1→"Credit card"…) |
| `dim_rate_code` | `rate_code_id` | rate_code_desc (1→"Standard", 2→"JFK"…) |
| `dim_vendor` | `vendor_id` | vendor_name |

The fact stores `payment_type = 1`; the dim turns it into "Credit card." Change
the label once in the dim → every chart updates, the fact never moves.

**Why a star, not one big flat table?** Cheaper scans (columnar BQ stores tiny
integer FKs, not repeated strings across millions of rows), a single source of
truth for labels, and it's the **native shape for BI tools** (drag-and-drop
slicing for free).

**The marts** (7 of them) are pre-aggregated answers on top of `fact_trip` +
dims. The fact is the flexible star; the marts are the fast canned answers.

### The mental model

```
bronze  = "what the source said"     (faithful, replayable)
silver  = "one clean, typed row"     (valid, self-derived, NO joins)
gold    = "the business model"       (star: fact + dims, joins live here)
  ├─ fact_trip = events (numbers + FKs), the BI plug
  ├─ dim_*     = the labels you slice by
  └─ marts     = pre-computed answers
```

The discipline that makes it work: **each layer refuses to do the next layer's
job.** Bronze doesn't clean, silver doesn't join, gold doesn't re-clean.

---

## Lesson 5 — Dataform: how `.sqlx` files become a pipeline

**Dataform ≈ dbt.** It takes a folder of SQL files and turns them into an
ordered, incremental, tested pipeline — with no server (it's SQL compiled and run
*inside* BigQuery). Six ideas make it work.

### Idea 1 — `ref()` builds the DAG for you

You never write "run silver before gold." Each table *references* its inputs:

```sql
FROM ${ref("stg_trips")}          -- fact_trip depends on stg_trips
LEFT JOIN ${ref("dim_zone")} ...  -- ...and on dim_zone
```

Dataform reads every file, sees who `ref()`s whom, and **infers the dependency
graph**, then topologically sorts it:

```
yellow_trips (declaration) ─► stg_trips ─► fact_trip ─► zone_hour_earnings
zone_lookup  (declaration) ─► stg_zone  ─► dim_zone ──┘         (+ 6 more marts)
                                        └► fact_trip
```

`ref()` also writes the **fully-qualified name** — `${ref("stg_trips")}` →
`` `project.taxi_silver.stg_trips` `` — so you never hardcode project/dataset,
which is why the same code runs in any project.

The chain *starts* at a **declaration** (`bronze_yellow_trips.sqlx`,
`type: "declaration"`): not a table Dataform builds, just a registration that
"this table already exists (the ingest made it)" so `ref()` works. Declarations
are the handshake between the Python ingest world and the SQL transform world.

### Idea 2 — `type:` decides what SQL gets generated

| `type` | Example | What Dataform runs |
|---|---|---|
| `declaration` | `bronze_yellow_trips` | *nothing* — registers an existing table |
| `table` | `dim_zone`, all 7 marts | `CREATE OR REPLACE TABLE … AS (SELECT)` — full rebuild |
| `incremental` | `stg_trips`, `fact_trip` | `MERGE` new rows into existing table |

**Small things rebuild; big things merge.** `dim_zone` has ~265 rows → rebuild is
free → `type: "table"`. `fact_trip` has millions/month → never rebuild history →
`incremental`. The marts are `table` too — `HAVING trips >= 30` collapses
millions of rides into a few thousand rows, so a full rebuild is cheapest.

### Idea 3 — `incremental` + `uniqueKey`: the idempotent MERGE

```js
type: "incremental",
uniqueKey: ["trip_sk"],
```

and inside the query:

```sql
${when(incremental(),
  `AND _loaded_at > (SELECT COALESCE(MAX(_bronze_loaded_at), TIMESTAMP '1970-01-01') FROM ${self()})`
)}
```

- **First run** (table absent): `incremental()` is false → full `CREATE TABLE`.
- **Every run after**: a `MERGE` on `trip_sk` — matched rows update, unmatched
  insert. Run a month twice → same result. **Idempotent** (the SQL twin of
  bronze's DELETE+INSERT).

The `when(incremental(), …)` line is a **high-water mark**: only pull bronze rows
newer than the newest already processed. And `trip_sk` being a *true* unique key
is why `stg_trips` ends with a `ROW_NUMBER()` trick — two genuinely-identical
rides would collide on the fingerprint, so it appends `_1`, `_2` (else the MERGE
throws "matched more than one source row").

### Idea 4 — `includes/` = shared code + partition pruning

The `${…}` bits in `.sqlx` are **JavaScript**; anything in `includes/` is
importable by filename. `constants.js`:

```js
const TARGET_MONTH = dataform.projectConfig.vars.target_month || "";

function sourceMonthFilter() {
  return TARGET_MONTH ? `_source_month = DATE '${TARGET_MONTH}-01'` : `TRUE`;
}
```

The transform job runs `dataform run --vars target_month=2023-02`, and that value
flows into every `${constants.sourceMonthFilter()}`. Two payoffs:

1. **Partition pruning on read** — `WHERE _source_month = DATE '2023-02-01'` scans
   *one* partition, not five years. The difference between $0 and a blown free tier.
2. **`updatePartitionFilter()`** — bounds the *write* side of the MERGE to just
   the affected partitions.

Empty `target_month` (`""`) → both helpers return `TRUE` → process everything.
**That's the backfill switch** — the same code does daily-one-month *and*
full-history-rebuild depending on one variable.

> **Scar tissue:** `updatePartitionFilter` must start with the partition column
> and mention it once, using `BETWEEN … LAST_DAY(…)`. Dataform prepends a table
> alias to only the first token of the predicate, so a two-bound
> `pickup_date >= … AND pickup_date < …` broke with "column is ambiguous." The
> comment in the file exists so nobody re-breaks it.

### Idea 5 — `assertions`: tests are part of the graph

```js
assertions: {
  uniqueKey: ["trip_sk"],
  rowConditions: [
    "trip_minutes >= 1 AND trip_minutes <= 720",
    "fare_amount >= 0",
    "driver_revenue >= 0"
  ]
}
```

Dataform compiles each assertion into a query that **selects violating rows**. If
any come back, the assertion fails and the run stops. Because assertions are
nodes in the same DAG, they run in order — silver's assertions gate gold. Your
data-quality wall is *inside* the pipeline, not a separate job you hope runs.

### Idea 6 — how it actually runs (the containerized twist)

Managed Dataform-from-Git requires the project at a **git repo root**, but here
`dataform/` is a subdirectory. So instead: the folder is baked into a
**container** (its `Dockerfile` runs `dataform compile` then `dataform run
--vars target_month=…`), and that container is the **`taxi-transform` Cloud Run
job**, run as `sa-taxi-dataform`. `workflow_settings.yaml` has a placeholder
`defaultProject`; the real project is injected at runtime — which is exactly why
`ref()` never hardcoding names matters.

End to end: **Scheduler → Workflow → (ingest lands a month) → Workflow →
(transform runs `dataform run`) → BigQuery MERGEs silver + rebuilds gold + runs
assertions.**

---

## Lesson 6 — Orchestration (Cloud Workflows + Cloud Scheduler)

Two tiny serverless pieces drive the whole thing daily, for effectively $0.

- **Cloud Scheduler** = GCP's cron (≈ EventBridge Scheduler). First 3 jobs free.
- **Cloud Workflows** = GCP's serverless state machine (≈ Step Functions).

### The trigger: `scheduler.tf`

```hcl
resource "google_cloud_scheduler_job" "daily" {
  name      = "taxi-daily"
  schedule  = var.daily_schedule       # cron, in New York time
  time_zone = var.scheduler_timezone
  http_target {
    http_method = "POST"
    uri  = ".../workflows/${…}/executions"   # start a Workflow execution
    body = base64encode(jsonencode({}))       # empty => resolve latest month
    oauth_token { service_account_email = google_service_account.scheduler.email }
  }
}
```

Once a day it POSTs to the Workflows Executions API, authenticating with an OAuth
token minted for `sa-taxi-scheduler` (which holds *only* `workflows.invoker`).
An **empty body** tells the pipeline "figure out the latest un-loaded month"; to
force a specific month you POST `{"target_month":"2023-02"}`.

### The state machine: `workflows/pipeline.yaml`

The workflow is four logical steps:

```
1. run_ingest    → run the ingest Cloud Run job (wait for it)
2. read_state    → GET gs://…/_state/last_ingest.json (the baton from Lesson 3)
3. decide        → switch on state.status
4. run_transform → ONLY if status == "loaded", run the transform job for that month
```

The **gating** in step 3 is the cost lever:

```yaml
- decide:
    switch:
      - condition: ${state_resp.body.status == "loaded"}
        next: run_transform
    next: done_skip
```

A new month appears ~once a month, so **~29 of 30 daily runs are no-ops**: ingest
resolves "nothing new," writes `status: "skipped"`, and the expensive SQL
transforms never run. Only when a genuinely new month lands does the transform
fire — and it's handed exactly that month via `TARGET_MONTH`:

```yaml
- run_transform:
    ...
    containerOverrides:
      - env:
          - name: TARGET_MONTH
            value: ${state_resp.body.month}   # e.g. "2023-02"
```

That's the same `target_month` variable that drives Dataform's partition pruning
(Lesson 5) — so the transform touches only the new month's partition.

### The IAM subtlety worth remembering

Both job-run steps use **container overrides** (`TARGET_MONTH`), which is the
`run.jobs.runWithOverrides` permission. Plain `roles/run.invoker` does **not**
include it — so `iam.tf` grants the workflow SA `roles/run.developer` on each
job. This was a real deploy-time failure ("permission denied") until the role was
bumped. The chain of explicit grants:

```
scheduler SA (workflows.invoker)
   └─► workflow SA (run.developer on both jobs + storage.objectViewer for state)
          └─► ingest/transform jobs run as their own runtime SAs
```

No ambient roles — every hop is granted by hand. That's the AWS→GCP tax, made
explicit and least-privilege.

> **Why Workflows, not Composer/Airflow?** A Composer environment carries a
> standing GKE + Cloud SQL footprint costing **~$300–500+/month even when idle** —
> over 100× this whole pipeline's bill. The DAG here (ingest → maybe-transform) is
> simple; Workflows is serverless and effectively free at this volume.

---

## Lesson 7 — Data quality

Correctness is enforced at **two levels**, in-band and out-of-band.

### Level 1 — Dataform assertions (in-band, gate every run)

Covered in Lesson 5: `assertions` on `stg_trips` (unique key, non-null,
row-conditions like `trip_minutes BETWEEN 1 AND 720`, `driver_revenue >= 0`),
plus a `gold_sanity` assertion file. These compile to "select the violating
rows"; any violation **stops the run** before bad data reaches gold. Because
they're DAG nodes, silver's assertions gate gold automatically. This is your
*continuous* guardrail — it runs on every transform.

### Level 2 — cross-layer reconciliation (out-of-band, `tests/data_quality_checks.py`)

Assertions check a table against *rules*; reconciliation checks tables against
*each other* and against **source truth**. This suite runs against live BigQuery
(ADC auth, `PROJECT_ID=<proj> python tests/data_quality_checks.py`, non-zero exit
on failure — CI-friendly). The ten checks, and what each *proves*:

| Check | Proves |
|---|---|
| bronze: partition key never null; 1 source file per month | ingest wrote clean partitions |
| bronze 2023-01 count == **3,066,766** | matches TLC's published source truth exactly |
| **bronze valid-rows == stg_trips rows, per month** | silver dropped *exactly* the invalid rows — no over/under-filtering |
| stg_trips: unique key, no null keys, `driver_revenue == fare+tip`, in-range | silver's derived columns are arithmetically correct |
| **fact_trip count == stg_trips count** | the gold LEFT JOINs preserved grain (didn't fan out or drop rows) |
| fact_trip: every pickup zone resolved in dim_zone | no unmatched foreign keys |
| mart `tipping_by_payment` SUM(trips) == fact_trip count | the mart aggregates every ride, none lost |
| mart `hourly_pulse` SUM(trips) == fact rows (same mph filter) | filter parity between mart and fact |
| mart `airport_economics` JFK median ≈ recomputed from fact (±0.5) | approx-quantile mart matches a direct recompute |
| mart `zone_hour_earnings` honors `trips >= 30` suppression | small-cell privacy/robustness rule holds |

The two bolded checks are the heart of it: they form a **row-count chain of
custody** — *source truth → bronze → silver → fact → marts* — where each layer's
count is provably derived from the one before. If any layer silently drops or
duplicates rows, exactly one link breaks and names itself.

Two levels, two jobs: **assertions catch bad rows continuously; reconciliation
catches broken *relationships* between layers on demand.**

---

## Lesson 8 — Cost model

**Bottom line: ≈ $0–2/month** for 5 years of data with daily runs. Almost
everything fits GCP's Always-Free tier; the only non-zero item is a sliver of
BigQuery storage (and even that → ~$0 with compressed-storage billing).

### The numbers (2026, us-central1)

| Service | Basis | Monthly |
|---|---|---|
| BigQuery **query** | new-month transform scans ~1 partition (~0.2 GB); monthly gold rebuild scans silver (~0.03 TiB). ≪ 1 TiB free | **$0.00** |
| BigQuery **storage** | ~60 GB logical − 10 GB free, mostly long-term | **~$0.50–1.00** (logical) / **~$0** (physical) |
| GCS Standard | ~3 GB of parquet @ $0.020/GB | **~$0.06** |
| Cloud Run Jobs | ~30 runs × ~120 s × 1 vCPU — under free tier | **$0.00** |
| Cloud Workflows | ~30 runs × ~20 steps ≪ 5,000 free | **$0.00** |
| Cloud Scheduler | 1 job (3 free) | **$0.00** |

> **AWS note:** the old "$5/TB" BigQuery number is stale — on-demand is now
> **$6.25 per *TiB*** (binary). Batch loads from GCS are **free**; **never** use
> streaming inserts (they bill per byte). Even the one-time 5-year backfill is
> effectively free: loads cost $0 and scanning ~30 GB a few times is a rounding
> error against the 1 TiB/month query allowance.

### The six design choices that keep it near zero

These aren't accidents — every one is a deliberate lever you've seen in earlier
lessons:

1. **Load, don't stream** — batch loads from GCS are free (Lesson 3).
2. **Transform in BigQuery** — no Dataflow/Dataproc/Composer VMs (Lessons 5–6).
3. **Partition + cluster** — silver/gold read only the new month's partitions
   (Lesson 5's `sourceMonthFilter`).
4. **Gate the transforms** — SQL runs only when a new month lands, not daily
   (Lesson 6's `decide` step; ~29/30 runs are no-ops).
5. **Single region** — co-located GCS + BQ ⇒ free loads, no egress.
6. **`require_partition_filter` guard** — an accidental full-table `SELECT *`
   *can't* silently scan (and bill) 5 years at once.

The theme: **cost-optimization here is an architectural property, not a
line-item you trim afterward.** The medallion + gating + partitioning design
*is* the cost control.

---

## Lesson 9 — Visualizing the results (local notebook)

The last mile: turning the star into the driver-earnings story. Instead of a
hosted BI tool, this project uses a **local Python notebook** —
[`analysis/driver_earnings_analysis.ipynb`](../analysis/driver_earnings_analysis.ipynb).
It queries `taxi_gold` over Application Default Credentials and renders every
finding as a matplotlib chart. Nothing to host, nothing to authorize, and the
charts live in the repo next to the SQL.

### Why a notebook (and not a hosted dashboard)?

- **Zero extra infra / cost** — it runs on your machine against the same free-tier
  BigQuery; there's no dashboard service to stand up or authorize.
- **Reproducible + reviewable** — the queries and the plotting code are versioned
  in one file; a reviewer re-runs it and gets identical charts.
- **The gold layer already did the work** — the 7 marts are the pre-aggregated
  answers, so each chart is a tiny query plus a few lines of matplotlib.

### How it maps to the findings

| Notebook section | Mart(s) it reads | The chart / story |
|---|---|---|
| Tipping | `tipping_by_payment`, `top_tip_zones` | bar of tip % by payment method (cash ≈ 0); top card-tip zones |
| Rush-hour paradox | `hourly_pulse` | combo chart: peak *demand* ≠ peak *pay* as speed collapses |
| When to drive | `fact_trip` (ad-hoc) | heatmap of median $/hour by hour × day-of-week |
| Airport economics | `airport_economics` | JFK/LGA vs non-airport, per-trip and per-hour |
| Trip length | `trip_length_economics` | the $/hour U-curve — avoid the 2–5 mi band |
| The playbook | `best_slots` | top (zone × hour) slots table |

### Two honest notes that show engineering maturity

- **Cash-tip trap:** `payment_type = 2` (cash) records `tip_amount ≈ 0` because
  cash tips are never entered into the meter. So all tip analysis is **card-only**
  — surfaced explicitly rather than reporting a false "cash riders don't tip."
- **No filled-map yet:** a choropleth of pickup zones needs the TLC zone
  *geometry* (a shapefile) joined to `location_id` — not in this pipeline. The
  documented next step is a `dim_taxi_zone` with geometry to unlock maps.

That closes the loop: **source → bronze → silver → gold star → a decision a real
driver could act on.**

---

## Where to go next

- **Run the full history:** the pipeline is validated on a single month
  (2023-01). The held step is the 9-month backfill + full rebuild + re-run of the
  reconciliation suite (`scripts/backfill.sh` loops `TARGET_MONTH`).
- **Resume the schedule:** `taxi-daily` is paused during evaluation; resume it
  before production. (Once resumed with only one month loaded, the self-healing
  resolver will walk forward and backfill on its own, one month per day.)
- **Add geometry:** `dim_taxi_zone` with shapefile geometry → choropleth maps.
```

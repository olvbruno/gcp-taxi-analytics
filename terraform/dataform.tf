# Transforms run via the containerized `dataform run` Cloud Run job
# (google_cloud_run_v2_job.transform in cloudrun.tf), NOT a managed Dataform
# repository. This keeps the Dataform project in the monorepo (dataform/) as the
# single source of truth and avoids the managed-Dataform constraint that the
# project must sit at the git repo root.
#
# The execution identity (sa-taxi-dataform) and its BigQuery grants live in
# iam.tf; the job image is built by scripts/build_push.sh.

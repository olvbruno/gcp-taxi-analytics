# Remote state in GCS. The bucket must exist BEFORE `terraform init`
# (created by scripts/bootstrap.sh — chicken-and-egg: Terraform can't create
# the bucket that holds its own state).
#
# This is a PARTIAL backend config: pass the bucket at init time so the value
# is not hard-coded per-environment:
#
#   terraform init -backend-config="bucket=<PROJECT_ID>-tfstate" \
#                  -backend-config="prefix=taxi/state"
#
terraform {
  backend "gcs" {}
}

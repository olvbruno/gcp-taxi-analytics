#!/usr/bin/env bash
# One-time GCP bootstrap: project, billing, minimal APIs, and the Terraform
# state bucket. Run this ONCE before `terraform init`. Requires the gcloud CLI
# and an authenticated user (`gcloud auth login`).
#
# Edit the three variables, then: bash scripts/bootstrap.sh
set -euo pipefail

# ---- EDIT THESE ----
PROJECT_ID="my-taxi-analytics-project"      # must be globally unique
BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"      # gcloud billing accounts list
REGION="us-central1"
# --------------------

STATE_BUCKET="${PROJECT_ID}-tfstate"

echo ">> Creating project ${PROJECT_ID} (ok if it already exists)"
gcloud projects create "${PROJECT_ID}" 2>/dev/null || true

echo ">> Linking billing account"
gcloud billing projects link "${PROJECT_ID}" --billing-account "${BILLING_ACCOUNT}"

echo ">> Setting active project"
gcloud config set project "${PROJECT_ID}"

echo ">> Enabling the minimal APIs Terraform needs to start"
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  --project "${PROJECT_ID}"
# (Terraform enables the rest — BigQuery, Run, Workflows, Scheduler, Dataform,
#  Artifact Registry, Cloud Build — via google_project_service.)

echo ">> Creating Terraform state bucket gs://${STATE_BUCKET}"
gcloud storage buckets create "gs://${STATE_BUCKET}" \
  --project "${PROJECT_ID}" --location "${REGION}" \
  --uniform-bucket-level-access 2>/dev/null || true
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning

echo ">> Setting up Application Default Credentials for Terraform"
echo "   (a browser window will open)"
gcloud auth application-default login

cat <<EOF

Bootstrap complete.

Next:
  cd terraform
  cp terraform.tfvars.example terraform.tfvars      # set project_id / region
  terraform init -backend-config="bucket=${STATE_BUCKET}" -backend-config="prefix=taxi/state"
  # build+push the ingest image first (job apply needs it):
  bash ../scripts/build_push.sh ${PROJECT_ID} ${REGION}
  terraform apply
EOF

#!/usr/bin/env bash
# Build + push BOTH container images (ingest + transform) with Cloud Build
# (no local Docker needed). Run AFTER the Artifact Registry repo exists — either
# apply just the repo first:
#   terraform apply -target=google_artifact_registry_repository.taxi
# ...or run this after a full apply to push new image versions.
#
# Usage: bash scripts/build_push.sh <PROJECT_ID> [REGION] [TAG]
set -euo pipefail

PROJECT_ID="${1:?usage: build_push.sh <PROJECT_ID> [REGION] [TAG]}"
REGION="${2:-us-central1}"
TAG="${3:-latest}"
REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/taxi"

echo ">> Building + pushing ingest image"
gcloud builds submit ingest --tag "${REPO}/ingest:${TAG}" --project "${PROJECT_ID}"

echo ">> Building + pushing transform image (bundled Dataform project)"
gcloud builds submit dataform --tag "${REPO}/transform:${TAG}" --project "${PROJECT_ID}"

echo ">> Done: ${REPO}/ingest:${TAG} and ${REPO}/transform:${TAG}"

#!/usr/bin/env bash
# Backfill a range of months by driving the SAME orchestrator used in prod —
# one workflow execution per month (ingest that month, then transform it).
# Idempotent: re-running a month replaces its partition.
#
# Usage: bash scripts/backfill.sh <PROJECT_ID> <REGION> <START_YYYY-MM> <END_YYYY-MM>
# Example (5 years): bash scripts/backfill.sh my-proj us-central1 2019-01 2023-12
set -euo pipefail

PROJECT_ID="${1:?}"; REGION="${2:?}"; START="${3:?}"; END="${4:?}"
WORKFLOW="taxi-pipeline"

y=${START%-*}; m=${START#*-}
ey=${END%-*}; em=${END#*-}

while [ "$((10#$y * 12 + 10#$m))" -le "$((10#$ey * 12 + 10#$em))" ]; do
  MONTH=$(printf "%04d-%02d" "$((10#$y))" "$((10#$m))")
  echo ">> Backfilling ${MONTH}"
  gcloud workflows run "${WORKFLOW}" \
    --location "${REGION}" --project "${PROJECT_ID}" \
    --data "{\"target_month\":\"${MONTH}\"}"
  m=$((10#$m + 1))
  if [ "$m" -gt 12 ]; then m=1; y=$((10#$y + 1)); fi
done

echo ">> Backfill complete: ${START} .. ${END}"

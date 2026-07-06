#!/bin/sh
# Entrypoint for the Dataform transform Cloud Run job.
# Runs the compiled bronze->silver->gold transforms (+ assertions) against
# BigQuery, authenticating via the attached service account (ADC / metadata).
set -e
: "${PROJECT_ID:?PROJECT_ID required}"
: "${REGION:?REGION required}"

# Point the project/location at the runtime env (workflow_settings.yaml ships a
# placeholder so the repo stays project-agnostic).
sed -i "s/^defaultProject:.*/defaultProject: ${PROJECT_ID}/" /dataform/workflow_settings.yaml
sed -i "s/^defaultLocation:.*/defaultLocation: ${REGION}/" /dataform/workflow_settings.yaml

# Connection config: no embedded key => the CLI uses Application Default
# Credentials, which on Cloud Run is the attached service account.
cat > /dataform/.df-credentials.json <<EOF
{"projectId":"${PROJECT_ID}","location":"${REGION}"}
EOF

cd /dataform
echo "dataform run for target_month='${TARGET_MONTH:-<all>}'"
exec dataform run --vars=target_month="${TARGET_MONTH}"

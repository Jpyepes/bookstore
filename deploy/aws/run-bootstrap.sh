#!/bin/bash
# One-shot RDS bootstrap, executed on an application EC2 instance through
# SSM Run Command (AWS-RunShellScript). Runs database/rds/bootstrap.sh inside a
# postgres:17 container, the same way the "bootstrap" service does in compose.yaml.
#
# Safe to re-run: the bootstrap scripts are idempotent.

set -euo pipefail

REGION=us-east-1
SECRET_ID=bookstore/prod
REPO_URL=https://github.com/Jpyepes/bookstore.git
WORK_DIR=/tmp/bookstore-bootstrap

dnf install -y git jq >/dev/null

SECRET_JSON=$(aws secretsmanager get-secret-value --region "${REGION}" \
    --secret-id "${SECRET_ID}" --query SecretString --output text)

secret() {
    jq -er --arg key "$1" '.[$key]' <<<"${SECRET_JSON}"
}

rm -rf "${WORK_DIR}"
git clone --depth 1 "${REPO_URL}" "${WORK_DIR}"

docker run --rm \
    -e DB_HOST=bookstore-rds-prod.crcs4mw4ubpn.us-east-1.rds.amazonaws.com \
    -e DB_PORT=5432 \
    -e DB_NAME=bookstore \
    -e DB_ADMIN_USER=bookstore_admin \
    -e DB_ADMIN_PASSWORD="$(secret DB_ADMIN_PASSWORD)" \
    -e APP_DB_USER=bookstore_app \
    -e APP_DB_PASSWORD="$(secret APP_DB_PASSWORD)" \
    -e INGEST_DB_USER=bookstore_ingest \
    -e INGEST_DB_PASSWORD="$(secret INGEST_DB_PASSWORD)" \
    -e PGSSLMODE=require \
    -v "${WORK_DIR}/database:/database:ro" \
    -w /database/rds \
    --entrypoint /bin/bash \
    postgres:17 ./bootstrap.sh

rm -rf "${WORK_DIR}"

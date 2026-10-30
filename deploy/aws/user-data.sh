#!/bin/bash
# EC2 user data (Amazon Linux 2023) for the BookStore Auto Scaling Group.
#
# Runs both containers on each instance:
#   frontend (Nginx + compiled SPA) on :80   <- ALB default rule
#   backend  (Node.js API)          on :5001 <- ALB rule /api/*
#
# Secrets are read at boot from AWS Secrets Manager (JSON secret) using the
# instance profile (LabInstanceProfile); none are stored in the launch template.

set -euo pipefail
exec > >(tee -a /var/log/bookstore-user-data.log) 2>&1

REGION=us-east-1
REGISTRY=975050271329.dkr.ecr.us-east-1.amazonaws.com
BACKEND_IMAGE=${REGISTRY}/bookstore/repo-app:8.2.0
FRONTEND_IMAGE=${REGISTRY}/bookstore/repo-frontend:8.1.0
SECRET_ID=bookstore/prod

DB_HOST=bookstore-rds-prod.crcs4mw4ubpn.us-east-1.rds.amazonaws.com
PUBLIC_ORIGIN=http://alb-bookstore-215289595.us-east-1.elb.amazonaws.com
ORDER_EVENTS_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/975050271329/bookstore-order-placed

# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------

dnf install -y docker jq
systemctl enable --now docker

# ------------------------------------------------------------
# Secrets
# ------------------------------------------------------------

SECRET_JSON=$(aws secretsmanager get-secret-value --region "${REGION}" \
    --secret-id "${SECRET_ID}" --query SecretString --output text)

secret() {
    jq -er --arg key "$1" '.[$key]' <<<"${SECRET_JSON}"
}

APP_DB_PASSWORD=$(secret APP_DB_PASSWORD)
AUTH_JWT_SECRET=$(secret AUTH_JWT_SECRET)
unset SECRET_JSON

# ------------------------------------------------------------
# Backend runtime configuration (values from .env.aws.example)
# ------------------------------------------------------------

install -d -m 0700 /etc/bookstore
umask 077
cat > /etc/bookstore/backend.env <<EOF
NODE_ENV=production
SERVICE_NAME=bookstore-api
PORT=5001
API_BASE_PATH=/api
CORS_ORIGINS=${PUBLIC_ORIGIN}
BOOKS_DEFAULT_LIMIT=24
BOOKS_MAX_LIMIT=100
ORDERS_MAX_DISTINCT_ITEMS=100
ORDERS_MAX_QUANTITY_PER_ITEM=1000
HTTP_TRUST_PROXY_HOPS=1
HTTP_JSON_BODY_LIMIT=32kb
ACCESS_LOG_ENABLED=true
ACCESS_LOG_EXCLUDE_PATHS=/health
ACCESS_LOG_MAX_FIELD_LENGTH=2048
ACCESS_LOG_REQUEST_ID_HEADER=X-Request-Id
CLICKSTREAM_FILE_ENABLED=true
CLICKSTREAM_FILE_PATH=/usr/src/app/logs/clickstream.log
AUTH_JWT_SECRET=${AUTH_JWT_SECRET}
AUTH_JWT_ALGORITHM=HS256
AUTH_JWT_ISSUER=bookstore-api
AUTH_JWT_AUDIENCE=bookstore-web
AUTH_TOKEN_TTL_SECONDS=28800
AUTH_COOKIE_NAME=bookstore_session
AUTH_COOKIE_SECURE=false
AUTH_COOKIE_SAME_SITE=lax
AUTH_COOKIE_PATH=/api
DB_HOST=${DB_HOST}
DB_PORT=5432
DB_NAME=bookstore
DB_USER=bookstore_app
DB_PASSWORD=${APP_DB_PASSWORD}
DB_SSL=true
DB_SSL_REJECT_UNAUTHORIZED=false
DB_POOL_MAX=10
DB_IDLE_TIMEOUT_MS=30000
DB_CONNECTION_TIMEOUT_MS=5000
ORDER_EVENTS_QUEUE_URL=${ORDER_EVENTS_QUEUE_URL}
AWS_REGION=${REGION}
EOF
umask 022

# ------------------------------------------------------------
# Containers
# ------------------------------------------------------------

aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY}"

docker network inspect bookstore >/dev/null 2>&1 || docker network create bookstore

# The backend image runs as the "node" user (uid 1000)
install -d -o 1000 -g 1000 /var/log/bookstore

docker run -d --name backend \
    --network bookstore \
    --restart unless-stopped \
    --init \
    -p 5001:5001 \
    --env-file /etc/bookstore/backend.env \
    -v /var/log/bookstore:/usr/src/app/logs \
    "${BACKEND_IMAGE}"

docker run -d --name frontend \
    --network bookstore \
    --restart unless-stopped \
    -p 80:80 \
    -e NGINX_PORT=80 \
    -e API_PROXY_PREFIX=/api \
    -e PROXY_PASS=http://backend:5001 \
    "${FRONTEND_IMAGE}"

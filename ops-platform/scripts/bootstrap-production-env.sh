#!/bin/sh
set -eu

env_file=${1:-.env}
credentials_file=${2:-.bootstrap-credentials}

if [ -e "$env_file" ]; then
  echo "Refusing to overwrite existing environment file: $env_file" >&2
  exit 1
fi
if [ -e "$credentials_file" ]; then
  echo "Refusing to overwrite existing credentials file: $credentials_file" >&2
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to generate production secrets" >&2
  exit 1
fi

umask 077
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

random_hex() {
  openssl rand -hex "$1"
}

base64_one_line() {
  base64 < "$1" | tr -d '\r\n'
}

owner_email=${BOOTSTRAP_OWNER_EMAIL:-admin@stacio.local}
owner_name=${BOOTSTRAP_OWNER_NAME:-Stacio Owner}
owner_password=${BOOTSTRAP_OWNER_PASSWORD:-$(random_hex 18)}
postgres_user=${POSTGRES_USER:-stacio_ops}
postgres_password=${POSTGRES_PASSWORD:-$(random_hex 24)}
postgres_db=${POSTGRES_DB:-stacio_ops}
data_root=${DATA_ROOT:-./data}
agent_api_key=$(random_hex 32)

case "$postgres_user:$postgres_password:$postgres_db" in
  *[!A-Za-z0-9_.:~-]*)
    echo "PostgreSQL bootstrap values must be URL-safe ASCII" >&2
    exit 1
    ;;
esac

openssl genpkey -algorithm Ed25519 -out "$tmp_dir/license-private.pem" >/dev/null 2>&1
openssl pkey -in "$tmp_dir/license-private.pem" -pubout -out "$tmp_dir/license-public.pem" >/dev/null 2>&1

jwt_secret=$(openssl rand -base64 48 | tr -d '\r\n')
connector_key=$(openssl rand -base64 32 | tr -d '\r\n')
agent_key_pepper=$(random_hex 32)
analytics_hash_key=$(random_hex 32)
license_private_key=$(base64_one_line "$tmp_dir/license-private.pem")
license_public_key=$(base64_one_line "$tmp_dir/license-public.pem")

cat > "$env_file" <<EOF
NODE_ENV=production
COMPOSE_PROJECT_NAME=stacio-ops
WEB_PORT=${WEB_PORT:-8081}
API_PORT=${API_PORT:-8080}
WEB_BIND_HOST=${WEB_BIND_HOST:-127.0.0.1}
API_BIND_HOST=${API_BIND_HOST:-127.0.0.1}
VITE_API_BASE_URL=/api/v1
VITE_DEMO_MODE=false
JWT_SECRET=$jwt_secret
ANALYTICS_HASH_KEY=$analytics_hash_key
JWT_EXPIRES_IN=8h
REFRESH_TOKEN_EXPIRES_DAYS=30
TRUST_PROXY=${TRUST_PROXY:-false}
BOOTSTRAP_OWNER_EMAIL=$owner_email
BOOTSTRAP_OWNER_PASSWORD=$owner_password
BOOTSTRAP_OWNER_NAME="$owner_name"

CONNECTOR_ENCRYPTION_KEY_BASE64=$connector_key

PUBLIC_FEEDBACK_RATE_LIMIT_MAX=30
PUBLIC_FEEDBACK_RATE_LIMIT_WINDOW_SECONDS=60
PUBLIC_TELEMETRY_RATE_LIMIT_MAX=120
PUBLIC_TELEMETRY_RATE_LIMIT_WINDOW_SECONDS=60

DATA_ROOT="$data_root"
DATABASE_URL=postgres://$postgres_user:$postgres_password@postgres:5432/$postgres_db
POSTGRES_USER=$postgres_user
POSTGRES_PASSWORD=$postgres_password
POSTGRES_DB=$postgres_db
DATABASE_AUTO_MIGRATE=true
DATABASE_SEED_DEFAULTS=true
DATABASE_POOL_MAX=10
DATABASE_CONNECT_TIMEOUT_MS=10000
DATABASE_IDLE_TIMEOUT_MS=30000
DATABASE_SSL=false
DATABASE_SSL_REJECT_UNAUTHORIZED=true

API_MEMORY_LIMIT=${API_MEMORY_LIMIT:-512m}
WORKER_MEMORY_LIMIT=${WORKER_MEMORY_LIMIT:-384m}
WEB_MEMORY_LIMIT=${WEB_MEMORY_LIMIT:-128m}
POSTGRES_MEMORY_LIMIT=${POSTGRES_MEMORY_LIMIT:-512m}
REDIS_MEMORY_LIMIT=${REDIS_MEMORY_LIMIT:-128m}
LOG_MAX_SIZE=${LOG_MAX_SIZE:-10m}
LOG_MAX_FILES=${LOG_MAX_FILES:-5}

REDIS_URL=redis://redis:6379

S3_ENDPOINT=
S3_REGION=auto
S3_BUCKET=
S3_ACCESS_KEY_ID=
S3_SECRET_ACCESS_KEY=
S3_FORCE_PATH_STYLE=true
S3_PUBLIC_BASE_URL=
S3_OBJECT_PREFIX=products/stacio
S3_PRESIGN_EXPIRES_SECONDS=900

SMTP_HOST=
SMTP_PORT=465
SMTP_SECURE=true
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=
SMTP_DRY_RUN=true

NOTIFICATION_QUIET_HOURS_START=22:00
NOTIFICATION_QUIET_HOURS_END=08:00
NOTIFICATION_QUIET_HOURS_TIME_ZONE=Asia/Shanghai

GITHUB_OWNER=
GITHUB_REPOSITORY=
GITHUB_TOKEN=
GITHUB_API_BASE_URL=https://api.github.com
GITHUB_APP_ID=
GITHUB_PRIVATE_KEY_BASE64=
GITHUB_WEBHOOK_SECRET=

AGENT_API_KEY_PEPPER=$agent_key_pepper
AGENT_API_KEYS_JSON=[{"id":"codex-feedback","key":"$agent_api_key","name":"Codex feedback triage","productIds":["stacio"],"scopes":["feedback:read","feedback:write_analysis","feedback:write_draft","issues:read","customers:read","licenses:read","notifications:write_draft","actions:propose","releases:read","releases:write_draft"],"expiresAt":"2099-01-01T00:00:00.000Z"}]
AGENT_API_KEY=

LICENSE_PRIVATE_KEY_BASE64=$license_private_key
LICENSE_PUBLIC_KEY_BASE64=$license_public_key
EOF

cat > "$credentials_file" <<EOF
Bootstrap owner email: $owner_email
Bootstrap owner password: $owner_password
Codex Agent API key: $agent_api_key
EOF

chmod 600 "$env_file" "$credentials_file"
echo "Created $env_file and $credentials_file with mode 600."
echo "Review integration settings before enabling SMTP, object storage, or GitHub sync."

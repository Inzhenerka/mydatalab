#!/bin/bash
set -Eeuo pipefail

FOREGROUND=0
if [[ ${1:-} == "--foreground" ]]; then
  FOREGROUND=1
  shift
fi

LAKEKEEPER_BIN=${LAKEKEEPER_BIN:-/usr/local/bin/lakekeeper}
LAKEKEEPER_PORT=${LAKEKEEPER_PORT:-8181}
LAKEKEEPER_METRICS_PORT=${LAKEKEEPER_METRICS_PORT:-19100}
LAKEKEEPER_BIND_IP=${LAKEKEEPER_BIND_IP:-0.0.0.0}
LAKEKEEPER_LOG_FILE=${LAKEKEEPER_LOG_FILE:-${SUPERVISOR_LOG_DIR:-/srv/mydatalab/logs}/lakekeeper.log}
LAKEKEEPER_HEALTHCHECK_RETRIES=${LAKEKEEPER_HEALTHCHECK_RETRIES:-60}
LAKEKEEPER_HEALTHCHECK_INTERVAL=${LAKEKEEPER_HEALTHCHECK_INTERVAL:-1}
LAKEKEEPER_BOOTSTRAP_RETRIES=${LAKEKEEPER_BOOTSTRAP_RETRIES:-30}
LAKEKEEPER_BOOTSTRAP_SLEEP=${LAKEKEEPER_BOOTSTRAP_SLEEP:-2}
LAKEKEEPER_DATABASE=${LAKEKEEPER_DATABASE:-lakekeeper}
LAKEKEEPER_ENCRYPTION_KEY=${LAKEKEEPER_ENCRYPTION_KEY:-mydatalab-secret-key}
LAKEKEEPER_RUST_LOG=${LAKEKEEPER_RUST_LOG:-info}
LAKEKEEPER_WAREHOUSE=${LAKEKEEPER_WAREHOUSE:-mydatalab}
LAKEKEEPER_WAREHOUSE_PREFIX=${LAKEKEEPER_WAREHOUSE_PREFIX:-warehouse}
LAKEKEEPER_WAREHOUSE_REGION=${LAKEKEEPER_WAREHOUSE_REGION:-local-01}
LAKEKEEPER_BOOTSTRAP_PROJECT=${LAKEKEEPER_BOOTSTRAP_PROJECT:-00000000-0000-0000-0000-000000000000}
LAKEKEEPER_STORAGE_FLAVOR=${LAKEKEEPER_STORAGE_FLAVOR:-minio}
LAKEKEEPER_STORAGE_STS_ENABLED=${LAKEKEEPER_STORAGE_STS_ENABLED:-true}
LAKEKEEPER_BOOTSTRAP_SKIP_CHECK=${LAKEKEEPER_BOOTSTRAP_SKIP_CHECK:-false}

POSTGRES_HOST=${POSTGRES_HOST:-127.0.0.1}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}

MINIO_SERVER_ADDRESS=${MINIO_SERVER_ADDRESS:-:9000}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}
MINIO_BUCKET=${MINIO_BUCKET:-mydatalab}

log() {
  printf '[%s] [lakekeeper] %s\n' "$(date -Iseconds)" "$*" >&2
}

minio_loopback_url() {
  local address=$1
  local port=${address##*:}
  printf 'http://127.0.0.1:%s' "$port"
}

wait_for_postgres() {
  local attempts=60
  log "Waiting for PostgreSQL on ${POSTGRES_HOST}:${POSTGRES_PORT}"
  until pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" >/dev/null 2>&1; do
    ((attempts--)) || {
      log "PostgreSQL is not ready"
      return 1
    }
    sleep 1
  done
  log "PostgreSQL is ready"
}

ensure_database() {
  if [[ -n ${LAKEKEEPER__PG_DATABASE_URL_WRITE:-} ]]; then
    log "LAKEKEEPER__PG_DATABASE_URL_WRITE is set; skipping automatic database creation"
    return
  fi

  export PGPASSWORD="$POSTGRES_PASSWORD"
  local exists
  exists=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${LAKEKEEPER_DATABASE}'" || true)
  if [[ $exists != "1" ]]; then
    log "Creating database ${LAKEKEEPER_DATABASE}"
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${LAKEKEEPER_DATABASE}\"" >/dev/null
  else
    log "Database ${LAKEKEEPER_DATABASE} already exists"
  fi
}

wait_for_minio() {
  local endpoint attempts=60
  endpoint=$(minio_loopback_url "$MINIO_SERVER_ADDRESS")
  log "Waiting for MinIO on ${endpoint}"
  until curl -fsS --max-time 2 "${endpoint}/minio/health/live" >/dev/null 2>&1; do
    ((attempts--)) || {
      log "MinIO is not reachable at ${endpoint}"
      return 1
    }
    sleep 1
  done
  log "MinIO is ready"
}

is_success_status() {
  case "${1:-}" in
    200|201|204|409) return 0 ;;
    *) return 1 ;;
  esac
}

is_bootstrapped() {
  local api="http://127.0.0.1:${LAKEKEEPER_PORT}"
  local info
  info=$(curl -fsS --max-time 2 "${api}/management/v1/info" 2>/dev/null || true)
  [[ $info == *'"bootstrapped":true'* ]]
}

warehouse_exists() {
  local api="http://127.0.0.1:${LAKEKEEPER_PORT}"
  local resp
  resp=$(curl -fsS --max-time 2 "${api}/management/v1/warehouse" 2>/dev/null || true)
  [[ $resp == *"\"name\":\"${LAKEKEEPER_WAREHOUSE}\""* ]]
}

bootstrap_lakekeeper() {
  local api="http://127.0.0.1:${LAKEKEEPER_PORT}"
  local status attempts=$LAKEKEEPER_BOOTSTRAP_RETRIES

  if [[ ${LAKEKEEPER_BOOTSTRAP_SKIP_CHECK,,} != "true" ]] && is_bootstrapped; then
    log "Catalog already bootstrapped; skipping bootstrap request"
    return 0
  fi

  while ((attempts--)); do
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${api}/management/v1/bootstrap" \
      -H "Content-Type: application/json" \
      --data '{"accept-terms-of-use": true}' || true)

    if is_success_status "$status"; then
      log "Bootstrap request completed with status ${status}"
      return 0
    fi

    if [[ $status == "400" ]] && is_bootstrapped; then
      log "Bootstrap not required (server reports bootstrapped)"
      return 0
    fi

    log "Bootstrap request failed with status ${status}, attempts left: ${attempts}"
    sleep "$LAKEKEEPER_BOOTSTRAP_SLEEP"
  done

  log "Bootstrap request exhausted retries"
  return 1
}

create_default_warehouse() {
  local api="http://127.0.0.1:${LAKEKEEPER_PORT}"
  local endpoint
  endpoint=$(minio_loopback_url "$MINIO_SERVER_ADDRESS")
  local sts="${LAKEKEEPER_STORAGE_STS_ENABLED,,}"
  [[ -z $sts ]] && sts=true

  local status attempts=$LAKEKEEPER_BOOTSTRAP_RETRIES

  if warehouse_exists; then
    log "Warehouse ${LAKEKEEPER_WAREHOUSE} already exists; skipping bootstrap"
    return 0
  fi

  while ((attempts--)); do
    status=$(
      curl -s -o /dev/null -w "%{http_code}" -X POST "${api}/management/v1/warehouse" \
        -H "Content-Type: application/json" \
        --data-binary @- <<JSON || true
{
  "warehouse-name": "${LAKEKEEPER_WAREHOUSE}",
  "project-id": "${LAKEKEEPER_BOOTSTRAP_PROJECT}",
  "storage-profile": {
    "type": "s3",
    "bucket": "${MINIO_BUCKET}",
    "key-prefix": "${LAKEKEEPER_WAREHOUSE_PREFIX}",
    "assume-role-arn": null,
    "endpoint": "${endpoint}",
    "region": "${LAKEKEEPER_WAREHOUSE_REGION}",
    "path-style-access": true,
    "flavor": "${LAKEKEEPER_STORAGE_FLAVOR}",
    "sts-enabled": ${sts}
  },
  "storage-credential": {
    "type": "s3",
    "credential-type": "access-key",
    "aws-access-key-id": "${MINIO_ROOT_USER}",
    "aws-secret-access-key": "${MINIO_ROOT_PASSWORD}"
  }
}
JSON
    )

    if is_success_status "$status"; then
      log "Warehouse bootstrap completed with status ${status}"
      return 0
    fi

    if [[ $status == "400" ]] && warehouse_exists; then
      log "Warehouse already present; skipping bootstrap"
      return 0
    fi

    log "Warehouse bootstrap failed with status ${status}, attempts left: ${attempts}"
    sleep "$LAKEKEEPER_BOOTSTRAP_SLEEP"
  done

  log "Warehouse bootstrap exhausted retries"
  return 1
}

start_lakekeeper() {
  mkdir -p "$(dirname "$LAKEKEEPER_LOG_FILE")"
  touch "$LAKEKEEPER_LOG_FILE"

  local default_pg_url="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${LAKEKEEPER_DATABASE}"
  local pg_url="${LAKEKEEPER__PG_DATABASE_URL_WRITE:-$default_pg_url}"
  export LAKEKEEPER__LISTEN_PORT="$LAKEKEEPER_PORT"
  export LAKEKEEPER__BIND_IP="$LAKEKEEPER_BIND_IP"
  export LAKEKEEPER__METRICS_PORT="$LAKEKEEPER_METRICS_PORT"
  export LAKEKEEPER__PG_DATABASE_URL_WRITE="$pg_url"
  export LAKEKEEPER__PG_DATABASE_URL_READ="${LAKEKEEPER__PG_DATABASE_URL_READ:-$pg_url}"
  export LAKEKEEPER__PG_ENCRYPTION_KEY="$LAKEKEEPER_ENCRYPTION_KEY"
  export LAKEKEEPER__SERVE_SWAGGER_UI=true
  export LAKEKEEPER__ALLOW_ORIGIN=*
  export LAKEKEEPER__ENABLE_DEFAULT_PROJECT=true
  export LAKEKEEPER__DEBUG__MIGRATE_BEFORE_SERVE=true
  export LAKEKEEPER__SECRET_BACKEND=postgres
  export RUST_LOG="$LAKEKEEPER_RUST_LOG"

  log "Starting Lakekeeper on ${LAKEKEEPER_BIND_IP}:${LAKEKEEPER_PORT}"
  "$LAKEKEEPER_BIN" serve \
    > >(tee -a "$LAKEKEEPER_LOG_FILE" >&2) 2>&1 &
  lakekeeper_pid=$!
}

wait_for_healthcheck() {
  local attempts=$LAKEKEEPER_HEALTHCHECK_RETRIES
  while ((attempts--)); do
    if "$LAKEKEEPER_BIN" healthcheck >/dev/null 2>&1; then
      log "Lakekeeper is healthy"
      return 0
    fi
    sleep "$LAKEKEEPER_HEALTHCHECK_INTERVAL"
  done

  log "Lakekeeper healthcheck failed"
  tail -n 50 "$LAKEKEEPER_LOG_FILE" >&2 || true
  return 1
}

stop_lakekeeper() {
  if [ -n "${lakekeeper_pid:-}" ] && kill -0 "$lakekeeper_pid" 2>/dev/null; then
    log "Stopping Lakekeeper (pid $lakekeeper_pid)"
    kill -TERM "$lakekeeper_pid" >/dev/null 2>&1 || true
  fi
}

if (( FOREGROUND )); then
  trap stop_lakekeeper EXIT
fi

if [[ -n ${LAKEKEEPER__PG_DATABASE_URL_WRITE:-} ]]; then
  log "Using custom PostgreSQL connection string; skipping local readiness checks"
else
  wait_for_postgres
  ensure_database
fi
wait_for_minio
start_lakekeeper
wait_for_healthcheck
bootstrap_lakekeeper
create_default_warehouse

if (( FOREGROUND )); then
  trap stop_lakekeeper TERM INT
  wait "$lakekeeper_pid"
  exit $?
fi

printf '%s\n' "$lakekeeper_pid"

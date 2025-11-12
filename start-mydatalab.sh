#!/bin/bash
set -Eeuo pipefail

POSTGRES_DATA_DIR=${POSTGRES_DATA_DIR:-${PGDATA:-/home/jovyan/postgres-data/data}}
POSTGRES_LOG_FILE=${POSTGRES_LOG_FILE:-$(dirname "$POSTGRES_DATA_DIR")/postgres.log}
POSTGRES_ENTRYPOINT=${POSTGRES_ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}
POSTGRES_LISTEN_ADDRESSES=${POSTGRES_LISTEN_ADDRESSES:-*}
POSTGRES_LOG_TAIL_LINES=${POSTGRES_LOG_TAIL_LINES:-200}
MINIO_SERVER_ADDRESS=${MINIO_SERVER_ADDRESS:-:9000}
MINIO_CONSOLE_ADDRESS=${MINIO_CONSOLE_ADDRESS:-:9001}
STATIC_PORT=${STATIC_PORT:-1111}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/scripts" ]; then
  DEFAULT_SERVICE_DIR="$SCRIPT_DIR/scripts"
else
  DEFAULT_SERVICE_DIR="$SCRIPT_DIR"
fi
SERVICE_SCRIPTS_DIR=${SERVICE_SCRIPTS_DIR:-$DEFAULT_SERVICE_DIR}

if [ "$(id -u)" -eq 0 ]; then
  NB_UID=${NB_UID:-1000}
  NB_GID=${NB_GID:-100}
  mkdir -p "$POSTGRES_DATA_DIR"
  chown -R "$NB_UID:$NB_GID" "$POSTGRES_DATA_DIR"
  chmod 700 "$POSTGRES_DATA_DIR" || true
  exec gosu "$NB_UID:$NB_GID" "$0" "$@"
fi

required_vars=(POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB MINIO_ROOT_USER MINIO_ROOT_PASSWORD)
for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "Environment variable $var must be set" >&2
    exit 1
  fi
done

export POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_HOST_AUTH_METHOD POSTGRES_INITDB_ARGS
export PGDATA="$POSTGRES_DATA_DIR"
export PGPORT="$POSTGRES_PORT"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

stop_pid() {
  local name=$1 pid=$2
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "Stopping $name"
    kill "$pid" >/dev/null 2>&1 || true
  fi
}

MINIO_PID=""
POSTGRES_PID=""
STATIC_PID=""

cleanup() {
  stop_pid "static site" "$STATIC_PID"
  stop_pid "MinIO" "$MINIO_PID"
  if [ -d "$POSTGRES_DATA_DIR" ]; then
    pg_ctl -D "$POSTGRES_DATA_DIR" -m fast stop >/dev/null 2>&1 || stop_pid "PostgreSQL" "$POSTGRES_PID"
  fi
}
trap cleanup EXIT

POSTGRES_PID="$("$SERVICE_SCRIPTS_DIR/start-postgres.sh")"
MINIO_PID="$("$SERVICE_SCRIPTS_DIR/start-minio.sh")"
STATIC_PID="$("$SERVICE_SCRIPTS_DIR/start-static-site.sh")"

exec /usr/local/bin/start.sh start-notebook.py \
  --ServerApp.token='' \
  --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  "$@"

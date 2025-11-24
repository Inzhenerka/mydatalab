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
SUPERVISOR_CONFIG=${SUPERVISOR_CONFIG:-/etc/supervisor/supervisord.conf}
SUPERVISOR_LOG_DIR=${SUPERVISOR_LOG_DIR:-/srv/mydatalab/logs}
SUPERVISOR_RUN_DIR=${SUPERVISOR_RUN_DIR:-/srv/mydatalab/run}
SUPERVISOR_HTTP_ADDRESS=${SUPERVISOR_HTTP_ADDRESS:-0.0.0.0:9010}
SUPERVISOR_HTTP_USER=${SUPERVISOR_HTTP_USER:-admin}
SUPERVISOR_HTTP_PASSWORD=${SUPERVISOR_HTTP_PASSWORD:-admin}

if [ "$(id -u)" -eq 0 ]; then
  NB_UID=${NB_UID:-1000}
  NB_GID=${NB_GID:-100}
  mkdir -p "$POSTGRES_DATA_DIR" "$SUPERVISOR_LOG_DIR" "$SUPERVISOR_RUN_DIR"
  chown -R "$NB_UID:$NB_GID" "$POSTGRES_DATA_DIR" "$SUPERVISOR_LOG_DIR" "$SUPERVISOR_RUN_DIR"
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
export SUPERVISOR_HTTP_USER SUPERVISOR_HTTP_PASSWORD SUPERVISOR_HTTP_ADDRESS SUPERVISOR_LOG_DIR SUPERVISOR_RUN_DIR

mkdir -p "$POSTGRES_DATA_DIR" "$SUPERVISOR_LOG_DIR" "$SUPERVISOR_RUN_DIR"
chmod 700 "$POSTGRES_DATA_DIR" 2>/dev/null || true

build_extra_notebook_args() {
  local arg quoted=""
  for arg in "$@"; do
    quoted+=" $(printf '%q' "$arg")"
  done
  printf '%s' "$quoted"
}

NOTEBOOK_COMMAND="/usr/local/bin/start.sh start-notebook.py --ServerApp.token='' --ServerApp.password='' --ServerApp.allow_origin='*'"
if [ "$#" -gt 0 ]; then
  NOTEBOOK_COMMAND+=$(build_extra_notebook_args "$@")
fi
export MYDATALAB_NOTEBOOK_COMMAND="$NOTEBOOK_COMMAND"

exec supervisord -n -c "$SUPERVISOR_CONFIG"

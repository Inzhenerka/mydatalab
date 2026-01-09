#!/bin/bash
set -Eeuo pipefail

FOREGROUND=0
if [[ ${1:-} == "--foreground" ]]; then
  FOREGROUND=1
  shift
fi

MINIO_SERVER_ADDRESS=${MINIO_SERVER_ADDRESS:-:9000}
MINIO_CONSOLE_ADDRESS=${MINIO_CONSOLE_ADDRESS:-:9001}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}
MINIO_ALIAS=${MINIO_ALIAS:-local}
MINIO_BUCKET=${MINIO_BUCKET:-mydatalab}
MINIO_DATA_DIR=${MINIO_DATA_DIR:-/var/lib/mydatalab/minio}
MINIO_LOG_FILE=${MINIO_LOG_FILE:-${SUPERVISOR_LOG_DIR:-/srv/mydatalab/logs}/minio.log}

log() {
  printf '[%s] [minio] %s\n' "$(date -Iseconds)" "$*" >&2
}

minio_loopback_url() {
  local address=$1
  local port=$address
  if [[ $address == *:* ]]; then
    port=${address##*:}
  fi
  printf 'http://127.0.0.1:%s' "$port"
}

stop_minio() {
  if [ -n "${minio_pid:-}" ] && kill -0 "$minio_pid" 2>/dev/null; then
    log "Stopping MinIO (pid $minio_pid)"
    kill -TERM "$minio_pid" >/dev/null 2>&1 || true
  fi
}

mkdir -p "$MINIO_DATA_DIR" "$(dirname "$MINIO_LOG_FILE")"
touch "$MINIO_LOG_FILE"

log "Starting MinIO on ${MINIO_SERVER_ADDRESS} (console ${MINIO_CONSOLE_ADDRESS})"
minio server "$MINIO_DATA_DIR" --address "$MINIO_SERVER_ADDRESS" --console-address "$MINIO_CONSOLE_ADDRESS" \
  > >(tee -a "$MINIO_LOG_FILE" >&2) 2>&1 &
minio_pid=$!

sleep 5
mc alias set "$MINIO_ALIAS" "$(minio_loopback_url "$MINIO_SERVER_ADDRESS")" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || true
mc mb "$MINIO_ALIAS/$MINIO_BUCKET" >/dev/null 2>&1 || true
log "MinIO is ready"

if (( FOREGROUND )); then
  trap stop_minio TERM INT
  wait "$minio_pid"
  exit $?
fi

printf '%s\n' "$minio_pid"

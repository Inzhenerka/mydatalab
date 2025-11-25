#!/bin/bash
set -Eeuo pipefail

FOREGROUND=0
if [[ ${1:-} == "--foreground" ]]; then
  FOREGROUND=1
  shift
fi

STATIC_PORT=${STATIC_PORT:-1111}
STATIC_ROOT=${STATIC_ROOT:-/home/jovyan/site}
STATIC_LOG_FILE=${STATIC_LOG_FILE:-${SUPERVISOR_LOG_DIR:-/srv/mydatalab/logs}/static-site.log}

log() {
  printf '[%s] [static] %s\n' "$(date -Iseconds)" "$*" >&2
}

stop_static() {
  if [ -n "${static_pid:-}" ] && kill -0 "$static_pid" 2>/dev/null; then
    log "Stopping static site (pid $static_pid)"
    kill -TERM "$static_pid" >/dev/null 2>&1 || true
  fi
}

mkdir -p "$(dirname "$STATIC_LOG_FILE")"
touch "$STATIC_LOG_FILE"

log "Serving landing page on 0.0.0.0:${STATIC_PORT}"
(
  cd "$STATIC_ROOT"
  python -m http.server "$STATIC_PORT" --bind 0.0.0.0
) > >(tee -a "$STATIC_LOG_FILE" >&2) 2>&1 &
static_pid=$!

if (( FOREGROUND )); then
  trap stop_static TERM INT
  wait "$static_pid"
  exit $?
fi

printf '%s\n' "$static_pid"

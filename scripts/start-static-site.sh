#!/bin/bash
set -Eeuo pipefail

STATIC_PORT=${STATIC_PORT:-1111}
STATIC_ROOT=${STATIC_ROOT:-/home/jovyan/start}
STATIC_LOG_FILE=${STATIC_LOG_FILE:-/home/jovyan/static-site.log}

log() {
  printf '[%s] [static] %s\n' "$(date -Iseconds)" "$*" >&2
}

mkdir -p "$(dirname "$STATIC_LOG_FILE")"
touch "$STATIC_LOG_FILE"

log "Serving landing page on 0.0.0.0:${STATIC_PORT}"
(
  cd "$STATIC_ROOT"
  python -m http.server "$STATIC_PORT" --bind 0.0.0.0
) > >(tee -a "$STATIC_LOG_FILE" >&2) 2>&1 &
static_pid=$!

printf '%s\n' "$static_pid"

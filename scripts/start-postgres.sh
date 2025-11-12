#!/bin/bash
set -Eeuo pipefail

POSTGRES_DATA_DIR=${POSTGRES_DATA_DIR:-${PGDATA:-/home/jovyan/postgres-data/data}}
POSTGRES_LOG_FILE=${POSTGRES_LOG_FILE:-$(dirname "$POSTGRES_DATA_DIR")/postgres.log}
POSTGRES_ENTRYPOINT=${POSTGRES_ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}
POSTGRES_LISTEN_ADDRESSES=${POSTGRES_LISTEN_ADDRESSES:-*}
POSTGRES_LOG_TAIL_LINES=${POSTGRES_LOG_TAIL_LINES:-200}
POSTGRES_PORT=${POSTGRES_PORT:-5432}

log() {
  printf '[%s] [postgres] %s\n' "$(date -Iseconds)" "$*" >&2
}

tail_postgres_logs() {
  if [ -f "$POSTGRES_LOG_FILE" ]; then
    log "Last $POSTGRES_LOG_TAIL_LINES log lines:"
    tail -n "$POSTGRES_LOG_TAIL_LINES" "$POSTGRES_LOG_FILE" >&2 || true
  fi
}

wait_for_postgres() {
  local attempts=30
  until pg_isready -h 127.0.0.1 -p "$POSTGRES_PORT" -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1; do
    ((attempts--)) || {
      log "PostgreSQL did not start in time"
      tail_postgres_logs
      return 1
    }
    sleep 1
  done
  log "PostgreSQL is ready"
}

mkdir -p "$POSTGRES_DATA_DIR" "$(dirname "$POSTGRES_LOG_FILE")" /var/run/postgresql || true
chmod 700 "$POSTGRES_DATA_DIR" 2>/dev/null || true

export POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_HOST_AUTH_METHOD POSTGRES_INITDB_ARGS
export PGDATA="$POSTGRES_DATA_DIR"
export PGPORT="$POSTGRES_PORT"

log "Starting PostgreSQL on port $POSTGRES_PORT"
args=(-p "$POSTGRES_PORT" -c "listen_addresses=${POSTGRES_LISTEN_ADDRESSES}")
if [ -n "${POSTGRES_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  extra_args=( $POSTGRES_EXTRA_ARGS )
  args+=("${extra_args[@]}")
fi

"$POSTGRES_ENTRYPOINT" postgres "${args[@]}" \
  > >(tee -a "$POSTGRES_LOG_FILE" >&2) 2>&1 &
postgres_pid=$!

wait_for_postgres

printf '%s\n' "$postgres_pid"

#!/bin/bash
set -Eeuo pipefail

FOREGROUND=0
if [[ ${1:-} == "--foreground" ]]; then
  FOREGROUND=1
  shift
fi

POSTGRES_DATA_DIR=${POSTGRES_DATA_DIR:-${PGDATA:-/var/lib/mydatalab/postgres/data}}
POSTGRES_LOG_FILE=${POSTGRES_LOG_FILE:-${SUPERVISOR_LOG_DIR:-/srv/mydatalab/logs}/postgres.log}
POSTGRES_ENTRYPOINT=${POSTGRES_ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}
POSTGRES_LISTEN_ADDRESSES=${POSTGRES_LISTEN_ADDRESSES:-*}
POSTGRES_LOG_TAIL_LINES=${POSTGRES_LOG_TAIL_LINES:-200}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_PID_FILE="$POSTGRES_DATA_DIR/postmaster.pid"

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

cleanup_postmaster_pid() {
  if [ ! -f "$POSTGRES_PID_FILE" ]; then
    return
  fi

  local existing_pid=""
  existing_pid=$(head -n 1 "$POSTGRES_PID_FILE" 2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    log "Found existing PostgreSQL process (pid $existing_pid); stopping it before restart"
    pg_ctl -D "$POSTGRES_DATA_DIR" -m fast stop >/dev/null 2>&1 || true
    local attempts=30
    while kill -0 "$existing_pid" 2>/dev/null && ((attempts-- > 0)); do
      sleep 1
    done
    if kill -0 "$existing_pid" 2>/dev/null; then
      log "PostgreSQL pid $existing_pid ignored SIGTERM, sending SIGKILL"
      kill -KILL "$existing_pid" >/dev/null 2>&1 || true
    fi
  else
    log "Removing stale postmaster.pid file"
  fi

  rm -f "$POSTGRES_PID_FILE" >/dev/null 2>&1 || true
}

stop_postgres() {
  if [ -n "${postgres_pid:-}" ] && kill -0 "$postgres_pid" 2>/dev/null; then
    log "Stopping PostgreSQL (pid $postgres_pid)"
    kill -TERM "$postgres_pid" >/dev/null 2>&1 || true
  fi
}

mkdir -p "$POSTGRES_DATA_DIR" "$(dirname "$POSTGRES_LOG_FILE")" /var/run/postgresql || true
chmod 700 "$POSTGRES_DATA_DIR" 2>/dev/null || true

export POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_HOST_AUTH_METHOD POSTGRES_INITDB_ARGS
export PGDATA="$POSTGRES_DATA_DIR"
export PGPORT="$POSTGRES_PORT"

cleanup_postmaster_pid

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

if (( FOREGROUND )); then
  trap stop_postgres TERM INT
  wait "$postgres_pid"
  exit $?
fi

printf '%s\n' "$postgres_pid"

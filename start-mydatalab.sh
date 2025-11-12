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

minio_loopback_url() {
  local address=$1
  local port=$address
  if [[ $address == *:* ]]; then
    port=${address##*:}
  fi
  printf 'http://127.0.0.1:%s' "$port"
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

tail_postgres_logs() {
  if [ -f "$POSTGRES_LOG_FILE" ]; then
    log "Last $POSTGRES_LOG_TAIL_LINES log lines:"
    tail -n "$POSTGRES_LOG_TAIL_LINES" "$POSTGRES_LOG_FILE" || true
  fi
}

wait_for_postgres() {
  local attempts=30
  until pg_isready -h 127.0.0.1 -p "$POSTGRES_PORT" -U "$POSTGRES_USER" >/dev/null 2>&1; do
    ((attempts--)) || {
      log "PostgreSQL did not start in time"
      tail_postgres_logs
      return 1
    }
    sleep 1
  done
  log "PostgreSQL is ready"
}

start_postgres() {
  mkdir -p "$POSTGRES_DATA_DIR" "$(dirname "$POSTGRES_LOG_FILE")" /var/run/postgresql || true
  chmod 700 "$POSTGRES_DATA_DIR" 2>/dev/null || true
  log "Starting PostgreSQL on port $POSTGRES_PORT"
  local args=(-p "$POSTGRES_PORT" -c "listen_addresses=${POSTGRES_LISTEN_ADDRESSES}")
  local extra_args=()
  if [ -n "${POSTGRES_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    extra_args=( $POSTGRES_EXTRA_ARGS )
    args+=("${extra_args[@]}")
  fi
  (
    "$POSTGRES_ENTRYPOINT" postgres "${args[@]}" \
      > >(tee -a "$POSTGRES_LOG_FILE") 2>&1
  ) &
  POSTGRES_PID=$!
  wait_for_postgres
}

start_minio() {
  log "Starting MinIO on ${MINIO_SERVER_ADDRESS} (console ${MINIO_CONSOLE_ADDRESS})"
  minio server /data/minio --address "$MINIO_SERVER_ADDRESS" --console-address "$MINIO_CONSOLE_ADDRESS" &
  MINIO_PID=$!
  sleep 5
  mc alias set local "$(minio_loopback_url "$MINIO_SERVER_ADDRESS")" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || true
  mc mb local/edu-bucket >/dev/null 2>&1 || true
  log "MinIO is ready"
}

start_static_site() {
  log "Serving landing page on 0.0.0.0:${STATIC_PORT}"
  (cd /home/jovyan/start && python -m http.server "$STATIC_PORT" --bind 0.0.0.0) &
  STATIC_PID=$!
}

start_postgres
start_minio
start_static_site

exec /usr/local/bin/start.sh start-notebook.py \
  --ServerApp.token='' \
  --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  "$@"

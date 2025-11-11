#!/bin/bash
set -e

POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
POSTGRES_DB=${POSTGRES_DB:-$POSTGRES_USER}
POSTGRES_DATA_DIR=${POSTGRES_DATA_DIR:-/home/jovyan/postgres-data/data}
POSTGRES_LOG_FILE=${POSTGRES_LOG_FILE:-/home/jovyan/postgres-data/postgres.log}

if [ "$(id -u)" -eq 0 ]; then
  NB_UID=${NB_UID:-1000}
  NB_GID=${NB_GID:-100}
  mkdir -p "$POSTGRES_DATA_DIR"
  chown -R "$NB_UID:$NB_GID" "$POSTGRES_DATA_DIR"
  chmod 700 "$POSTGRES_DATA_DIR" || true
  exec gosu "$NB_UID:$NB_GID" "$0" "$@"
fi

export MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
export MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

POSTGRES_LOG_TAIL_LINES=${POSTGRES_LOG_TAIL_LINES:-200}
POSTGRES_HOST_AUTH_METHOD=${POSTGRES_HOST_AUTH_METHOD:-scram-sha-256}
if [ -z "${POSTGRES_INITDB_ARGS:-}" ]; then
  POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256 --auth-local=trust"
fi
POSTGRES_ENTRYPOINT=${POSTGRES_ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}
POSTGRES_EXTRA_ARGS=${POSTGRES_EXTRA_ARGS:-}
POSTGRES_LISTEN_ADDRESSES=${POSTGRES_LISTEN_ADDRESSES:-*}

export POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_HOST_AUTH_METHOD POSTGRES_INITDB_ARGS
export PGDATA=$POSTGRES_DATA_DIR
export PGPORT=$POSTGRES_PORT

MINIO_PID=""
POSTGRES_PID=""
STATIC_PID=""

cleanup() {
  if [ -n "$STATIC_PID" ] && kill -0 "$STATIC_PID" 2>/dev/null; then
    kill "$STATIC_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$MINIO_PID" ] && kill -0 "$MINIO_PID" 2>/dev/null; then
    kill "$MINIO_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$POSTGRES_PID" ] && kill -0 "$POSTGRES_PID" 2>/dev/null; then
    pg_ctl -D "$POSTGRES_DATA_DIR" -m fast stop >/dev/null 2>&1 || kill "$POSTGRES_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

report_postgres_failure() {
  echo "---- PostgreSQL debug info ----"
  if [ -n "$POSTGRES_PID" ]; then
    if kill -0 "$POSTGRES_PID" >/dev/null 2>&1; then
      echo "Process $POSTGRES_PID is still running."
    else
      wait "$POSTGRES_PID" >/dev/null 2>&1 || true
      echo "Process $POSTGRES_PID has already exited."
    fi
  else
    echo "Postgres process PID is not set."
  fi
  if [ -f "$POSTGRES_LOG_FILE" ]; then
    echo "-- Last $POSTGRES_LOG_TAIL_LINES lines from $POSTGRES_LOG_FILE --"
    tail -n "$POSTGRES_LOG_TAIL_LINES" "$POSTGRES_LOG_FILE" || true
  else
    echo "Postgres log file $POSTGRES_LOG_FILE not found."
  fi
  if [ -d "$POSTGRES_DATA_DIR" ]; then
    echo "-- Contents of $POSTGRES_DATA_DIR --"
    ls -l "$POSTGRES_DATA_DIR" || true
  else
    echo "Postgres data directory $POSTGRES_DATA_DIR not found."
  fi
  echo "---------------------------------"
}

wait_for_postgres() {
  for i in $(seq 1 30); do
    # capture pg_isready output so we can display it to the user
    output=$(pg_isready -h 127.0.0.1 -p "$POSTGRES_PORT" -U "$POSTGRES_USER" 2>&1) || true
    rc=$?
    echo "pg_isready attempt $i: $output"
    if [ "$rc" -eq 0 ]; then
      echo "PostgreSQL is ready (attempt $i)."
      return 0
    fi
    sleep 1
  done
  echo "PostgreSQL did not become ready in time" >&2
  report_postgres_failure
  return 1
}

start_postgres() {
  mkdir -p "$POSTGRES_DATA_DIR" "$(dirname "$POSTGRES_LOG_FILE")" /var/run/postgresql
  if [ ! -s "$POSTGRES_DATA_DIR/PG_VERSION" ]; then
    case "$POSTGRES_LOG_FILE" in
      "$POSTGRES_DATA_DIR"/*)
        rm -f "$POSTGRES_LOG_FILE" 2>/dev/null || true
        ;;
    esac
  fi
  echo "Starting PostgreSQL via official entrypoint on port $POSTGRES_PORT"
  local args extra_args
  args=(-p "$POSTGRES_PORT" -c "listen_addresses=${POSTGRES_LISTEN_ADDRESSES}")
  if [ -n "$POSTGRES_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    extra_args=( $POSTGRES_EXTRA_ARGS )
    args+=("${extra_args[@]}")
  fi
  (
    set -o pipefail
    "$POSTGRES_ENTRYPOINT" postgres "${args[@]}" \
      > >(tee -a "$POSTGRES_LOG_FILE") 2>&1
  ) &
  POSTGRES_PID=$!
  wait_for_postgres
  echo "PostgreSQL is ready. Data dir: $POSTGRES_DATA_DIR"
}

start_minio() {
  minio server /data/minio --address :9000 --console-address :9001 &
  MINIO_PID=$!
  echo "Waiting for MinIO to start..."
  sleep 5
  mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || true
  mc mb local/edu-bucket >/dev/null 2>&1 || true
  echo "MinIO is up. Bucket 'edu-bucket' is ready."
}

start_static_site() {
  echo "Starting static landing on http://127.0.0.1:1111  http://0.0.0.0:1111"
  (cd /home/jovyan/start && python -m http.server 1111 --bind 0.0.0.0) &
  STATIC_PID=$!
}

start_postgres
start_minio
start_static_site

# run the Jupyter notebook server last
exec /usr/local/bin/start.sh start-notebook.py \
  --ServerApp.token='' \
  --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  "$@"

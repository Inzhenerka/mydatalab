#!/bin/bash
set -Eeuo pipefail

FOREGROUND=0
if [[ ${1:-} == "--foreground" ]]; then
  FOREGROUND=1
  shift
fi

GRAVITINO_HOME=${GRAVITINO_HOME:-/opt/gravitino}
GRAVITINO_BIN=${GRAVITINO_BIN:-${GRAVITINO_HOME}/bin/gravitino.sh}
GRAVITINO_DATA_DIR=${GRAVITINO_DATA_DIR:-/srv/gravitino}
# Конфиги держим не в bind-mount, а в локальном каталоге внутри контейнера
GRAVITINO_CONF_DIR=${GRAVITINO_CONF_DIR:-${GRAVITINO_HOME}/conf-local}
GRAVITINO_DB_DIR=${GRAVITINO_DB_DIR:-${GRAVITINO_DATA_DIR}}
GRAVITINO_TEMPLATE_DIR=${GRAVITINO_TEMPLATE_DIR:-/etc/gravitino/templates}
GRAVITINO_MAIN_CONF=${GRAVITINO_MAIN_CONF:-${GRAVITINO_CONF_DIR}/gravitino.conf}
GRAVITINO_LOG_DIR=${GRAVITINO_LOG_DIR:-${SUPERVISOR_LOG_DIR:-/srv/mydatalab/logs}/gravitino}
GRAVITINO_LOG_FILE=${GRAVITINO_LOG_FILE:-${GRAVITINO_LOG_DIR}/gravitino-server.out}
GRAVITINO_WEB_HOST=${GRAVITINO_WEB_HOST:-0.0.0.0}
GRAVITINO_WEB_PORT=${GRAVITINO_WEB_PORT:-8090}
GRAVITINO_MEM=${GRAVITINO_MEM:--Xms1024m -Xmx1024m -XX:MaxMetaspaceSize=512m}
GRAVITINO_STORE_JDBC=${GRAVITINO_STORE_JDBC:-jdbc:h2:file:${GRAVITINO_DB_DIR}/gravitino_store;AUTO_SERVER=TRUE;MODE=MYSQL}
GRAVITINO_STORE_DRIVER=${GRAVITINO_STORE_DRIVER:-org.h2.Driver}
GRAVITINO_STORE_USER=${GRAVITINO_STORE_USER:-gravitino}
GRAVITINO_STORE_PASSWORD=${GRAVITINO_STORE_PASSWORD:-gravitino}
GRAVITINO_VERSION=${GRAVITINO_VERSION:-0.9.1}

ICEBERG_REST_PORT=${ICEBERG_REST_PORT:-8181}
ICEBERG_CATALOG_NAME=${ICEBERG_CATALOG_NAME:-mydatalab}
ICEBERG_WAREHOUSE=${ICEBERG_WAREHOUSE:-s3://mydatalab/warehouse}
ICEBERG_JDBC_URI=${ICEBERG_JDBC_URI:-jdbc:h2:file:${GRAVITINO_DB_DIR}/iceberg_catalog;AUTO_SERVER=TRUE;MODE=MYSQL}
ICEBERG_JDBC_USER=${ICEBERG_JDBC_USER:-gravitino}
ICEBERG_JDBC_PASSWORD=${ICEBERG_JDBC_PASSWORD:-gravitino}
ICEBERG_AWS_REGION=${ICEBERG_AWS_REGION:-us-east-1}
ICEBERG_MINIO_ENDPOINT=${ICEBERG_MINIO_ENDPOINT:-http://127.0.0.1:9000}
ICEBERG_CONFIG_SOURCE=${ICEBERG_CONFIG_SOURCE:-${GRAVITINO_CONF_DIR}/gravitino-iceberg-rest-server.conf}
ICEBERG_CONFIG_TARGET=${ICEBERG_CONFIG_TARGET:-${GRAVITINO_HOME}/iceberg-rest-server/conf/gravitino-iceberg-rest-server.conf}

MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

# Ensure template rendering sees all defaults
export \
  GRAVITINO_HOME GRAVITINO_BIN GRAVITINO_DATA_DIR GRAVITINO_CONF_DIR GRAVITINO_DB_DIR \
  GRAVITINO_TEMPLATE_DIR GRAVITINO_MAIN_CONF GRAVITINO_LOG_DIR GRAVITINO_LOG_FILE \
  GRAVITINO_WEB_HOST GRAVITINO_WEB_PORT GRAVITINO_MEM GRAVITINO_STORE_JDBC \
  GRAVITINO_STORE_DRIVER GRAVITINO_STORE_USER GRAVITINO_STORE_PASSWORD GRAVITINO_VERSION \
  ICEBERG_REST_PORT ICEBERG_CATALOG_NAME ICEBERG_WAREHOUSE ICEBERG_JDBC_URI \
  ICEBERG_JDBC_USER ICEBERG_JDBC_PASSWORD ICEBERG_AWS_REGION ICEBERG_MINIO_ENDPOINT \
  ICEBERG_CONFIG_SOURCE ICEBERG_CONFIG_TARGET MINIO_ROOT_USER MINIO_ROOT_PASSWORD

log() {
  printf '[%s] [gravitino] %s\n' "$(date -Iseconds)" "$*" >&2
}

ensure_parent_dir_from_uri() {
  local uri=$1
  local path=""
  case "$uri" in
    jdbc:h2:file:*)
      path=${uri#jdbc:h2:file:}
      path=${path%%;*}
      ;;
    *)
      return
      ;;
  esac
  if [[ -n "$path" ]]; then
    mkdir -p "$(dirname "$path")"
  fi
}

ensure_paths() {
  mkdir -p "$GRAVITINO_CONF_DIR" "$GRAVITINO_LOG_DIR" "$GRAVITINO_DB_DIR"
  if [[ ! -d "$GRAVITINO_DB_DIR" ]]; then
    log "Cannot access Gravitino DB directory at $GRAVITINO_DB_DIR (check bind mount permissions)"
    exit 1
  fi
  touch "$GRAVITINO_LOG_FILE" 2>/tmp/gravitino-touch.log || {
    log "Failed to touch log file $GRAVITINO_LOG_FILE, see /tmp/gravitino-touch.log"
    exit 1
  }

  ensure_parent_dir_from_uri "$GRAVITINO_STORE_JDBC"
  ensure_parent_dir_from_uri "$ICEBERG_JDBC_URI"

  if ! cat >"${GRAVITINO_CONF_DIR}/gravitino-env.sh" <<EOF
GRAVITINO_VERSION=${GRAVITINO_VERSION:-0.0.0}
EOF
  then
    log "Failed to write ${GRAVITINO_CONF_DIR}/gravitino-env.sh"
    ls -ld "$GRAVITINO_CONF_DIR" || true
    exit 1
  fi
}

render_template_if_missing() {
  local template=$1
  local dest=$2
  local mode=${3:-copy}

  if [[ ! -f "$template" || -f "$dest" ]]; then
    return
  fi

  case "$mode" in
    env)
      envsubst <"$template" >"$dest"
      ;;
    *)
      cp "$template" "$dest"
      ;;
  esac
}

seed_default_configs() {
  if [[ ! -d "$GRAVITINO_TEMPLATE_DIR" ]]; then
    return
  fi

  render_template_if_missing "${GRAVITINO_TEMPLATE_DIR}/gravitino.conf" "$GRAVITINO_MAIN_CONF" env
  render_template_if_missing "${GRAVITINO_TEMPLATE_DIR}/gravitino-iceberg-rest-server.conf" "$ICEBERG_CONFIG_SOURCE" env
  render_template_if_missing "${GRAVITINO_TEMPLATE_DIR}/log4j2.properties" "${GRAVITINO_CONF_DIR}/log4j2.properties" copy

  if [[ -n "$ICEBERG_JDBC_USER" && -f "$GRAVITINO_MAIN_CONF" ]]; then
    if ! grep -q 'gravitino\.iceberg-rest\.jdbc-user' "$GRAVITINO_MAIN_CONF"; then
      printf 'gravitino.iceberg-rest.jdbc-user = %s\n' "$ICEBERG_JDBC_USER" >>"$GRAVITINO_MAIN_CONF"
    fi
  fi
  if [[ -n "$ICEBERG_JDBC_PASSWORD" && -f "$GRAVITINO_MAIN_CONF" ]]; then
    if ! grep -q 'gravitino\.iceberg-rest\.jdbc-password' "$GRAVITINO_MAIN_CONF"; then
      printf 'gravitino.iceberg-rest.jdbc-password = %s\n' "$ICEBERG_JDBC_PASSWORD" >>"$GRAVITINO_MAIN_CONF"
    fi
  fi

  if [[ -n "$ICEBERG_JDBC_USER" && -f "$ICEBERG_CONFIG_SOURCE" ]]; then
    if ! grep -q 'jdbc.user' "$ICEBERG_CONFIG_SOURCE"; then
      printf '  jdbc.user: "%s"\n' "$ICEBERG_JDBC_USER" >>"$ICEBERG_CONFIG_SOURCE"
    fi
  fi
  if [[ -n "$ICEBERG_JDBC_PASSWORD" && -f "$ICEBERG_CONFIG_SOURCE" ]]; then
    if ! grep -q 'jdbc.password' "$ICEBERG_CONFIG_SOURCE"; then
      printf '  jdbc.password: "%s"\n' "$ICEBERG_JDBC_PASSWORD" >>"$ICEBERG_CONFIG_SOURCE"
    fi
  fi
}

start_gravitino() {
  export GRAVITINO_HOME GRAVITINO_CONF_DIR GRAVITINO_LOG_DIR GRAVITINO_MEM
  local cmd=( "$GRAVITINO_BIN" --config "$GRAVITINO_CONF_DIR" )

  if (( FOREGROUND )); then
    log "Starting Gravitino server with web UI on ${GRAVITINO_WEB_HOST}:${GRAVITINO_WEB_PORT} (streaming logs)"
    "${cmd[@]}" run >>"$GRAVITINO_LOG_FILE" 2>&1 &
    server_pid=$!

    tail -n +1 -F "$GRAVITINO_LOG_FILE" &
    tail_pid=$!

    cleanup() {
      if [[ -n "${server_pid:-}" ]]; then
        kill -TERM "$server_pid" >/dev/null 2>&1 || true
      fi
      if [[ -n "${tail_pid:-}" ]]; then
        kill "$tail_pid" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup TERM INT

    wait "$server_pid"
    status=$?
    cleanup
    wait "$tail_pid" 2>/dev/null || true
    exit $status
  fi

  log "Starting Gravitino server in background"
  "${cmd[@]}" start >/dev/null 2>&1 || {
    log "Failed to start Gravitino"
    exit 1
  }

  sleep 2
  local pid
  pid=$(pgrep -f GravitinoServer || true)
  if [[ -z "$pid" ]]; then
    log "Could not detect Gravitino process"
    exit 1
  fi
  printf '%s\n' "$pid"
}

ensure_paths
seed_default_configs
install -d "$(dirname "$ICEBERG_CONFIG_TARGET")"
cp "$ICEBERG_CONFIG_SOURCE" "$ICEBERG_CONFIG_TARGET"
log "Configuration ready. Logs directory: $GRAVITINO_LOG_DIR"

if [[ ! -x "$GRAVITINO_BIN" ]]; then
  log "Gravitino binary not found at $GRAVITINO_BIN"
  exit 1
fi

start_gravitino

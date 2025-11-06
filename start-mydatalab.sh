#!/bin/bash
set -e

export MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
export MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

# 1. стартуем MinIO
minio server /data/minio --address :9000 --console-address :9001 &
MINIO_PID=$!

# убьём minio при выходе
trap "kill $MINIO_PID" EXIT

echo "Waiting for MinIO to start..."
sleep 5

# 2. настраиваем mc
mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || true
mc mb local/edu-bucket >/dev/null 2>&1 || true
echo "MinIO is up. Bucket 'edu-bucket' is ready."

echo "Starting static landing on http://127.0.0.1:1111  http://0.0.0.0:1111"
(cd /home/jovyan/start && python -m http.server 1111 --bind 0.0.0.0) &


# здесь продолжается ваш запуск MinIO/Jupyter и т.д.
# exec <основной процесс, как у вас было>
# он уже есть в образе и называется именно /usr/local/bin/start.sh
exec /usr/local/bin/start.sh start-notebook.py \
  --ServerApp.token='' \
  --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  "$@"

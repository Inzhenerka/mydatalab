# Stage 1: pull PostgreSQL userland binaries that we will embed later
FROM postgres:18.0-trixie@sha256:41fc5342eefba6cc2ccda736aaf034bbbb7c3df0fdb81516eba1ba33f360162c AS postgres-src

# Stage 2: extend the official PySpark notebook with storage services
FROM quay.io/jupyter/pyspark-notebook:spark-4.0.1@sha256:37c62b362043b5d6876a2d93f2fce2aba741a05e7fffa166f0abaf04b6f53343

# Version switches for the components we download at build time
ARG HADOOP_AWS_VERSION=3.4.1
ARG AWS_BUNDLE_VERSION=2.37.3
ARG ICEBERG_VERSION=1.10.0
ARG ICEBERG_SPARK_VERSION=4.0
ARG ICEBERG_SCALA_VERSION=2.13
ARG MINIO_SERVER_RELEASE=2025-09-07T16-13-09Z
ARG MINIO_CLIENT_RELEASE=2025-08-13T08-35-41Z
ARG LAKEKEEPER_VERSION=0.10.4
ARG LAKEKEEPER_ARCHIVE=lakekeeper-x86_64-unknown-linux-gnu.tar.gz

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Pre-load Spark with the AWS connector jars so S3-compatible storage works
RUN install -d -m 0755 /usr/local/spark/jars && \
    curl -fsSL "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" \
      -o /usr/local/spark/jars/hadoop-aws-${HADOOP_AWS_VERSION}.jar && \
    curl -fsSL "https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/${AWS_BUNDLE_VERSION}/bundle-${AWS_BUNDLE_VERSION}.jar" \
      -o /usr/local/spark/jars/bundle-${AWS_BUNDLE_VERSION}.jar && \
    curl -fsSL "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-${ICEBERG_SPARK_VERSION}_${ICEBERG_SCALA_VERSION}/${ICEBERG_VERSION}/iceberg-spark-runtime-${ICEBERG_SPARK_VERSION}_${ICEBERG_SCALA_VERSION}-${ICEBERG_VERSION}.jar" \
      -o /usr/local/spark/jars/iceberg-spark-runtime-${ICEBERG_SPARK_VERSION}_${ICEBERG_SCALA_VERSION}-${ICEBERG_VERSION}.jar && \
    curl -fsSL "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar" \
      -o /usr/local/spark/jars/iceberg-aws-bundle-${ICEBERG_VERSION}.jar

# Install the only native dependency MinIO server requires
RUN apt-get update && \
    apt-get install -y --no-install-recommends liburing2 supervisor && \
    rm -rf /var/lib/apt/lists/*

RUN install -d /etc/supervisor

# MinIO server binary
RUN curl -fsSL "https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.${MINIO_SERVER_RELEASE}" -o /usr/local/bin/minio \
    && chmod +x /usr/local/bin/minio

# MinIO client (mc) for bootstrap tasks
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/archive/mc.RELEASE.${MINIO_CLIENT_RELEASE}" -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

# Lakekeeper binary (Iceberg REST catalog)
RUN curl -fsSL "https://github.com/lakekeeper/lakekeeper/releases/download/v${LAKEKEEPER_VERSION}/${LAKEKEEPER_ARCHIVE}" \
      -o "/tmp/${LAKEKEEPER_ARCHIVE}" \
    && tar -xzf "/tmp/${LAKEKEEPER_ARCHIVE}" -C /usr/local/bin \
    && rm "/tmp/${LAKEKEEPER_ARCHIVE}" \
    && chmod +x /usr/local/bin/lakekeeper

# PostgreSQL runtime copied from the official postgres:18 image
COPY --from=postgres-src /usr/lib/postgresql /usr/lib/postgresql
COPY --from=postgres-src /usr/share/postgresql /usr/share/postgresql
COPY --from=postgres-src /usr/lib/x86_64-linux-gnu/libpq.so* /usr/lib/x86_64-linux-gnu/
COPY --from=postgres-src /usr/lib/x86_64-linux-gnu/libicu*.so* /usr/lib/x86_64-linux-gnu/
COPY --from=postgres-src /usr/lib/x86_64-linux-gnu/libssl.so* /usr/lib/x86_64-linux-gnu/
COPY --from=postgres-src /usr/lib/x86_64-linux-gnu/libcrypto.so* /usr/lib/x86_64-linux-gnu/
COPY --from=postgres-src /etc/postgresql /etc/postgresql
COPY --from=postgres-src /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --from=postgres-src /usr/local/bin/gosu /usr/local/bin/gosu

# Prepare writable directories for the non-root notebook user
RUN install -d -o $NB_UID -g $NB_GID /data/minio \
    && install -d -o $NB_UID -g $NB_GID /srv/mydatalab/logs /srv/mydatalab/run \
    && install -d -o $NB_UID -g $NB_GID /home/jovyan/.jupyter/labconfig

# Tweak the Jupyter landing page
COPY --chown=$NB_UID:$NB_GID customization/page_config.json /home/jovyan/.jupyter/labconfig/page_config.json

# Static assets used by the lightweight welcome site
COPY --chown=$NB_UID:$NB_GID site /home/jovyan/site

# Copy notebooks
COPY --chown=$NB_UID:$NB_GID notebooks/START.ipynb /home/jovyan/START.ipynb
COPY --chown=$NB_UID:$NB_GID notebooks/demo/ /home/jovyan/demo/

# Copy orchestration scripts that control all bundled services
COPY start-mydatalab.sh /usr/local/bin/start-mydatalab.sh
COPY scripts/*.sh /usr/local/bin/
COPY supervisor/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/start-mydatalab.sh /usr/local/bin/start-*.sh

# Consolidated configuration for PostgreSQL, MinIO and the static server
ENV PATH="/usr/lib/postgresql/18/bin:${PATH}" \
    PG_MAJOR=18 \
    PGDATA=/home/jovyan/postgres-data/data \
    POSTGRES_PORT=5432 \
    POSTGRES_USER=postgres \
    POSTGRES_PASSWORD=postgres \
    POSTGRES_DB=postgres \
    POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
    POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256 --auth-local=trust" \
    POSTGRES_EXTRA_ARGS= \
    POSTGRES_LISTEN_ADDRESSES=* \
    POSTGRES_DATA_DIR=/home/jovyan/postgres-data/data \
    POSTGRES_LOG_FILE=/home/jovyan/postgres-data/postgres.log \
    POSTGRES_LOG_TAIL_LINES=200 \
    POSTGRES_ENTRYPOINT=/usr/local/bin/docker-entrypoint.sh \
    MINIO_ROOT_USER=minioadmin \
    MINIO_ROOT_PASSWORD=minioadmin \
    MINIO_SERVER_ADDRESS=:9000 \
    MINIO_CONSOLE_ADDRESS=:9001 \
    STATIC_PORT=1111 \
    SUPERVISOR_CONFIG=/etc/supervisor/supervisord.conf \
    SUPERVISOR_LOG_DIR=/srv/mydatalab/logs \
    SUPERVISOR_RUN_DIR=/srv/mydatalab/run \
    SUPERVISOR_HTTP_ADDRESS=0.0.0.0:9010 \
    SUPERVISOR_HTTP_USER=admin \
    SUPERVISOR_HTTP_PASSWORD=admin \
    LAKEKEEPER_PORT=8181 \
    LAKEKEEPER_METRICS_PORT=19100 \
    LAKEKEEPER_DATABASE=lakekeeper \
    LAKEKEEPER_ENCRYPTION_KEY=mydatalab-secret-key \
    LAKEKEEPER_WAREHOUSE=mydatalab \
    LAKEKEEPER_WAREHOUSE_PREFIX=warehouse \
    LAKEKEEPER_WAREHOUSE_REGION=local-01 \
    LAKEKEEPER_BOOTSTRAP_PROJECT=00000000-0000-0000-0000-000000000000 \
    LAKEKEEPER_RUST_LOG=info \
    LAKEKEEPER_STORAGE_FLAVOR=minio \
    LAKEKEEPER_STORAGE_STS_ENABLED=true \
    LAKEKEEPER_BIND_IP=0.0.0.0

# Ensure runtime directories exist for both PostgreSQL and initdb scripts
RUN install -d -o $NB_UID -g $NB_GID \
      /home/jovyan/postgres-data \
      /home/jovyan/postgres-data/data \
      /var/run/postgresql \
      /docker-entrypoint-initdb.d

# Publish all service ports out of the container
EXPOSE 8888 4040 9000 9001 8181 5432 1111 9010

# Unified entrypoint that starts PostgreSQL, MinIO, the static page and Jupyter
CMD ["/usr/local/bin/start-mydatalab.sh"]

# Stage 1: pull PostgreSQL userland binaries that we will embed later
FROM postgres:18.0-trixie AS postgres-src

# Stage 2: extend the official PySpark notebook with storage services
FROM quay.io/jupyter/pyspark-notebook:spark-4.0.1

# Version switches for the components we download at build time
ARG HADOOP_AWS_VERSION=3.4.1
ARG AWS_BUNDLE_VERSION=2.37.3
ARG MINIO_SERVER_RELEASE=2025-09-07T16-13-09Z
ARG MINIO_CLIENT_RELEASE=2025-08-13T08-35-41Z

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Pre-load Spark with the AWS connector jars so S3-compatible storage works
RUN install -d -m 0755 /usr/local/spark/jars && \
    curl -fsSL "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" \
      -o /usr/local/spark/jars/hadoop-aws-${HADOOP_AWS_VERSION}.jar && \
    curl -fsSL "https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/${AWS_BUNDLE_VERSION}/bundle-${AWS_BUNDLE_VERSION}.jar" \
      -o /usr/local/spark/jars/bundle-${AWS_BUNDLE_VERSION}.jar

# Install the only native dependency MinIO server requires
RUN apt-get update && \
    apt-get install -y --no-install-recommends liburing2 && \
    rm -rf /var/lib/apt/lists/*

# MinIO server binary
RUN curl -fsSL "https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.${MINIO_SERVER_RELEASE}" -o /usr/local/bin/minio \
    && chmod +x /usr/local/bin/minio

# MinIO client (mc) for bootstrap tasks
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/archive/mc.RELEASE.${MINIO_CLIENT_RELEASE}" -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

# Prepare writable directories for the non-root notebook user
RUN install -d -o $NB_UID -g $NB_GID /data/minio \
    && install -d -o $NB_UID -g $NB_GID /home/jovyan/.jupyter/labconfig

# Tweak the Jupyter landing page
COPY --chown=$NB_UID:$NB_GID customization/page_config.json /home/jovyan/.jupyter/labconfig/page_config.json

# Static assets used by the lightweight welcome site
COPY --chown=$NB_UID:$NB_GID start /home/jovyan/start

# Copy orchestration scripts that control all bundled services
COPY start-mydatalab.sh /usr/local/bin/start-mydatalab.sh
COPY scripts/*.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start-mydatalab.sh /usr/local/bin/start-*.sh

# PostgreSQL runtime copied from the official postgres:18 image
COPY --from=postgres-src /usr/lib/postgresql /usr/lib/postgresql
COPY --from=postgres-src /usr/share/postgresql /usr/share/postgresql
COPY --from=postgres-src /usr/lib/x86_64-linux-gnu/libpq.so* /usr/lib/x86_64-linux-gnu/
COPY --from=postgres-src /usr/lib/x86_64-linux-gnu/libicu*.so* /usr/lib/x86_64-linux-gnu/
COPY --from=postgres-src /etc/postgresql /etc/postgresql
COPY --from=postgres-src /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --from=postgres-src /usr/local/bin/gosu /usr/local/bin/gosu

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
    STATIC_PORT=1111

# Ensure runtime directories exist for both PostgreSQL and initdb scripts
RUN install -d -o $NB_UID -g $NB_GID \
      /home/jovyan/postgres-data \
      /home/jovyan/postgres-data/data \
      /var/run/postgresql \
      /docker-entrypoint-initdb.d

# Publish all service ports out of the container
EXPOSE 8888 9000 9001 5432 1111

# Unified entrypoint that starts PostgreSQL, MinIO, the static page and Jupyter
CMD ["/usr/local/bin/start-mydatalab.sh"]

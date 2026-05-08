# Stage 1: pull PostgreSQL userland binaries that we will embed later
FROM postgres:18.0-trixie@sha256:41fc5342eefba6cc2ccda736aaf034bbbb7c3df0fdb81516eba1ba33f360162c AS postgres-src

# Stage 1b: gather arch-specific PostgreSQL libs into an arch-agnostic path so the
# final stage does not need to hardcode /usr/lib/<triplet>. This stage runs on the
# target platform, so the correct multiarch dir is auto-selected by buildx.
FROM postgres-src AS postgres-libs
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eux; \
    if   [ -d /usr/lib/x86_64-linux-gnu ];  then ARCH_DIR=x86_64-linux-gnu; \
    elif [ -d /usr/lib/aarch64-linux-gnu ]; then ARCH_DIR=aarch64-linux-gnu; \
    else echo "unsupported architecture: $(uname -m)" >&2; exit 1; fi; \
    install -d /pglibs; \
    cp -a /usr/lib/${ARCH_DIR}/libpq.so*     /pglibs/; \
    cp -a /usr/lib/${ARCH_DIR}/libicu*.so*   /pglibs/; \
    cp -a /usr/lib/${ARCH_DIR}/libssl.so*    /pglibs/; \
    cp -a /usr/lib/${ARCH_DIR}/libcrypto.so* /pglibs/; \
    echo "${ARCH_DIR}" > /pglibs/.arch_dir

# Stage 2: extend the official PySpark notebook with storage services
FROM quay.io/jupyter/pyspark-notebook:spark-4.0.1@sha256:37c62b362043b5d6876a2d93f2fce2aba741a05e7fffa166f0abaf04b6f53343

# Provided by buildx for multi-arch builds; values: amd64 | arm64 | ...
ARG TARGETARCH

# Version switches for the components we download at build time
ARG HADOOP_AWS_VERSION=3.4.1
ARG AWS_BUNDLE_VERSION=2.37.3
ARG ICEBERG_VERSION=1.10.0
ARG ICEBERG_SPARK_VERSION=4.0
ARG ICEBERG_SCALA_VERSION=2.13
ARG MINIO_SERVER_RELEASE=2025-09-07T16-13-09Z
ARG MINIO_CLIENT_RELEASE=2025-08-13T08-35-41Z
ARG LAKEKEEPER_VERSION=0.10.4

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

# MinIO server binary (linux-amd64 / linux-arm64 — paths align with $TARGETARCH)
RUN curl -fsSL "https://dl.min.io/server/minio/release/linux-${TARGETARCH}/archive/minio.RELEASE.${MINIO_SERVER_RELEASE}" -o /usr/local/bin/minio \
    && chmod +x /usr/local/bin/minio

# MinIO client (mc) for bootstrap tasks
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/archive/mc.RELEASE.${MINIO_CLIENT_RELEASE}" -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

# Lakekeeper binary (Iceberg REST catalog)
# Note: upstream ships Linux arm64 only as a statically-linked musl build, while
# amd64 is glibc. Both run fine inside this Debian-based image.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) LK_ARCHIVE="lakekeeper-x86_64-unknown-linux-gnu.tar.gz" ;; \
      arm64) LK_ARCHIVE="lakekeeper-aarch64-unknown-linux-musl.tar.gz" ;; \
      *) echo "Unsupported TARGETARCH for Lakekeeper: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/lakekeeper/lakekeeper/releases/download/v${LAKEKEEPER_VERSION}/${LK_ARCHIVE}" \
      -o "/tmp/${LK_ARCHIVE}"; \
    tar -xzf "/tmp/${LK_ARCHIVE}" -C /usr/local/bin; \
    rm "/tmp/${LK_ARCHIVE}"; \
    chmod +x /usr/local/bin/lakekeeper

# PostgreSQL runtime copied from the official postgres:18 image
COPY --from=postgres-src /usr/lib/postgresql /usr/lib/postgresql
COPY --from=postgres-src /usr/share/postgresql /usr/share/postgresql
COPY --from=postgres-src /etc/postgresql /etc/postgresql
COPY --from=postgres-src /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --from=postgres-src /usr/local/bin/gosu /usr/local/bin/gosu

# Arch-specific PostgreSQL libs were collected by the postgres-libs stage
# under /pglibs (with .arch_dir noting the multiarch triplet).
COPY --from=postgres-libs /pglibs /tmp/pglibs
RUN set -eux; \
    ARCH_DIR=$(cat /tmp/pglibs/.arch_dir); \
    install -d "/usr/lib/${ARCH_DIR}"; \
    cp -a /tmp/pglibs/*.so* "/usr/lib/${ARCH_DIR}/"; \
    rm -rf /tmp/pglibs

# Prepare writable directories for the non-root notebook user
RUN install -d -o $NB_UID -g $NB_GID /var/lib/mydatalab/minio \
    && install -d -o $NB_UID -g $NB_GID /srv/mydatalab/logs /srv/mydatalab/run \
    && install -d -o $NB_UID -g $NB_GID /home/jovyan/.jupyter/labconfig

# Tweak the Jupyter landing page
COPY --chown=$NB_UID:$NB_GID customization/page_config.json /home/jovyan/.jupyter/labconfig/page_config.json

# Static assets used by the lightweight welcome site
COPY --chown=$NB_UID:$NB_GID site /home/jovyan/site

# Copy notebooks
COPY --chown=$NB_UID:$NB_GID notebooks/START.ipynb /home/jovyan/START.ipynb
COPY --chown=$NB_UID:$NB_GID notebooks/demo/ /home/jovyan/demo/
COPY --chown=$NB_UID:$NB_GID notebooks/solutions/ /home/jovyan/solutions/

# Copy orchestration scripts that control all bundled services
COPY start-mydatalab.sh /usr/local/bin/start-mydatalab.sh
COPY scripts/*.sh /usr/local/bin/
COPY supervisor/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/start-mydatalab.sh /usr/local/bin/start-*.sh

# Consolidated configuration for PostgreSQL, MinIO and the static server
ENV PATH="/usr/lib/postgresql/18/bin:${PATH}" \
    PG_MAJOR=18 \
    PGDATA=/var/lib/mydatalab/postgres/data \
    POSTGRES_PORT=5432 \
    POSTGRES_USER=postgres \
    POSTGRES_PASSWORD=postgres \
    POSTGRES_DB=postgres \
    POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
    POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256 --auth-local=trust" \
    POSTGRES_EXTRA_ARGS= \
    POSTGRES_LISTEN_ADDRESSES=* \
    POSTGRES_DATA_DIR=/var/lib/mydatalab/postgres/data \
    POSTGRES_LOG_FILE=/var/lib/mydatalab/postgres/postgres.log \
    POSTGRES_LOG_TAIL_LINES=200 \
    POSTGRES_ENTRYPOINT=/usr/local/bin/docker-entrypoint.sh \
    MINIO_DATA_DIR=/var/lib/mydatalab/minio \
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
      /var/lib/mydatalab/postgres \
      /var/lib/mydatalab/postgres/data \
      /var/run/postgresql \
      /docker-entrypoint-initdb.d

# Publish all service ports out of the container
EXPOSE 8888 4040 9000 9001 8181 5432 1111 9010

# Unified entrypoint that starts PostgreSQL, MinIO, the static page and Jupyter
CMD ["/usr/local/bin/start-mydatalab.sh"]

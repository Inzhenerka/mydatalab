# Extend the official PySpark notebook with storage services
FROM quay.io/jupyter/pyspark-notebook:spark-4.0.1

# Version switches for the components we download at build time
ARG HADOOP_AWS_VERSION=3.4.1
ARG AWS_BUNDLE_VERSION=2.37.3
ARG MINIO_SERVER_RELEASE=2025-09-07T16-13-09Z
ARG MINIO_CLIENT_RELEASE=2025-08-13T08-35-41Z

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Pre-load Spark with the AWS connector jars so S3-compatible storage works
RUN set -eux; \
    install -d -m 0755 /usr/local/spark/jars; \
    curl -fsSL "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" \
      -o /usr/local/spark/jars/hadoop-aws-${HADOOP_AWS_VERSION}.jar & \
    curl -fsSL "https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/${AWS_BUNDLE_VERSION}/bundle-${AWS_BUNDLE_VERSION}.jar" \
      -o /usr/local/spark/jars/bundle-${AWS_BUNDLE_VERSION}.jar & \
    wait

# Install the native dependencies MinIO and our helpers require
RUN apt-get update && \
    apt-get install -y --no-install-recommends liburing2 supervisor gosu && \
    rm -rf /var/lib/apt/lists/*

RUN install -d /etc/supervisor

# MinIO server binary
RUN curl -fsSL "https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.${MINIO_SERVER_RELEASE}" -o /usr/local/bin/minio \
    && chmod +x /usr/local/bin/minio

# MinIO client (mc) for bootstrap tasks
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/archive/mc.RELEASE.${MINIO_CLIENT_RELEASE}" -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

# Prepare writable directories for the non-root notebook user
RUN install -d -o $NB_UID -g $NB_GID /data/minio \
    && install -d -o $NB_UID -g $NB_GID /srv/mydatalab/logs /srv/mydatalab/run \
    && install -d -o $NB_UID -g $NB_GID /home/jovyan/.jupyter/labconfig

# Tweak the Jupyter landing page
COPY --chown=$NB_UID:$NB_GID customization/page_config.json /home/jovyan/.jupyter/labconfig/page_config.json

# Static assets used by the lightweight welcome site
COPY --chown=$NB_UID:$NB_GID start /home/jovyan/start

# Copy orchestration scripts that control all bundled services
COPY start-mydatalab.sh /usr/local/bin/start-mydatalab.sh
COPY scripts/*.sh /usr/local/bin/
COPY supervisor/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/start-mydatalab.sh /usr/local/bin/start-*.sh

# Consolidated configuration for MinIO, the static server and Supervisord
ENV MINIO_ROOT_USER=minioadmin \
    MINIO_ROOT_PASSWORD=minioadmin \
    MINIO_SERVER_ADDRESS=:9000 \
    MINIO_CONSOLE_ADDRESS=:9001 \
    STATIC_PORT=1111 \
    SUPERVISOR_CONFIG=/etc/supervisor/supervisord.conf \
    SUPERVISOR_LOG_DIR=/srv/mydatalab/logs \
    SUPERVISOR_RUN_DIR=/srv/mydatalab/run \
    SUPERVISOR_HTTP_ADDRESS=0.0.0.0:9010 \
    SUPERVISOR_HTTP_USER=admin \
    SUPERVISOR_HTTP_PASSWORD=admin

# Publish all service ports out of the container
EXPOSE 8888 4040 9000 9001 1111 9010

# Unified entrypoint that starts MinIO, the static page and Jupyter
CMD ["/usr/local/bin/start-mydatalab.sh"]

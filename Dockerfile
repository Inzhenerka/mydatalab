FROM postgres:18.0-trixie AS postgres-src

FROM quay.io/jupyter/pyspark-notebook:spark-4.0.1

ARG HADOOP_AWS_VERSION=3.4.1
ARG AWS_BUNDLE_VERSION=2.37.3
ARG MINIO_SERVER_RELEASE=2025-09-07T16-13-09Z
ARG MINIO_CLIENT_RELEASE=2025-08-13T08-35-41Z

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN install -d -m 0755 /usr/local/spark/jars && \
    curl -fsSL "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" \
      -o /usr/local/spark/jars/hadoop-aws-${HADOOP_AWS_VERSION}.jar && \
    curl -fsSL "https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/${AWS_BUNDLE_VERSION}/bundle-${AWS_BUNDLE_VERSION}.jar" \
      -o /usr/local/spark/jars/bundle-${AWS_BUNDLE_VERSION}.jar

RUN apt-get update && \
    apt-get install -y --no-install-recommends liburing2 && \
    rm -rf /var/lib/apt/lists/*

# MinIO server
RUN curl -fsSL "https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.${MINIO_SERVER_RELEASE}" -o /usr/local/bin/minio \
    && chmod +x /usr/local/bin/minio

# MinIO client
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/archive/mc.RELEASE.${MINIO_CLIENT_RELEASE}" -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

RUN install -d -o $NB_UID -g $NB_GID /data/minio \
    && install -d -o $NB_UID -g $NB_GID /home/jovyan/.jupyter/labconfig

COPY --chown=$NB_UID:$NB_GID customization/page_config.json /home/jovyan/.jupyter/labconfig/page_config.json

COPY --chown=$NB_UID:$NB_GID start /home/jovyan/start

COPY start-mydatalab.sh /usr/local/bin/start-mydatalab.sh
RUN chmod +x /usr/local/bin/start-mydatalab.sh

# PostgreSQL runtime copied from the official postgres:18 image
COPY --from=postgres-src /usr/lib/postgresql /usr/lib/postgresql
COPY --from=postgres-src /usr/share/postgresql /usr/share/postgresql
COPY --from=postgres-src /usr/lib/x86_64-linux-gnu/libpq.so* /usr/lib/x86_64-linux-gnu/
COPY --from=postgres-src /usr/lib/x86_64-linux-gnu/libicu*.so* /usr/lib/x86_64-linux-gnu/
COPY --from=postgres-src /etc/postgresql /etc/postgresql
COPY --from=postgres-src /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --from=postgres-src /usr/local/bin/gosu /usr/local/bin/gosu

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

RUN install -d -o $NB_UID -g $NB_GID \
      /home/jovyan/postgres-data \
      /home/jovyan/postgres-data/data \
      /var/run/postgresql \
      /docker-entrypoint-initdb.d

EXPOSE 8888 9000 9001 5432 1111

CMD ["/usr/local/bin/start-mydatalab.sh"]

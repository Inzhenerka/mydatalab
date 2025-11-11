FROM postgres:18.0-trixie AS postgres-src

FROM quay.io/jupyter/pyspark-notebook:spark-4.0.1

USER root

RUN mkdir -p /usr/local/spark/jars && \
    cd /usr/local/spark/jars && \
    wget https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.4.1/hadoop-aws-3.4.1.jar && \
    wget https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/2.37.3/bundle-2.37.3.jar

RUN apt-get update && \
    apt-get install -y --no-install-recommends liburing2 && \
    rm -rf /var/lib/apt/lists/*

# MinIO server
RUN curl -L https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.2025-09-07T16-13-09Z -o /usr/local/bin/minio \
    && chmod +x /usr/local/bin/minio

# MinIO client
RUN curl -L https://dl.min.io/client/mc/release/linux-amd64/archive/mc.RELEASE.2025-08-13T08-35-41Z -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

RUN mkdir -p /data/minio && chown -R $NB_UID:$NB_GID /data/minio

RUN mkdir -p /home/jovyan/.jupyter/labconfig

COPY customization/page_config.json /home/jovyan/.jupyter/labconfig/page_config.json

RUN chown -R $NB_UID:$NB_GID /home/jovyan/.jupyter

COPY start /home/jovyan/start
RUN chown -R $NB_UID:$NB_GID /home/jovyan/start

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
    PGDATA=/home/jovyan/postgres-data \
    POSTGRES_PORT=5432

RUN mkdir -p /home/jovyan/postgres-data /var/run/postgresql /docker-entrypoint-initdb.d && \
    chown -R $NB_UID:$NB_GID /home/jovyan/postgres-data /var/run/postgresql /docker-entrypoint-initdb.d

USER root

EXPOSE 8888 9000 9001 5432 1111

CMD ["/usr/local/bin/start-mydatalab.sh"]

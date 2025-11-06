FROM quay.io/jupyter/pyspark-notebook:spark-4.0.1

USER root

RUN mkdir -p /usr/local/spark/jars && \
    cd /usr/local/spark/jars && \
    wget https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.4.1/hadoop-aws-3.4.1.jar && \
    wget https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/2.37.3/bundle-2.37.3.jar

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

COPY demo /home/jovyan/demo
RUN chown -R $NB_UID:$NB_GID /home/jovyan/demo

COPY public /home/jovyan/public
RUN chown -R $NB_UID:$NB_GID /home/jovyan/public

COPY start-mydatalab.sh /usr/local/bin/start-mydatalab.sh
RUN chmod +x /usr/local/bin/start-mydatalab.sh

USER $NB_UID

EXPOSE 8888 9000 9001 1111

CMD ["/usr/local/bin/start-mydatalab.sh"]

# Hive local Docker image
# Base: hive-test-base:latest  (Ubuntu 22.04, Hadoop 3.4.2, Tez 0.10.5)
# Adds: Hive 4.3.0-SNAPSHOT local build (with queue-metrics changes)
# Mode: Tez-on-YARN cluster (real YARN for live queue metrics validation)

FROM hive-test-base:latest

ARG HIVE_VERSION=4.3.0-SNAPSHOT

RUN apt-get update && apt-get install -y --no-install-recommends \
        gettext-base \
        netcat-openbsd \
        curl \
        wget \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 1000 --gid 0 -m -s /bin/bash hive \
    && mkdir -p /home/hive/.beeline \
    && chown -R hive:root /home/hive

ENV HIVE_HOME=/opt/hive \
    HIVE_VER=${HIVE_VERSION}

ENV PATH=${HIVE_HOME}/bin:${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${PATH}

# Override Hadoop cluster config
COPY conf/hadoop/core-site.xml          ${HADOOP_HOME}/etc/hadoop/core-site.xml
COPY conf/hadoop/hdfs-site.xml          ${HADOOP_HOME}/etc/hadoop/hdfs-site.xml
COPY conf/hadoop/yarn-site.xml          ${HADOOP_HOME}/etc/hadoop/yarn-site.xml
COPY conf/hadoop/mapred-site.xml        ${HADOOP_HOME}/etc/hadoop/mapred-site.xml
COPY conf/hadoop/capacity-scheduler.xml ${HADOOP_HOME}/etc/hadoop/capacity-scheduler.xml

# Install Hive from local build
COPY apache-hive-${HIVE_VERSION}-bin.tar.gz /tmp/
RUN tar -xzf /tmp/apache-hive-${HIVE_VERSION}-bin.tar.gz -C /opt/ \
    && mv /opt/apache-hive-${HIVE_VERSION}-bin ${HIVE_HOME} \
    && rm /tmp/apache-hive-${HIVE_VERSION}-bin.tar.gz

# PostgreSQL JDBC driver
RUN wget -q \
    https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.3/postgresql-42.7.3.jar \
    -O ${HIVE_HOME}/lib/postgresql.jar

# Hive config: base conf first, then cluster-specific overrides
COPY conf/           ${HIVE_HOME}/conf/
COPY conf-hive/      ${HIVE_HOME}/conf/

# Fix beeline JLine provider to work without a TTY (skip FFM, use exec/dumb)
# Also write a wrapper that can be called non-interactively from deploy.sh
RUN sed -i 's|-Dlog4j.configurationFile=beeline-log4j2.properties|-Dlog4j.configurationFile=beeline-log4j2.properties -Dorg.jline.terminal.providers=exec,dumb|' \
    ${HIVE_HOME}/bin/ext/beeline.sh \
  && cat > /usr/local/bin/beeline-cmd <<'SCRIPT'
#!/usr/bin/env bash
# Thin wrapper: calls BeeLine via java directly so JVM args take effect
# without requiring a TTY (no JLine FFM terminal needed in non-interactive use)
HIVE_HOME="${HIVE_HOME:-/opt/hive}"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
CP="${HIVE_HOME}/lib/hive-beeline-"*".jar:${HIVE_HOME}/lib/jline-"*".jar:${HIVE_HOME}/lib/super-csv-"*".jar:${HIVE_HOME}/lib/hive-jdbc-"*".jar:${HIVE_HOME}/lib/hive-common-"*".jar:${HIVE_HOME}/lib/hive-service-rpc-"*".jar:${HIVE_HOME}/lib/hive-shims-"*".jar:${HIVE_HOME}/lib/slf4j-"*".jar:${HIVE_HOME}/lib/log4j-"*".jar:${HIVE_HOME}/conf:${HADOOP_HOME}/share/hadoop/common/lib/*:${HADOOP_HOME}/share/hadoop/common/*"
"${JAVA_HOME:-/opt/java/openjdk}/bin/java" \
  -Dorg.jline.terminal.providers=exec,dumb \
  -Dlog4j.configurationFile=beeline-log4j2.properties \
  --add-opens java.base/java.nio=ALL-UNNAMED \
  --add-opens java.base/java.lang=ALL-UNNAMED \
  --add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.net=ALL-UNNAMED \
  -cp "${CP}" \
  org.apache.hive.beeline.BeeLine "$@"
SCRIPT
RUN chmod +x /usr/local/bin/beeline-cmd

# Entrypoints
COPY entrypoint.sh       /entrypoint.sh
COPY entrypoint-hive.sh  /entrypoint-hive.sh

RUN mkdir -p \
        ${HIVE_HOME}/data/warehouse \
        ${HIVE_HOME}/scratch \
        ${HIVE_HOME}/scratch/_resultscache_ \
        /opt/tez-snapshot \
        /opt/hadoop/data/namenode \
        /opt/hadoop/data/datanode \
    && chmod +x /entrypoint.sh /entrypoint-hive.sh \
    && chown -R hive:root ${HIVE_HOME} /home/hive \
    && chown -R root:root /opt/hadoop /opt/tez /opt/tez-snapshot

EXPOSE 10000 10002 9083 8020 9870 8088 8032 8042

ENTRYPOINT ["bash", "-c", "/entrypoint.sh"]

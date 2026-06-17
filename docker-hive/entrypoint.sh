#!/bin/bash
# Hive cluster entrypoint – dispatches to the correct daemon based on SERVICE_NAME.
set -e

SERVICE_NAME="${SERVICE_NAME:-hiveserver2}"
export HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
export TEZ_HOME="${TEZ_HOME:-/opt/tez}"
export HIVE_HOME="${HIVE_HOME:-/opt/hive}"
export JAVA_HOME="${JAVA_HOME:-/opt/java/openjdk}"

log() { echo "[entrypoint] $(date '+%H:%M:%S') $*"; }

case "${SERVICE_NAME}" in
  namenode)
    log "Service: HDFS NameNode"
    if [ ! -f "/opt/hadoop/data/namenode/current/VERSION" ]; then
      log "Formatting HDFS NameNode (first start)..."
      "${HADOOP_HOME}/bin/hdfs" namenode -format -force -nonInteractive
    fi
    exec "${HADOOP_HOME}/bin/hdfs" namenode
    ;;
  datanode)
    log "Service: HDFS DataNode"
    exec "${HADOOP_HOME}/bin/hdfs" datanode
    ;;
  resourcemanager)
    log "Service: YARN ResourceManager"
    exec "${HADOOP_HOME}/bin/yarn" resourcemanager
    ;;
  nodemanager)
    log "Service: YARN NodeManager"
    exec "${HADOOP_HOME}/bin/yarn" nodemanager
    ;;
  metastore|hiveserver2)
    log "Service: Hive ${SERVICE_NAME}"
    exec /entrypoint-hive.sh
    ;;
  *)
    echo "ERROR: Unknown SERVICE_NAME='${SERVICE_NAME}'"
    echo "Valid: namenode | datanode | resourcemanager | nodemanager | metastore | hiveserver2"
    exit 1
    ;;
esac

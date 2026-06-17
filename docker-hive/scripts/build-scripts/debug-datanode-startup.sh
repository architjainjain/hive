#!/usr/bin/env bash
# =============================================================================
# debug-datanode-startup.sh - Debug DataNode startup issues
#
# Usage: ./debug-datanode-startup.sh [datanode_number]
# Example: ./debug-datanode-startup.sh 1
#          ./debug-datanode-startup.sh 2
# =============================================================================
set -euo pipefail

DATANODE_NUM="${1:-1}"
if [[ "${DATANODE_NUM}" == "1" ]]; then
  CONTAINER="hive-local-datanode"
else
  CONTAINER="hive-local-datanode${DATANODE_NUM}"
fi

BOLD='\033[1m'; RESET='\033[0m'
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; DIM='\033[2m'

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     DataNode ${DATANODE_NUM} Debug Report                           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo

# Check if container exists
if ! docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER}$"; then
  echo -e "${RED}✗ Container ${CONTAINER} does not exist${RESET}"
  echo
  echo "Available containers:"
  docker ps -a --filter "name=hive-local" --format "  {{.Names}}" | head -10
  exit 1
fi

# Container status
echo -e "${BOLD}[1] Container Status${RESET}"
STATUS=$(docker inspect "${CONTAINER}" --format '{{.State.Status}}' 2>/dev/null)
HEALTH=$(docker inspect "${CONTAINER}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")
STARTED=$(docker inspect "${CONTAINER}" --format '{{.State.StartedAt}}' 2>/dev/null)
echo "  Status:      ${STATUS}"
echo "  Health:      ${HEALTH}"
echo "  Started:     ${STARTED}"
echo

# Environment variables
echo -e "${BOLD}[2] Environment Variables${RESET}"
docker inspect "${CONTAINER}" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E "SERVICE_NAME|HADOOP_HOME|JAVA_HOME" | sed 's/^/  /'
echo

# Network connectivity
echo -e "${BOLD}[3] Network Connectivity${RESET}"
if [[ "${STATUS}" == "running" ]]; then
  echo -n "  Ping NameNode: "
  if docker exec "${CONTAINER}" ping -c 1 -W 2 namenode >/dev/null 2>&1; then
    echo -e "${GREEN}OK${RESET}"
  else
    echo -e "${RED}FAILED${RESET}"
  fi

  echo -n "  NameNode RPC (8020): "
  if docker exec "${CONTAINER}" nc -z namenode 8020 2>/dev/null; then
    echo -e "${GREEN}OK${RESET}"
  else
    echo -e "${RED}FAILED${RESET}"
  fi

  echo -n "  NameNode HTTP (9870): "
  if docker exec "${CONTAINER}" curl -sf http://namenode:9870/ >/dev/null 2>&1; then
    echo -e "${GREEN}OK${RESET}"
  else
    echo -e "${RED}FAILED${RESET}"
  fi
else
  echo -e "  ${DIM}Container not running${RESET}"
fi
echo

# DataNode process
echo -e "${BOLD}[4] DataNode Process${RESET}"
if [[ "${STATUS}" == "running" ]]; then
  if docker exec "${CONTAINER}" pgrep -f "org.apache.hadoop.hdfs.server.datanode.DataNode" >/dev/null 2>&1; then
    PID=$(docker exec "${CONTAINER}" pgrep -f "org.apache.hadoop.hdfs.server.datanode.DataNode" | head -1)
    echo -e "  ${GREEN}✓${RESET} DataNode process running (PID: ${PID})"
  else
    echo -e "  ${RED}✗${RESET} DataNode process NOT found"
  fi
else
  echo -e "  ${DIM}Container not running${RESET}"
fi
echo

# HTTP endpoint test
echo -e "${BOLD}[5] HTTP Endpoint (localhost:9864)${RESET}"
if [[ "${STATUS}" == "running" ]]; then
  echo -n "  Listening on port 9864: "
  if docker exec "${CONTAINER}" netstat -tuln 2>/dev/null | grep -q ":9864 " || \
     docker exec "${CONTAINER}" ss -tuln 2>/dev/null | grep -q ":9864 "; then
    echo -e "${GREEN}YES${RESET}"
  else
    echo -e "${RED}NO${RESET}"
  fi

  echo -n "  HTTP GET /: "
  if docker exec "${CONTAINER}" curl -sf http://localhost:9864/ >/dev/null 2>&1; then
    echo -e "${GREEN}SUCCESS${RESET}"
    curl_time=$(docker exec "${CONTAINER}" bash -c "time curl -sf http://localhost:9864/ >/dev/null 2>&1" 2>&1 | grep real || echo "")
    [[ -n "${curl_time}" ]] && echo "    Response time: ${curl_time}"
  else
    echo -e "${RED}FAILED${RESET}"
    echo "    Testing with verbose output:"
    docker exec "${CONTAINER}" curl -v http://localhost:9864/ 2>&1 | head -20 | sed 's/^/      /'
  fi
else
  echo -e "  ${DIM}Container not running${RESET}"
fi
echo

# Disk space
echo -e "${BOLD}[6] Disk Space${RESET}"
if [[ "${STATUS}" == "running" ]]; then
  docker exec "${CONTAINER}" df -h /opt/hadoop/data/datanode 2>/dev/null | sed 's/^/  /' || \
    echo -e "  ${YELLOW}Could not check disk space${RESET}"
else
  echo -e "  ${DIM}Container not running${RESET}"
fi
echo

# Recent logs (last 50 lines)
echo -e "${BOLD}[7] Recent Logs (last 50 lines)${RESET}"
echo -e "${DIM}──────────────────────────────────────────────────────${RESET}"
docker logs "${CONTAINER}" 2>&1 | tail -50
echo -e "${DIM}──────────────────────────────────────────────────────${RESET}"
echo

# Error summary
echo -e "${BOLD}[8] Error Summary${RESET}"
error_count=$(docker logs "${CONTAINER}" 2>&1 | grep -ci "error\|exception\|fatal" || echo "0")
if [[ "${error_count}" -gt 0 ]]; then
  echo -e "  ${YELLOW}Found ${error_count} error/exception/fatal messages${RESET}"
  echo -e "  ${DIM}Most recent errors:${RESET}"
  docker logs "${CONTAINER}" 2>&1 | grep -i "error\|exception\|fatal" | tail -5 | sed 's/^/    /'
else
  echo -e "  ${GREEN}✓${RESET} No errors found"
fi
echo

# Healthcheck history
echo -e "${BOLD}[9] Healthcheck History${RESET}"
docker inspect "${CONTAINER}" --format '{{range .State.Health.Log}}  {{.Start}} - Exit: {{.ExitCode}}{{println}}{{end}}' 2>/dev/null | tail -10 || \
  echo "  No healthcheck history"
echo

# Summary and recommendations
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     Recommendations                                   ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"

if [[ "${STATUS}" != "running" ]]; then
  echo "  • Container is not running. Start it with:"
  echo "    docker compose -f docker-compose.yml up -d"
elif [[ "${HEALTH}" == "unhealthy" ]]; then
  echo "  • Container is unhealthy. Check logs for errors:"
  echo "    docker logs ${CONTAINER} | less"
  echo "  • Try restarting:"
  echo "    docker restart ${CONTAINER}"
elif [[ "${HEALTH}" == "starting" ]]; then
  echo "  • Container is still starting. Wait a bit more."
  echo "  • Monitor with: watch 'docker ps --filter name=${CONTAINER}'"
else
  echo -e "  ${GREEN}✓${RESET} Container appears healthy"
fi

echo
echo -e "${DIM}Full logs: docker logs ${CONTAINER} | less${RESET}"
echo -e "${DIM}Follow logs: docker logs -f ${CONTAINER}${RESET}"
echo -e "${DIM}Shell access: docker exec -it ${CONTAINER} bash${RESET}"
echo


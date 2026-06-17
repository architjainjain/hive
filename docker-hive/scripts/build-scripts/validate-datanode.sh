#!/usr/bin/env bash
# =============================================================================
# validate-datanode.sh - Quick DataNode health validation script
#
# Usage: ./validate-datanode.sh
# =============================================================================
set -euo pipefail

BOLD='\033[1m'; RESET='\033[0m'
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; DIM='\033[2m'

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     DataNode Health Validation                       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo

# Check if containers are running
echo -e "${BOLD}[1/5] Container Status${RESET}"
for i in "" 2 3; do
  container="hive-local-datanode${i}"
  if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
    status=$(docker inspect "${container}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")
    if [[ "${status}" == "healthy" ]]; then
      echo -e "  ${GREEN}✓${RESET}  ${container} - ${GREEN}healthy${RESET}"
    elif [[ "${status}" == "starting" ]]; then
      echo -e "  ${YELLOW}⏳${RESET}  ${container} - ${YELLOW}starting${RESET}"
    elif [[ "${status}" == "unhealthy" ]]; then
      echo -e "  ${RED}✗${RESET}  ${container} - ${RED}unhealthy${RESET}"
    else
      echo -e "  ${YELLOW}?${RESET}  ${container} - ${DIM}${status}${RESET}"
    fi
  else
    echo -e "  ${RED}✗${RESET}  ${container} - ${RED}NOT RUNNING${RESET}"
  fi
done
echo

# Check DataNode HTTP endpoints
echo -e "${BOLD}[2/5] HTTP Endpoints (port 9864)${RESET}"
for i in "" 2 3; do
  container="hive-local-datanode${i}"
  if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
    if docker exec "${container}" curl -sf http://localhost:9864/ >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${RESET}  ${container} - HTTP OK"
    else
      echo -e "  ${RED}✗${RESET}  ${container} - HTTP FAILED"
    fi
  else
    echo -e "  ${DIM}⊘${RESET}  ${container} - ${DIM}(not running)${RESET}"
  fi
done
echo

# Check NameNode connectivity from DataNodes
echo -e "${BOLD}[3/5] NameNode Connectivity${RESET}"
for i in "" 2 3; do
  container="hive-local-datanode${i}"
  if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
    if docker exec "${container}" ping -c 1 -W 2 namenode >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${RESET}  ${container} → namenode - REACHABLE"
    else
      echo -e "  ${RED}✗${RESET}  ${container} → namenode - UNREACHABLE"
    fi
  else
    echo -e "  ${DIM}⊘${RESET}  ${container} - ${DIM}(not running)${RESET}"
  fi
done
echo

# Check HDFS report from NameNode
echo -e "${BOLD}[4/5] HDFS Cluster Report${RESET}"
if docker ps --format "{{.Names}}" | grep -q "^hive-local-namenode$"; then
  echo -e "${DIM}  Running: hdfs dfsadmin -report${RESET}"
  report=$(docker exec hive-local-namenode hdfs dfsadmin -report 2>/dev/null | grep "Live datanodes" || echo "")
  if [[ -n "${report}" ]]; then
    echo "  ${report}" | sed "s/Live datanodes/${GREEN}Live datanodes${RESET}/"

    # Extract count
    count=$(echo "${report}" | grep -o "[0-9]\+" | head -1)
    if [[ "${count}" == "3" ]]; then
      echo -e "  ${GREEN}✓${RESET}  All 3 DataNodes registered"
    else
      echo -e "  ${YELLOW}⚠${RESET}  Only ${count}/3 DataNodes registered"
    fi
  else
    echo -e "  ${RED}✗${RESET}  Could not get HDFS report"
  fi
else
  echo -e "  ${RED}✗${RESET}  NameNode not running"
fi
echo

# Check DataNode logs for errors
echo -e "${BOLD}[5/5] Recent Errors in Logs${RESET}"
has_errors=false
for i in "" 2 3; do
  container="hive-local-datanode${i}"
  if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
    errors=$(docker logs "${container}" 2>&1 | grep -i "error\|exception\|fatal" | tail -3 || echo "")
    if [[ -n "${errors}" ]]; then
      echo -e "  ${YELLOW}⚠${RESET}  ${container}:"
      echo "${errors}" | sed 's/^/      /'
      has_errors=true
    fi
  fi
done
if [[ "${has_errors}" == "false" ]]; then
  echo -e "  ${GREEN}✓${RESET}  No recent errors found"
fi
echo

# Summary
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
running=$(docker ps --filter "name=hive-local-datanode" --format "{{.Names}}" | wc -l | tr -d ' ')
healthy=$(docker ps --filter "name=hive-local-datanode" --filter "health=healthy" --format "{{.Names}}" | wc -l | tr -d ' ')

if [[ "${healthy}" == "3" ]]; then
  echo -e "${BOLD}${GREEN}║   ✓  ALL DATANODES HEALTHY (${healthy}/3)                  ║${RESET}"
elif [[ "${running}" == "3" ]]; then
  echo -e "${BOLD}${YELLOW}║   ⏳  DATANODES STARTING (${healthy}/3 healthy)            ║${RESET}"
else
  echo -e "${BOLD}${RED}║   ✗  DATANODES NOT READY (${running}/3 running)          ║${RESET}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo

# Helpful commands
echo -e "${BOLD}Helpful Commands:${RESET}"
echo "  View logs:      docker logs hive-local-datanode | less"
echo "  Restart:        docker compose -f docker-compose.yml restart datanode"
echo "  Full report:    docker exec hive-local-namenode hdfs dfsadmin -report"
echo "  Web UI:         http://localhost:9870 (NameNode)"
echo


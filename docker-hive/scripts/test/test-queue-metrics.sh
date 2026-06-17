#!/usr/bin/env bash
# =============================================================================
# test-queue-metrics.sh  —  Queue Metrics Live Validation (Step 5)
#
# Runs two SEQUENTIAL long-running queries (default queue first, then analytics),
# displays a live scrolling YARN queue metrics dashboard per query, and asserts
# all pass/fail checks.
#
# Prerequisites: cluster must be running
#   (./docker-hive/scripts/build-scripts/deploy.sh or ./docker-hive/scripts/build-scripts/deploy.sh --skip-build)
#
# Usage:
#   ./docker-hive/scripts/test/test-queue-metrics.sh              # create dataset, keep it after test (default)
#   ./docker-hive/scripts/test/test-queue-metrics.sh --no-cleanup # same as default — keep dataset after test
#   ./docker-hive/scripts/test/test-queue-metrics.sh --clean      # create dataset, DROP it after test
#   ./docker-hive/scripts/test/test-queue-metrics.sh --reuse      # reuse existing dataset, keep it after test
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
CLEANUP_MODE="none"
REUSE_DATASET=false

for arg in "$@"; do
  case "$arg" in
    --no-cleanup) CLEANUP_MODE="none"  ;;
    --clean)      CLEANUP_MODE="clean" ;;
    --reuse)      REUSE_DATASET=true   ;;
    --help|-h)
      grep '^# ' "$0" | grep -A20 'Usage:' | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      echo "Valid options: --no-cleanup | --clean | --reuse" >&2
      exit 1
      ;;
  esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; RESET='\033[0m'
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; DIM='\033[2m'

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()      { echo -e "  ${GREEN}✓${RESET}  $*"; }
fail()    { echo -e "\n  ${RED}✗  $*${RESET}" >&2; exit 1; }
substep() { echo -e "  ${BOLD}▸${RESET} $*"; }
sep()     { echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"; }

# ── Check cluster is up ───────────────────────────────────────────────────────
echo
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   Queue Metrics Live Validation                      ║${RESET}"
echo -e "${BOLD}${CYAN}║   Sequential queries · YARN dashboard · Assertions   ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"

# Print active mode
if [[ "${REUSE_DATASET}" == "true" ]]; then
  echo -e "  ${DIM}Mode: --reuse   (skip dataset creation, keep data after test)${RESET}"
elif [[ "${CLEANUP_MODE}" == "clean" ]]; then
  echo -e "  ${DIM}Mode: --clean   (create fresh dataset, DROP after test)${RESET}"
else
  echo -e "  ${DIM}Mode: --no-cleanup (default — create dataset, keep after test)${RESET}"
fi
echo

if ! docker exec hive-local-hiveserver2 nc -z localhost 10000 2>/dev/null; then
  fail "HiveServer2 is not running. Start the cluster first:\n  ./docker-hive/scripts/build-scripts/deploy.sh --skip-build"
fi
ok "Cluster is up — HiveServer2 reachable"
echo

# ── Beeline runner ────────────────────────────────────────────────────────────
blq() {
  local sql="$1"
  docker exec -e TERM=dumb -e BLQ_SQL="${sql}" hive-local-hiveserver2 bash -c '
    export HADOOP_HOME=/opt/hadoop; export HIVE_HOME=/opt/hive
    beeline -u "jdbc:hive2://localhost:10000/" -n root \
      --outputformat=csv2 --silent=true --force=true -e "${BLQ_SQL}" 2>&1
  ' 2>&1 | grep -Ev \
    "SLF4J|Picked up|^26/[0-9]|SocketException|at java\.|TIOStream|NioSocket|ThreadPool|Thread\.run|FutureTask" \
  || true
}

# ── Dataset setup ─────────────────────────────────────────────────────────────
sep
echo -e "${BOLD}${CYAN}  STEP 1: Dataset Preparation${RESET}"
sep

if [[ "${REUSE_DATASET}" == "true" ]]; then
  substep "--reuse: checking existing qmetrics.big ..."
  COUNT_OUT=$(blq "SELECT COUNT(*) FROM qmetrics.big;" 2>&1)
  if echo "${COUNT_OUT}" | grep -qiE "Table not found|Error|FAILED"; then
    fail "qmetrics.big not found. Create it first:\n  ./docker-hive/scripts/test/test-queue-metrics.sh\n  ./docker-hive/scripts/test/test-queue-metrics.sh --no-cleanup"
  fi
  ROW_COUNT=$(echo "${COUNT_OUT}" | grep -Ev "^_c0|^$" | head -1 | tr -d '[:space:]')
  ok "Reusing existing dataset: ${ROW_COUNT} rows in qmetrics.big"
else
  substep "Preparing large dataset (~1M rows) ..."
  blq "DROP DATABASE IF EXISTS qmetrics CASCADE;" >/dev/null
  blq "CREATE DATABASE qmetrics;" >/dev/null
  blq "CREATE TABLE qmetrics.big (id BIGINT, val STRING) STORED AS ORC TBLPROPERTIES ('transactional'='false');" >/dev/null
  blq "INSERT INTO qmetrics.big
    SELECT (a.pos * 1000 + b.pos) AS id,
           CONCAT('row-', CAST(a.pos * 1000 + b.pos AS STRING)) AS val
    FROM (SELECT posexplode(split(space(999), ' '))) a
    CROSS JOIN (SELECT posexplode(split(space(999), ' '))) b;" >/dev/null
  ROW_COUNT=$(blq "SELECT COUNT(*) FROM qmetrics.big;" | grep -Ev "^_c0|^$" | head -1 | tr -d '[:space:]')
  ok "Dataset ready: ${ROW_COUNT} rows in qmetrics.big"
fi
echo

# ── Shared helpers ────────────────────────────────────────────────────────────
LOGDIR=$(mktemp -d /tmp/qmetrics-live-XXXX)
LOG_DEFAULT="${LOGDIR}/default.log"
LOG_ANALYTICS="${LOGDIR}/analytics.log"

strip_cursor() {
  sed 's/\r//g' \
    | sed $'s/\033\\[[0-9]*[ABCDEFGJKSUf]//g' \
    | sed $'s/\033\\[?[0-9]*[hl]//g'
}

# Parse all queue fields in one python3 call.
# Output: one line per queue: "queueName mem_mb vcores apps pending cap"
parse_all_queues() {
  echo "${SCHED_RAW}" | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  qs = d['scheduler']['schedulerInfo']['queues']['queue']
  for q in qs:
    name    = q.get('queueName', '')
    mem     = q.get('resourcesUsed', {}).get('memory', 0)
    vcores  = q.get('resourcesUsed', {}).get('vCores', 0)
    apps    = q.get('numActiveApplications', 0)
    pending = q.get('numPendingApplications', 0)
    cap     = q.get('absoluteCapacity', 0)
    print(name, mem, vcores, apps, pending, cap)
except:
  pass
" 2>/dev/null
}

PANEL_LINES=17
DASHSEP="$(printf '%*s' 94 '' | tr ' ' '-')"

# Print one YARN dashboard row for a queue name
print_yarn_row() {
  local Q="$1" elapsed="$2"
  local ROW MEM_MB VCORES APPS PENDING CAP MEM_GB CAP_PCT
  ROW=$(echo "${QUEUE_DATA}" | awk -v q="${Q}" '$1==q {print}' || true)
  MEM_MB=$(echo "${ROW}" | awk '{print $2+0}' || echo 0)
  VCORES=$(echo "${ROW}" | awk '{print $3+0}' || echo 0)
  APPS=$(echo "${ROW}"   | awk '{print $4+0}' || echo 0)
  PENDING=$(echo "${ROW}" | awk '{print $5+0}' || echo 0)
  CAP=$(echo "${ROW}"    | awk '{print $6+0}' || echo 0)
  MEM_GB=$(awk "BEGIN{printf \"%.2f\", ${MEM_MB:-0}/1024}" || echo "0.00")
  CAP_PCT=$(awk "BEGIN{printf \"%.2f%%\", ${CAP:-0}}" || echo "0.00%")
  if [[ "${APPS:-0}" -gt 0 ]]; then
    printf "  ${GREEN}%-20s  %-6s  %-20s  %-10s  %-10s  %-12s  %-8s${RESET}\n" \
           "root.${Q}" "${elapsed}s" "${MEM_GB} GB" "${VCORES}" "${APPS}" "${CAP_PCT}" "${PENDING}"
  else
    printf "  ${DIM}%-20s  %-6s  %-20s  %-10s  %-10s  %-12s  %-8s${RESET}\n" \
           "root.${Q}" "${elapsed}s" "${MEM_GB} GB" "${VCORES}" "${APPS}" "${CAP_PCT}" "${PENDING}"
  fi
}

# Print beeline panel (appended, not overwritten)
print_panel() {
  local label="$1" file="$2" width=94
  local border
  border=$(printf '%*s' "$((width-4))" '' | tr ' ' '─')
  echo -e "  ${BOLD}${CYAN}┌─ ${label} $(printf '%*s' $((width - ${#label} - 6)) '' | tr ' ' '─')┐${RESET}"
  {
    local raw
    raw=$(cat "${file}" 2>/dev/null | strip_cursor || true)
    echo "${raw}" \
      | grep -E '^-{20,}$|VERTICES.*MODE|Map [0-9]|Reducer [0-9]|VERTICES:.*%|ELAPSED TIME' \
      | tail -n 8 || true
    echo "${raw}" \
      | grep -E '^QUEUE:|^MEMORY:|^CAPACITY:' \
      | tail -n 3 || true
    echo "${raw}" \
      | grep -E '^row-|^val,|rows selected' \
      | tail -n 6 || true
  } \
    | grep -v '^[[:space:]]*$' \
    | head -n "${PANEL_LINES}" \
    | while IFS= read -r line; do
        printf "  │ %-${width}s │\n" "${line:0:${width}}"
      done || true
  echo -e "  ${BOLD}${CYAN}└${border}┘${RESET}"
}

# ── Run one query with a live scrolling dashboard ─────────────────────────────
# Usage: run_query_with_dashboard <queue> <logfile> <duration_file>
# Duration (seconds) is written to <duration_file> when complete.
run_query_with_dashboard() {
  local queue="$1" logfile="$2" dur_file="$3"
  local sql
  sql="SET tez.queue.name=${queue};
SELECT val, COUNT(*) AS cnt, SUM(id) AS total
FROM qmetrics.big
GROUP BY val
ORDER BY total DESC
LIMIT 100;"

  # Print the query
  echo -e "  ${DIM}── Query for [${queue}] ──────────────────────────────────────────────${RESET}"
  echo "${sql}" | sed 's/^/    /'
  echo -e "  ${DIM}────────────────────────────────────────────────────────────────────${RESET}"
  echo

  # Write HQL file into container and launch beeline in background
  : > "${logfile}"
  docker exec -i hive-local-hiveserver2 bash -c "cat > /tmp/q_${queue}.hql" <<< "${sql}"
  docker exec -e TERM=dumb hive-local-hiveserver2 bash -c "
    export HADOOP_HOME=/opt/hadoop; export HIVE_HOME=/opt/hive
    beeline -u 'jdbc:hive2://localhost:10000/' -n root \
      --outputformat=csv2 --silent=false --force=true \
      -f /tmp/q_${queue}.hql 2>&1
  " > "${logfile}" 2>&1 &
  local pid=$!
  echo -e "  ${DIM}PID: ${pid}  log: ${logfile}${RESET}"
  echo

  local T_START poll=0 MAX_POLLS=60
  T_START=$(date +%s)

  while [[ ${poll} -lt ${MAX_POLLS} ]]; do
    local T_NOW elapsed status
    T_NOW=$(date +%s)
    elapsed=$(( T_NOW - T_START ))

    # Check if done
    if ! kill -0 "${pid}" 2>/dev/null; then
      status="DONE"
    else
      status="RUNNING"
    fi

    SCHED_RAW=$(docker exec hive-local-resourcemanager \
      curl -sf "http://localhost:8088/ws/v1/cluster/scheduler" 2>/dev/null) || SCHED_RAW=""
    QUEUE_DATA=$(parse_all_queues) || QUEUE_DATA=""

    # ── YARN dashboard (appended each poll — no overwrite) ─────────────────
    echo -e "  ${BOLD}${CYAN}${DASHSEP}${RESET}"
    printf "  ${BOLD}${CYAN}%-20s  %-6s  %-20s  %-10s  %-10s  %-12s  %-8s${RESET}\n" \
           "QUEUE" "T(s)" "MEMORY (Used/GB)" "VCORES" "APPS" "CAPACITY%" "PENDING"
    echo -e "  ${BOLD}${CYAN}${DASHSEP}${RESET}"
    print_yarn_row "default"   "${elapsed}"
    print_yarn_row "analytics" "${elapsed}"
    echo -e "  ${BOLD}${CYAN}${DASHSEP}${RESET}"
    echo

    # ── Beeline panel ──────────────────────────────────────────────────────
    print_panel "${queue} queue  [${status}]  elapsed=${elapsed}s" "${logfile}"
    echo

    if [[ "${status}" == "DONE" ]]; then
      break
    fi

    poll=$(( poll + 1 ))
    sleep 3
  done

  wait "${pid}" 2>/dev/null || true
  local T_END DURATION
  T_END=$(date +%s)
  DURATION=$(( T_END - T_START ))
  ok "Query [${queue}] completed in ${DURATION}s"
  echo "${DURATION}" > "${dur_file}"
  echo
}

# ── STEP 2: Run default queue query ──────────────────────────────────────────
sep
echo -e "${BOLD}${CYAN}  STEP 2: Query 1 — default queue${RESET}"
sep
echo

DUR_DEFAULT_FILE="${LOGDIR}/dur_default.txt"
run_query_with_dashboard "default" "${LOG_DEFAULT}" "${DUR_DEFAULT_FILE}"
DUR_DEFAULT=$(cat "${DUR_DEFAULT_FILE}" 2>/dev/null || echo 0)

# ── STEP 3: Run analytics queue query ────────────────────────────────────────
sep
echo -e "${BOLD}${CYAN}  STEP 3: Query 2 — analytics queue${RESET}"
sep
echo

DUR_ANALYTICS_FILE="${LOGDIR}/dur_analytics.txt"
run_query_with_dashboard "analytics" "${LOG_ANALYTICS}" "${DUR_ANALYTICS_FILE}"
DUR_ANALYTICS=$(cat "${DUR_ANALYTICS_FILE}" 2>/dev/null || echo 0)

TOTAL_DURATION=$(( DUR_DEFAULT + DUR_ANALYTICS ))

# ── Assertions ────────────────────────────────────────────────────────────────
sep
echo -e "${BOLD}${CYAN}  STEP 4: Assertions${RESET}"
sep
echo

FAIL_COUNT=0

check() {
  local label="$1" result="$2" detail="$3"
  printf "  ${BOLD}▸${RESET}  %-45s " "${label}"
  if [[ "${result}" == "pass" ]]; then
    echo -e "${GREEN}PASS${RESET}  →  ${detail}"
  elif [[ "${result}" == "warn" ]]; then
    echo -e "${YELLOW}WARN${RESET}  →  ${detail}"
  else
    echo -e "${RED}FAIL${RESET}  →  ${detail}"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi
}

# [A] default query result
if grep -qE "^val,|^row-" "${LOG_DEFAULT}" 2>/dev/null; then
  ROWS_D=$(grep -cE "^row-" "${LOG_DEFAULT}" 2>/dev/null || echo 0)
  check "[A] default   query result" "pass" "${ROWS_D} result rows  (${DUR_DEFAULT}s)"
else
  check "[A] default   query result" "fail" "no output in ${LOG_DEFAULT}"
fi

# [B] analytics query result
if grep -qE "^val,|^row-" "${LOG_ANALYTICS}" 2>/dev/null; then
  ROWS_A=$(grep -cE "^row-" "${LOG_ANALYTICS}" 2>/dev/null || echo 0)
  check "[B] analytics query result" "pass" "${ROWS_A} result rows  (${DUR_ANALYTICS}s)"
else
  check "[B] analytics query result" "fail" "no output in ${LOG_ANALYTICS}"
fi

# [C] Queue metrics line in default log
if grep -q "QUEUE:\|MEMORY:" "${LOG_DEFAULT}" 2>/dev/null; then
  check "[C] queue metrics in default log" "pass" "QUEUE: line rendered"
else
  check "[C] queue metrics in default log" "warn" "QUEUE: line not found (may need TTY)"
fi

# [D] Queue metrics line in analytics log
if grep -q "QUEUE:\|MEMORY:" "${LOG_ANALYTICS}" 2>/dev/null; then
  check "[D] queue metrics in analytics log" "pass" "QUEUE: line rendered"
else
  check "[D] queue metrics in analytics log" "warn" "QUEUE: line not found (may need TTY)"
fi

# [E] YARN apps confirmed in root.default
DEF_APPS=$(docker exec hive-local-hiveserver2 bash -c \
  "curl -sf 'http://resourcemanager:8088/ws/v1/cluster/apps?states=FINISHED,RUNNING&queue=root.default' 2>/dev/null | grep -c '\"name\":\"HIVE'" \
  2>/dev/null || echo 0)
if [[ "${DEF_APPS}" -ge 1 ]]; then
  check "[E] YARN apps in root.default" "pass" "${DEF_APPS} HIVE app(s)"
else
  check "[E] YARN apps in root.default" "fail" "no HIVE apps found in root.default"
fi

# [F] YARN apps confirmed in root.analytics
ANA_APPS=$(docker exec hive-local-hiveserver2 bash -c \
  "curl -sf 'http://resourcemanager:8088/ws/v1/cluster/apps?states=FINISHED,RUNNING&queue=root.analytics' 2>/dev/null | grep -c '\"name\":\"HIVE'" \
  2>/dev/null || echo 0)
if [[ "${ANA_APPS}" -ge 1 ]]; then
  check "[F] YARN apps in root.analytics" "pass" "${ANA_APPS} HIVE app(s)"
else
  check "[F] YARN apps in root.analytics" "fail" "no HIVE apps found in root.analytics"
fi

echo

# ── Cleanup ───────────────────────────────────────────────────────────────────
if [[ "${CLEANUP_MODE}" == "clean" ]]; then
  substep "Cleaning up: dropping qmetrics database ..."
  blq "DROP DATABASE IF EXISTS qmetrics CASCADE;" >/dev/null
  ok "qmetrics database dropped"
else
  ok "Dataset kept (qmetrics.big) — re-run with --reuse to skip recreation next time"
fi
rm -rf "${LOGDIR}"

# ── Result ────────────────────────────────────────────────────────────────────
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║   ✓  ALL ASSERTIONS PASSED  (total: ${TOTAL_DURATION}s)$(printf '%*s' $((17 - ${#TOTAL_DURATION})) '')║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
else
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${RED}║   ✗  ${FAIL_COUNT} ASSERTION(S) FAILED                              ║${RESET}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════╝${RESET}"
  exit 1
fi
echo


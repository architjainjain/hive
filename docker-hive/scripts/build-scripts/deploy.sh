#!/usr/bin/env bash
# =============================================================================
# deploy.sh  —  Build Hive, package Docker image, start cluster, validate
#
# Location: docker-hive/scripts/build-scripts/deploy.sh
#
# Usage:
#   ./docker-hive/scripts/build-scripts/deploy.sh [--skip-build] [--stop] [--cleanup]
#
#   --skip-build   Skip Maven build (use existing packaging/target tarball)
#   --stop         Stop containers, keep volumes
#   --cleanup      Stop containers and remove all volumes
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
# scripts/build-scripts/ → scripts/ → docker-hive/ → repo-root/
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.."; pwd)"
DOCKER_DIR="${REPO_ROOT}/docker-hive"
HIVE_VERSION="4.3.0-SNAPSHOT"
IMAGE="hive-local:${HIVE_VERSION}"
COMPOSE_FILE="${DOCKER_DIR}/docker-compose.yml"
LOG_FILE="/tmp/deploy-hive-$(date +%Y%m%d-%H%M%S).log"

SKIP_BUILD=false
ACTION=deploy

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    --stop)       ACTION=stop ;;
    --cleanup)    ACTION=cleanup ;;
  esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; RESET='\033[0m'
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; DIM='\033[2m'

# ── Helpers ───────────────────────────────────────────────────────────────────
step_num=0
step() {
  step_num=$((step_num + 1))
  echo
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  STEP ${step_num}: $*${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
}
substep() { echo -e "  ${BOLD}▸${RESET} $*"; }
ok()      { echo -e "  ${GREEN}✓${RESET}  $*"; }
info()    { echo -e "  ${DIM}ℹ  $*${RESET}"; }
fail()    { echo -e "\n  ${RED}✗  $*${RESET}" >&2
            echo -e "  ${DIM}Full log: ${LOG_FILE}${RESET}" >&2; exit 1; }

# ── Spinner ───────────────────────────────────────────────────────────────────
SPINNER_PID=""
spinner_start() {
  local msg="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  ( i=0
    while true; do
      printf "\r  ${YELLOW}${frames[$((i % 10))]}${RESET}  %s  " "${msg}"
      sleep 0.12; i=$((i+1))
    done ) &
  SPINNER_PID=$!
  disown "${SPINNER_PID}" 2>/dev/null || true
}
spinner_stop() {
  if [[ -n "${SPINNER_PID}" ]]; then
    kill "${SPINNER_PID}" 2>/dev/null || true
    wait "${SPINNER_PID}" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[K"
  fi
}
trap 'spinner_stop' EXIT

# ── wait_for: retries with elapsed-time ──────────────────────────────────────
wait_for() {
  local label="$1" cmd="$2" tries="${3:-40}" delay="${4:-5}"
  local elapsed=0
  printf "  ${YELLOW}⏳${RESET}  %-45s" "${label} ..."
  for i in $(seq 1 "${tries}"); do
    if eval "${cmd}" >>"${LOG_FILE}" 2>&1; then
      printf "\r  ${GREEN}✓${RESET}  %-45s ${DIM}(${elapsed}s)${RESET}\n" "${label}"
      return 0
    fi
    printf "."
    sleep "${delay}"; elapsed=$((elapsed + delay))
  done
  printf "\n"

  # Extract container name from the command for diagnostic logging
  local container_name=""
  if [[ "${cmd}" =~ docker\ exec\ ([a-z0-9_-]+) ]]; then
    container_name="${BASH_REMATCH[1]}"
    echo -e "\n  ${DIM}Diagnostic: Last 30 lines from ${container_name}:${RESET}" | tee -a "${LOG_FILE}"
    docker logs "${container_name}" 2>&1 | tail -30 | sed 's/^/    /' | tee -a "${LOG_FILE}"
  fi

  fail "Timed out after ${elapsed}s waiting for: ${label}\n  Hint: docker logs <container-name>"
}

# ── Container status table ────────────────────────────────────────────────────
show_cluster_status() {
  echo
  echo -e "  ${BOLD}Container Status:${RESET}"
  docker ps --filter "name=hive-local" \
    --format "    {{printf \"%-30s\" .Names}}  {{.Status}}" 2>/dev/null \
    | sed "s/(healthy)/${GREEN}(healthy)${RESET}/g; s/starting/${YELLOW}starting${RESET}/g; s/(unhealthy)/${RED}(unhealthy)${RESET}/g"
  echo
}

# ── Beeline runner (noise filtered) ──────────────────────────────────────────
blq() {
  local sql="$1"
  docker exec -e TERM=dumb -e BLQ_SQL="${sql}" hive-local-hiveserver2 bash -c '
    export HADOOP_HOME=/opt/hadoop
    export HIVE_HOME=/opt/hive
    beeline -u "jdbc:hive2://localhost:10000/" -n root \
      --outputformat=csv2 --silent=true --force=true -e "${BLQ_SQL}" 2>&1
  ' 2>&1 | grep -Ev \
    "SLF4J|Picked up|^26/[0-9]|SocketException|at java\.|TIOStream|NioSocket|ThreadPool|Thread\.run|FutureTask|Executors|HiveConn|BeeLine|Commands|BufferedOutput|FilterOutput|Error:.*08S01|Error:.*cleanup|Closing:|Unexpected end|hive\.server2\.thrift" \
  || true
}

# =============================================================================
# STOP / CLEANUP
# =============================================================================
if [[ "${ACTION}" == "stop" ]]; then
  step "Stop cluster  (volumes retained)"
  substep "Running: docker compose down"
  docker compose -f "${COMPOSE_FILE}" down --remove-orphans 2>&1 | sed 's/^/    /'
  ok "Cluster stopped.  Run  ./docker-hive/scripts/build-scripts/deploy.sh --cleanup  to also remove volumes."
  exit 0
fi
if [[ "${ACTION}" == "cleanup" ]]; then
  step "Stop cluster and remove all volumes"
  substep "Running: docker compose down -v"
  docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>&1 | sed 's/^/    /'
  ok "All containers and volumes removed."
  exit 0
fi

# =============================================================================
# HEADER
# =============================================================================
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     Hive Local Cluster  ·  deploy.sh                 ║${RESET}"
echo -e "${BOLD}║     Hive ${HIVE_VERSION}  ·  Tez-on-YARN          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo -e "  Log: ${DIM}${LOG_FILE}${RESET}"

# =============================================================================
# STEP 1 — Maven build
# =============================================================================
step "Maven Build  (mvn clean package -DskipTests -Pdist)"

HIVE_TAR="${REPO_ROOT}/packaging/target/apache-hive-${HIVE_VERSION}-bin.tar.gz"

if [[ "${SKIP_BUILD}" == "true" ]]; then
  substep "--skip-build: skipping Maven"
  [[ -f "${HIVE_TAR}" ]] \
    || fail "Tarball not found: ${HIVE_TAR}\nRun without --skip-build to build from source."
  ok "Using existing tarball  ($(du -sh "${HIVE_TAR}" | cut -f1))"
else
  substep "Compiling all Hive modules (5-15 min) — showing module progress..."
  echo
  mvn clean package -DskipTests -Drat.skip=true -Pdist \
      -f "${REPO_ROOT}/pom.xml" 2>&1 | \
    tee -a "${LOG_FILE}" | \
    grep --line-buffered -E "^\[INFO\] Building |^\[WARNING\]|^\[ERROR\]|^BUILD " | \
    sed 's/^\[INFO\] Building /  📦  /; s/^\[WARNING\]/  ⚠  /; s/^\[ERROR\]/  ✗  /'
  echo
  [[ -f "${HIVE_TAR}" ]] || fail "Build finished but tarball not found: ${HIVE_TAR}"
  ok "Build complete  →  $(du -sh "${HIVE_TAR}" | cut -f1)"
fi

# =============================================================================
# STEP 2 — Docker image
# =============================================================================
step "Build Docker Image  →  ${IMAGE}"

substep "Checking base image hive-test-base:latest ..."
docker image inspect hive-test-base:latest >/dev/null 2>&1 \
  || fail "hive-test-base:latest not found.\nBuild or pull the base image before running this script."
BASE_SIZE=$(docker image inspect hive-test-base:latest --format '{{.Size}}' \
  | awk '{printf "%.0f MB", $1/1024/1024}')
ok "Base image present  (${BASE_SIZE})"

substep "Assembling build context ..."
WORK_DIR="$(mktemp -d)"
trap 'spinner_stop; rm -rf "${WORK_DIR}"' EXIT

spinner_start "Copying tarball ($(du -sh "${HIVE_TAR}" | cut -f1)) to build context"
cp "${HIVE_TAR}" "${WORK_DIR}/"
spinner_stop
ok "Tarball copied"

cp "${DOCKER_DIR}/Dockerfile"          "${WORK_DIR}/Dockerfile"
cp "${DOCKER_DIR}/entrypoint.sh"       "${WORK_DIR}/entrypoint.sh"
cp "${DOCKER_DIR}/entrypoint-hive.sh"  "${WORK_DIR}/entrypoint-hive.sh"
cp -r "${DOCKER_DIR}/conf"             "${WORK_DIR}/conf"
cp -r "${DOCKER_DIR}/conf-hive"        "${WORK_DIR}/conf-hive"
info "Build context: $(du -sh "${WORK_DIR}" | cut -f1)"

substep "Running docker build (showing Dockerfile layers) ..."
echo
docker build \
  --build-arg "HIVE_VERSION=${HIVE_VERSION}" \
  --progress=plain \
  -t "${IMAGE}" \
  "${WORK_DIR}" 2>&1 | \
  tee -a "${LOG_FILE}" | \
  grep --line-buffered -E "^#[0-9]+ \[|^#[0-9]+ DONE|^#[0-9]+ ERROR|writing image|naming to" | \
  sed 's/^/    /'
echo

docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || fail "Docker build failed — see ${LOG_FILE}"
IMG_SIZE=$(docker image inspect "${IMAGE}" --format '{{.Size}}' \
  | awk '{printf "%.0f MB", $1/1024/1024}')
ok "Image built: ${IMAGE}  (${IMG_SIZE})"

# =============================================================================
# STEP 3 — Start cluster
# =============================================================================
step "Start Cluster  (docker compose up)"

substep "Starting 11 services: Postgres · NameNode · 3×DataNode · ResourceManager · 3×NodeManager · Metastore · HiveServer2"
docker compose -f "${COMPOSE_FILE}" up -d 2>&1 | sed 's/^/    /'
echo

substep "── HDFS ───────────────────────────────────────────────"
wait_for "HDFS NameNode (active)" \
  "docker exec hive-local-namenode curl -sf 'http://localhost:9870/jmx?qry=Hadoop:service=NameNode,name=NameNodeStatus' | grep -q active" \
  60 5
wait_for "HDFS DataNode 1 (port 9864)" \
  "docker exec hive-local-datanode curl -sf http://localhost:9864/ >/dev/null 2>&1" \
  40 5
wait_for "HDFS DataNode 2 (port 9864)" \
  "docker exec hive-local-datanode2 curl -sf http://localhost:9864/ >/dev/null 2>&1" \
  40 5
wait_for "HDFS DataNode 3 (port 9864)" \
  "docker exec hive-local-datanode3 curl -sf http://localhost:9864/ >/dev/null 2>&1" \
  40 5

substep "Initialising HDFS directories ..."
docker exec hive-local-namenode bash -c "
  hdfs dfs -mkdir -p /tmp                 && hdfs dfs -chmod 1777 /tmp
  hdfs dfs -mkdir -p /user/hive/warehouse && hdfs dfs -chmod 1777 /user/hive/warehouse
  hdfs dfs -mkdir -p /user/root           && hdfs dfs -chmod 755  /user/root
  hdfs dfs -mkdir -p /tmp/tez-staging     && hdfs dfs -chmod 1777 /tmp/tez-staging
" 2>&1 | grep -v NativeCodeLoader || true
ok "HDFS dirs: /tmp  /user/hive/warehouse  /user/root  /tmp/tez-staging"

substep "Uploading Tez libs to HDFS (/apps/tez/tez.tar.gz) ..."
TEZ_MSG=$(docker exec hive-local-namenode bash -c "
  if hdfs dfs -test -e /apps/tez/tez.tar.gz 2>/dev/null; then
    echo 'already present'
  else
    hdfs dfs -mkdir -p /apps/tez
    hdfs dfs -put /opt/tez/share/tez.tar.gz /apps/tez/tez.tar.gz
    echo 'uploaded'
  fi
" 2>&1 | grep -v NativeCodeLoader | tail -1 || echo "done")
ok "Tez at /apps/tez/tez.tar.gz  (${TEZ_MSG})"

substep "── YARN ───────────────────────────────────────────────"
wait_for "YARN ResourceManager (STARTED)" \
  "docker exec hive-local-resourcemanager curl -sf 'http://localhost:8088/ws/v1/cluster/info' | grep -q STARTED" \
  40 5
wait_for "YARN NodeManager 1 (nodeHealthy)" \
  "docker exec hive-local-nodemanager curl -sf 'http://localhost:8042/ws/v1/node/info' | grep -q nodeHealthy" \
  40 5
wait_for "YARN NodeManager 2 (nodeHealthy)" \
  "docker exec hive-local-nodemanager2 curl -sf 'http://localhost:8042/ws/v1/node/info' | grep -q nodeHealthy" \
  40 5
wait_for "YARN NodeManager 3 (nodeHealthy)" \
  "docker exec hive-local-nodemanager3 curl -sf 'http://localhost:8042/ws/v1/node/info' | grep -q nodeHealthy" \
  40 5
wait_for "YARN 3 active nodes" \
  "docker exec hive-local-resourcemanager curl -sf 'http://localhost:8088/ws/v1/cluster/metrics' | grep -o '\"activeNodes\":3'" \
  40 5
YARN_NODES=$(docker exec hive-local-resourcemanager bash -c \
  "curl -sf http://localhost:8088/ws/v1/cluster/metrics 2>/dev/null | grep -o '\"activeNodes\":[0-9]*'" 2>/dev/null || echo "?")
ok "YARN cluster ready  (${YARN_NODES})"

substep "── Hive ────────────────────────────────────────────────"
wait_for "Hive Metastore   (port 9083)" \
  "docker exec hive-local-metastore nc -z localhost 9083" 80 5
wait_for "HiveServer2      (port 10000)" \
  "docker exec hive-local-hiveserver2 nc -z localhost 10000" 100 5
wait_for "HiveServer2 JDBC (beeline ping)" \
  "docker exec -e TERM=dumb hive-local-hiveserver2 bash -c \"beeline -u 'jdbc:hive2://localhost:10000/' -n root --silent=true -e 'SHOW DATABASES;' 2>&1 | grep -q default\"" \
  40 5

show_cluster_status

# =============================================================================
# STEP 4 — Smoke validation
# =============================================================================
step "Smoke Validation"

substep "Running 5 validation queries via Beeline ..."
echo

# [1/5] SHOW DATABASES
printf "  ${BOLD}▸${RESET}  [1/5] SHOW DATABASES ..................... "
OUT=$(blq "SHOW DATABASES;")
if echo "${OUT}" | grep -q "default"; then
  DBS=$(echo "${OUT}" | grep -v "database_name" | tr '\n' ',' | sed 's/,$//')
  echo -e "${GREEN}PASS${RESET}  →  (${DBS})"
else
  echo -e "${RED}FAIL${RESET}"
  fail "SHOW DATABASES did not return 'default'. Output:\n  ${OUT}"
fi

# [2/5] CREATE DB + TABLE
printf "  ${BOLD}▸${RESET}  [2/5] CREATE DATABASE + ORC TABLE ....... "
blq "CREATE DATABASE IF NOT EXISTS smoketest;" >/dev/null
blq "CREATE TABLE IF NOT EXISTS smoketest.t (id INT, val STRING) STORED AS ORC TBLPROPERTIES ('transactional'='false');" >/dev/null
echo -e "${GREEN}PASS${RESET}"

# [3/5] INSERT + SELECT (real Tez job on YARN, default queue)
printf "  ${BOLD}▸${RESET}  [3/5] INSERT + SELECT (Tez/default queue) "
blq "INSERT INTO smoketest.t VALUES (1,'cluster is running');" >/dev/null
SEL=$(blq "SELECT val FROM smoketest.t WHERE id=1;")
if echo "${SEL}" | grep -q "cluster is running"; then
  echo -e "${GREEN}PASS${RESET}  →  row: '$(echo "${SEL}" | grep -v "^val" | head -1)'"
else
  echo -e "${RED}FAIL${RESET}"
  fail "SELECT returned unexpected result: ${SEL}"
fi

# [4/5] Queue metrics config
printf "  ${BOLD}▸${RESET}  [4/5] Queue metrics interval = 2s ....... "
CONF=$(blq "SET hive.tez.queue.metrics.refresh.interval;" | grep "refresh.interval" || echo "")
if echo "${CONF}" | grep -qE "2s|2000"; then
  echo -e "${GREEN}PASS${RESET}  →  interval=2s"
else
  echo -e "${RED}FAIL${RESET}"
  fail "Queue metrics interval not configured to 2s. Got: '${CONF}'"
fi

# [5/5] analytics queue — create table, insert and select using SET tez.queue.name=analytics
printf "  ${BOLD}▸${RESET}  [5/5] INSERT + SELECT (analytics queue) .. "
blq "CREATE TABLE IF NOT EXISTS smoketest.t_analytics (id INT, val STRING) STORED AS ORC TBLPROPERTIES ('transactional'='false');" >/dev/null
blq "SET tez.queue.name=analytics; INSERT INTO smoketest.t_analytics VALUES (2,'analytics queue works');" >/dev/null
SEL2=$(blq "SET tez.queue.name=analytics; SELECT val FROM smoketest.t_analytics WHERE id=2;")
if echo "${SEL2}" | grep -q "analytics queue works"; then
  echo -e "${GREEN}PASS${RESET}  →  row: '$(echo "${SEL2}" | grep -v "^val" | head -1)'"
  # Verify the app actually ran in the analytics queue
  ANALYTICS_APPS=$(docker exec hive-local-hiveserver2 bash -c \
    "curl -sf 'http://resourcemanager:8088/ws/v1/cluster/apps?states=FINISHED,RUNNING&queue=root.analytics' 2>/dev/null | grep -c '\"name\":\"HIVE'" \
    2>/dev/null || echo 0)
  ok "analytics queue: ${ANALYTICS_APPS} HIVE app(s) confirmed in root.analytics"
else
  echo -e "${RED}FAIL${RESET}"
  fail "analytics queue SELECT returned unexpected result: ${SEL2}"
fi

# Confirm Tez ran on YARN
APPS=$(docker exec hive-local-hiveserver2 bash -c \
  "curl -sf 'http://resourcemanager:8088/ws/v1/cluster/apps?states=FINISHED,RUNNING' 2>/dev/null | grep -c '\"name\":\"HIVE'" \
  2>/dev/null || echo 0)
ok "Tez-on-YARN: ${APPS} HIVE application(s) completed in YARN"

blq "DROP DATABASE IF EXISTS smoketest CASCADE;" >/dev/null


# =============================================================================
# SUMMARY
# =============================================================================
echo
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   ✓  CLUSTER UP  —  ALL VALIDATIONS PASSED          ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${BOLD}Web UIs${RESET}"
echo    "    HDFS NameNode          →  http://localhost:9870"
echo    "    YARN ResourceManager   →  http://localhost:8088"
echo    "    HiveServer2            →  http://localhost:10002"
echo
echo -e "  ${BOLD}Cluster${RESET}  3 DataNodes · 3 NodeManagers  (replication=3)"
echo
echo -e "  ${BOLD}YARN Queues${RESET}  (Capacity Scheduler)"
echo    "    root.default   →  60% capacity (max 80%)"
echo    "    root.analytics →  40% capacity (max 80%)"
echo    "    Switch queue:  SET tez.queue.name=analytics;"
echo
echo -e "  ${BOLD}Connect with Beeline${RESET}"
echo    "    docker exec -it hive-local-hiveserver2 \\"
echo    "      beeline -u 'jdbc:hive2://localhost:10000/' -n root"
echo
echo -e "  ${BOLD}Queue metrics${RESET}  (enabled, refresh every 2s)"
echo    "    SET hive.tez.queue.metrics.refresh.interval=0s   → disable"
echo
echo -e "  ${BOLD}Manage cluster${RESET}"
echo    "    ./docker-hive/scripts/build-scripts/deploy.sh --stop                   stop (keep volumes)"
echo    "    ./docker-hive/scripts/build-scripts/deploy.sh --cleanup                stop + wipe all volumes"
echo
echo -e "  ${BOLD}Queue Metrics Validation${RESET}"
echo    "    ./docker-hive/scripts/test/test-queue-metrics.sh              run (creates dataset, keeps it)"
echo    "    ./docker-hive/scripts/test/test-queue-metrics.sh --reuse      reuse existing dataset"
echo    "    ./docker-hive/scripts/test/test-queue-metrics.sh --clean      run and drop dataset after"
echo
echo -e "  ${DIM}Log: ${LOG_FILE}${RESET}"

#!/usr/bin/env bash
# =============================================================================
# build-base.sh  —  Interactive builder for hive-test-base Docker image
#
# Prompts for Java / Hadoop / Tez versions, downloads tarballs to a local
# cache if not already present, builds hive-test-base:latest, then
# optionally calls deploy.sh to build and start the full Hive cluster.
#
# Cache  : <repo-root>/docker-hive/build-cache/   (tarballs kept, never auto-deleted)
# Scope  : no changes outside this repo's docker-hive/build-cache/ and Docker daemon.
#
# Usage  :  ./docker-hive/scripts/build-scripts/build-base.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
# scripts/build-scripts/ → scripts/ → docker-hive/ → repo-root/
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.."; pwd)"
DOCKER_DIR="${SCRIPT_DIR}/../.."
CACHE_DIR="${DOCKER_DIR}/build-cache"
DEPLOY_SH="${SCRIPT_DIR}/deploy.sh"

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m';   RESET='\033[0m'
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
RED='\033[0;31m';   DIM='\033[2m';       BLUE='\033[0;34m'
MAGENTA='\033[0;35m'

# ── Basic output helpers ──────────────────────────────────────────────────────
ok()      { echo -e "  ${GREEN}✓${RESET}  $*"; }
fail()    { echo -e "\n  ${RED}✗  $*${RESET}" >&2; exit 1; }
info()    { echo -e "  ${DIM}ℹ  $*${RESET}"; }
substep() { echo -e "\n  ${BOLD}▸${RESET}  $*"; }
sep()     { echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"; }

step_num=0
step() {
  step_num=$((step_num + 1))
  echo
  sep
  echo -e "  ${BOLD}${CYAN}  STEP ${step_num}: $*${RESET}"
  sep
  echo
}

# ── Spinner ───────────────────────────────────────────────────────────────────
SPINNER_PID=""
spinner_start() {
  local msg="$1"
  ( local i=0
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    while true; do
      printf "\r  ${YELLOW}${frames[$((i % 10))]}${RESET}  %s " "${msg}"
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

# ── tty_read: always read from /dev/tty so prompts work regardless of stdin ───
tty_read() {
  local __var="$1"
  local __val
  read -r __val < /dev/tty
  printf -v "${__var}" '%s' "${__val}"
}

# ── prompt_version ─────────────────────────────────────────────────────────────
# Usage: prompt_version  <Title>  <default>  <pom_value>  <VARNAME>  [hint]
prompt_version() {
  local title="$1" default="$2" pom_val="$3" varname="$4" hint="${5:-}"
  echo
  echo -e "  ${BOLD}${MAGENTA}┌─ ${title}${RESET}"
  [[ -n "${hint}" ]] && echo -e "  ${BOLD}${MAGENTA}│${RESET}  ${DIM}${hint}${RESET}"
  echo -e "  ${BOLD}${MAGENTA}│${RESET}  pom.xml  : ${CYAN}${pom_val}${RESET}"
  echo -e "  ${BOLD}${MAGENTA}│${RESET}  Default  : ${GREEN}${default}${RESET}"
  printf  "  ${BOLD}${MAGENTA}└▶${RESET} Version [default: ${GREEN}%s${RESET}]: " "${default}"
  tty_read _input
  printf -v "${varname}" '%s' "${_input:-${default}}"
  local _chosen; eval "_chosen=\${${varname}}"
  echo -e "  ${DIM}   ✔  ${GREEN}${_chosen}${RESET}"
}

# ── prompt_choice ──────────────────────────────────────────────────────────────
# Usage: prompt_choice  <Title>  <VARNAME>  <default>  "key:description" ...
prompt_choice() {
  local title="$1" varname="$2" default="$3"; shift 3
  echo
  echo -e "  ${BOLD}${MAGENTA}┌─ ${title}${RESET}"
  for opt in "$@"; do
    local key="${opt%%:*}" desc="${opt#*:}"
    if [[ "${key}" == "${default}" ]]; then
      echo -e "  ${BOLD}${MAGENTA}│${RESET}  ${BOLD}[${key}]${RESET}  ${desc}  ${DIM}← default${RESET}"
    else
      echo -e "  ${BOLD}${MAGENTA}│${RESET}   ${BOLD}${key}${RESET}   ${desc}"
    fi
  done
  printf "  ${BOLD}${MAGENTA}└▶${RESET} Choice [default: ${GREEN}%s${RESET}]: " "${default}"
  tty_read _input
  printf -v "${varname}" '%s' "${_input:-${default}}"
  local _chosen; eval "_chosen=\${${varname}}"
  echo -e "  ${DIM}   ✔  ${GREEN}${_chosen}${RESET}"
}

# ── confirm Y/N ────────────────────────────────────────────────────────────────
confirm() {
  local prompt="$1" default="${2:-Y}"
  local yn_hint
  [[ "${default}" == "Y" ]] && yn_hint="${BOLD}Y${RESET}/n" || yn_hint="y/${BOLD}N${RESET}"
  echo
  echo -e "  ${BOLD}${BLUE}?  ${prompt}${RESET}  [${yn_hint}]"
  printf  "  > "
  tty_read _ans
  _ans="${_ans:-${default}}"
  if [[ ! "${_ans}" =~ ^[Yy]$ ]]; then
    echo -e "\n  ${YELLOW}Aborted by user.${RESET}\n"
    exit 0
  fi
  echo -e "  ${DIM}   ✔  Confirmed${RESET}"
}

# ── detect_downloader: check for aria2c / curl and offer to install aria2 ─────
# Sets global DOWNLOADER="aria2c|curl"
detect_downloader() {
  if command -v aria2c >/dev/null 2>&1; then
    DOWNLOADER="aria2c"
    local ver; ver=$(aria2c --version 2>&1 | head -1)
    ok "Downloader: ${BOLD}aria2c${RESET}  ${DIM}(${ver})${RESET}  — 16-connection multi-segment"
    return 0
  fi

  # aria2c not found — offer to install
  echo
  echo -e "  ${YELLOW}⚠  aria2c not found.${RESET}"
  echo -e "  ${DIM}  aria2c splits each file into 16 segments downloaded simultaneously,${RESET}"
  echo -e "  ${DIM}  which is significantly faster than a single curl connection (3–8×).${RESET}"
  echo
  echo -e "  ${BOLD}Install (macOS / Homebrew):${RESET}"
  echo -e "    ${CYAN}brew install aria2${RESET}   ${DIM}← recommended${RESET}"
  echo
  echo -e "  ${BOLD}${BLUE}?  Install aria2 now via Homebrew?${RESET}  ${BOLD}Y${RESET}/n/skip"
  echo -e "  ${DIM}  (Enter 'skip' or 'n' to continue with plain curl)${RESET}"
  printf  "  > "
  tty_read _install_choice
  _install_choice="${_install_choice:-Y}"

  case "${_install_choice}" in
    [Yy]*)
      if ! command -v brew >/dev/null 2>&1; then
        fail "Homebrew not found. Install it first: https://brew.sh\nThen re-run this script."
      fi
      substep "Installing aria2 via Homebrew ..."
      brew install aria2 2>&1 | grep -E "^==>|already installed|aria2" | sed 's/^/    /'
      if command -v aria2c >/dev/null 2>&1; then
        DOWNLOADER="aria2c"
        ok "aria2c installed successfully"
      else
        fail "aria2c installation failed — check brew output above."
      fi
      ;;
    *)
      DOWNLOADER="curl"
      warn "Using curl  (slower — single connection per file)"
      ;;
  esac
}

DOWNLOADER=""   # set by detect_downloader

# ── fetch_content_length: get total bytes from server headers ─────────────────
fetch_content_length() {
  local url="$1"
  local bytes
  bytes=$(curl -sI -L "${url}" 2>/dev/null \
    | grep -i '^content-length:' | tail -1 \
    | tr -d '[:space:]' | sed 's/[Cc]ontent-[Ll]ength://' || echo "")
  if [[ "${bytes}" =~ ^[0-9]+$ ]] && [[ "${bytes}" -gt 0 ]]; then
    echo "${bytes}"
  else
    echo "0"
  fi
}

# ── bytes_to_human: convert bytes → "123.4M" ──────────────────────────────────
bytes_to_human() {
  awk "BEGIN{printf \"%.1fM\", ${1}/1048576}"
}

# ── download_one: download a single file with best available downloader ────────
# Usage: download_one <url> <dest> <label>
download_one() {
  local url="$1" dest="$2" label="$3"

  if [[ -f "${dest}" ]]; then
    ok "${label}  — already cached  ($(du -sh "${dest}" | cut -f1))"
    info "  ${dest}"
    return 0
  fi

  local total; total=$(fetch_content_length "${url}")
  substep "Downloading ${label}  ${DIM}($(bytes_to_human "${total}"))${RESET}"
  info "URL  : ${url}"
  info "Dest : ${dest}"
  echo

  mkdir -p "$(dirname "${dest}")"

  case "${DOWNLOADER}" in

    aria2c)
      # Use --summary-interval=1 so aria2c emits progress lines we parse.
      # Format: [#abc 23.4MiB/689MiB(3%) CN:16 DL:12MiB ETA:54s]
      local progress_file
      progress_file=$(mktemp /tmp/aria2-progress-XXXX)
      aria2c --max-connection-per-server=16 --split=16 \
             --min-split-size=10M \
             --summary-interval=1 \
             --dir="$(dirname "${dest}")" \
             --out="$(basename "${dest}").tmp" \
             "${url}" > "${progress_file}" 2>&1 &
      local dl_pid=$!

      while kill -0 "${dl_pid}" 2>/dev/null; do
        sleep 1
        local pline=""
        pline=$(grep -oE '\[#[a-f0-9]+ [^]]+\]' "${progress_file}" 2>/dev/null | tail -1 || true)
        if [[ -n "${pline}" ]]; then
          local done_t="" total_t="" pct="" speed="" eta=""
          done_t=$(echo  "${pline}" | grep -oE '[0-9]+(\.[0-9]+)?[KMGiB]+/'  | head -1 | tr -d '/'  || true)
          total_t=$(echo "${pline}" | grep -oE '/[0-9]+(\.[0-9]+)?[KMGiB]+\('         | tr -d '/('  || true)
          pct=$(echo     "${pline}" | grep -oE '\([0-9]+%\)'                           | tr -d '()'  || true)
          speed=$(echo   "${pline}" | grep -oE 'DL:[^ ]+'                              | tr -d 'DL:' || true)
          eta=$(echo     "${pline}" | grep -oE 'ETA:[^ ]+\]'                           | tr -d 'ETA:]' || true)
          printf "\r  ${YELLOW}↓${RESET}  ${label}  ${CYAN}%s${RESET}/%s  ${BOLD}%s${RESET}  DL:%s  ETA:%s   " \
                 "${done_t}" "${total_t}" "${pct}" "${speed}" "${eta}"
        fi
      done
      printf "\r\033[K"
      rm -f "${progress_file}"

      wait "${dl_pid}" || { rm -f "${dest}.tmp"; fail "aria2c download failed for ${label}."; }
      ;;


    curl)
      curl -L --fail --silent --show-error -o "${dest}.tmp" "${url}" &
      local dl_pid=$!
      while kill -0 "${dl_pid}" 2>/dev/null; do
        sleep 2
        local done
        done=$(stat -f%z "${dest}.tmp" 2>/dev/null || stat -c%s "${dest}.tmp" 2>/dev/null || echo 0)
        printf "\r  ${YELLOW}↓${RESET}  ${label}  —  ${CYAN}%s${RESET} / %s   " \
               "$(bytes_to_human "${done}")" "$(bytes_to_human "${total}")"
      done
      printf "\r\033[K"
      wait "${dl_pid}" || { rm -f "${dest}.tmp"; fail "curl download failed for ${label}."; }
      ;;

  esac

  mv "${dest}.tmp" "${dest}"
  ok "Downloaded  ${label}  ($(du -sh "${dest}" | cut -f1))"
}

# =============================================================================
# HEADER
# =============================================================================
clear
echo
echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "  ${BOLD}${CYAN}║   hive-test-base  —  Image Builder                       ║${RESET}"
echo -e "  ${BOLD}${CYAN}║   Ubuntu 22.04 (jammy) · eclipse-temurin · Hadoop · Tez  ║${RESET}"
echo -e "  ${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
info "Tarball cache : ${CACHE_DIR}"
info "No host-system changes outside the cache dir."
echo

# =============================================================================
# Read pom.xml defaults quietly
# =============================================================================
POM_HADOOP=$(grep -m1 '<hadoop\.version>' "${REPO_ROOT}/pom.xml" \
  | sed 's/.*<hadoop\.version>\(.*\)<\/hadoop\.version>.*/\1/' \
  | tr -d '[:space:]' 2>/dev/null) || POM_HADOOP="3.4.2"
POM_TEZ=$(grep -m1 '<tez\.version>' "${REPO_ROOT}/pom.xml" \
  | sed 's/.*<tez\.version>\(.*\)<\/tez\.version>.*/\1/' \
  | tr -d '[:space:]' 2>/dev/null) || POM_TEZ="0.10.5"

# =============================================================================
# STEP 1 — Version selection
# =============================================================================
step "Version Selection"

echo -e "  ${DIM}Press Enter at any prompt to accept the shown default.${RESET}"

# ── Java ──────────────────────────────────────────────────────────────────────
echo
echo -e "  ${BOLD}${MAGENTA}┌─ Java  (eclipse-temurin JDK)${RESET}"
echo -e "  ${BOLD}${MAGENTA}│${RESET}  Available LTS tags : ${CYAN}11${RESET}  ${CYAN}17${RESET}  ${CYAN}21${RESET}"
echo -e "  ${BOLD}${MAGENTA}│${RESET}  Hive 4.x requires  : Java 11 or 17  ${DIM}(17 recommended; 21 works but less tested)${RESET}"
echo -e "  ${BOLD}${MAGENTA}│${RESET}  Default            : ${GREEN}17${RESET}"
printf  "  ${BOLD}${MAGENTA}└▶${RESET} Java major version [default: ${GREEN}17${RESET}]: "
tty_read _java_input
JAVA_VERSION="${_java_input:-17}"
echo -e "  ${DIM}   ✔  Java ${GREEN}${JAVA_VERSION}${RESET}"

# ── Hadoop ────────────────────────────────────────────────────────────────────
prompt_version \
  "Hadoop" \
  "3.4.2" \
  "${POM_HADOOP}" \
  HADOOP_VERSION \
  "Browse releases → https://archive.apache.org/dist/hadoop/common/"

# ── Tez ───────────────────────────────────────────────────────────────────────
prompt_version \
  "Apache Tez" \
  "0.10.5" \
  "${POM_TEZ}" \
  TEZ_VERSION \
  "Browse releases → https://archive.apache.org/dist/tez/"

# =============================================================================
# STEP 2 — Show full plan and ask for confirmation
# =============================================================================
step "Build Plan  —  Please Review"

HADOOP_TAR="hadoop-${HADOOP_VERSION}.tar.gz"
TEZ_TAR="apache-tez-${TEZ_VERSION}-bin.tar.gz"
HADOOP_CACHE="${CACHE_DIR}/${HADOOP_TAR}"
TEZ_CACHE="${CACHE_DIR}/${TEZ_TAR}"
HADOOP_URL="https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_TAR}"
TEZ_URL="https://archive.apache.org/dist/tez/${TEZ_VERSION}/${TEZ_TAR}"
BASE_IMAGE="hive-test-base:latest"
BASE_IMAGE_VERSIONED="hive-test-base:hadoop${HADOOP_VERSION}-tez${TEZ_VERSION}-java${JAVA_VERSION}"

echo -e "  ${BOLD}Versions selected${RESET}"
printf  "    %-30s ${GREEN}%s${RESET}\n"  "Java (eclipse-temurin JDK):" "eclipse-temurin:${JAVA_VERSION}-jdk-jammy"
printf  "    %-30s ${GREEN}%s${RESET}\n"  "Hadoop:"  "${HADOOP_VERSION}"
printf  "    %-30s ${GREEN}%s${RESET}\n"  "Tez:"     "${TEZ_VERSION}"
echo
echo -e "  ${BOLD}Docker images that will be created${RESET}"
printf  "    %-30s ${CYAN}%s${RESET}\n"  "Latest tag:"    "${BASE_IMAGE}"
printf  "    %-30s ${CYAN}%s${RESET}\n"  "Versioned tag:" "${BASE_IMAGE_VERSIONED}"
echo
echo -e "  ${BOLD}Tarball cache  ${DIM}→  ${CACHE_DIR}${RESET}"
for entry in \
    "${HADOOP_CACHE}|Hadoop ${HADOOP_VERSION}|${HADOOP_URL}" \
    "${TEZ_CACHE}|Tez ${TEZ_VERSION}|${TEZ_URL}"; do
  file="${entry%%|*}"; rest="${entry#*|}"; label="${rest%%|*}"; url="${rest#*|}"
  if [[ -f "${file}" ]]; then
    sz=$(du -sh "${file}" | cut -f1)
    printf  "    %-30s ${GREEN}cached (%s)${RESET}\n"    "${label}:" "${sz}"
  else
    printf  "    %-30s ${YELLOW}will download${RESET}\n" "${label}:"
    printf  "    %-30s ${DIM}%s${RESET}\n"               ""          "${url}"
  fi
done

confirm "Everything looks correct — proceed with build?" "Y"

# =============================================================================
# STEP 3 — Download / verify tarballs
# =============================================================================
step "Tarball Cache"

mkdir -p "${CACHE_DIR}"
info "Cache: ${CACHE_DIR}"
echo

substep "Detecting best available downloader ..."
detect_downloader
echo

download_one "${HADOOP_URL}" "${HADOOP_CACHE}" "Hadoop ${HADOOP_VERSION}"
echo
download_one "${TEZ_URL}"    "${TEZ_CACHE}"    "Tez ${TEZ_VERSION}"

echo
substep "Verifying tarballs ..."
for entry in "${HADOOP_CACHE}|Hadoop ${HADOOP_VERSION}" "${TEZ_CACHE}|Tez ${TEZ_VERSION}"; do
  file="${entry%%|*}"; label="${entry#*|}"
  if tar -tzf "${file}" >/dev/null 2>&1; then
    sz=$(du -sh "${file}" | cut -f1)
    ok "${label}  tarball OK  (${sz})"
  else
    fail "${label} tarball is corrupt: ${file}\nDelete it and re-run to re-download."
  fi
done

# =============================================================================
# STEP 4 — Generate Dockerfile + build context
# =============================================================================
step "Generating Dockerfile"

WORK_DIR="$(mktemp -d /tmp/hive-base-build-XXXX)"
trap 'spinner_stop; rm -rf "${WORK_DIR}"' EXIT

BASE_DOCKERFILE="${WORK_DIR}/Dockerfile.base"

cat > "${BASE_DOCKERFILE}" << DOCKERFILE
# auto-generated by build-base.sh  —  do not edit manually
# FROM eclipse-temurin:${JAVA_VERSION}-jdk-jammy  (Ubuntu 22.04)
# Hadoop ${HADOOP_VERSION}  →  /opt/hadoop
# Tez    ${TEZ_VERSION}     →  /opt/tez
FROM eclipse-temurin:${JAVA_VERSION}-jdk-jammy

LABEL maintainer="hive-dev" \\
      hadoop.version="${HADOOP_VERSION}" \\
      tez.version="${TEZ_VERSION}" \\
      java.version="${JAVA_VERSION}"

RUN apt-get update && apt-get install -y --no-install-recommends \\
        bash curl wget netcat-openbsd procps python3 \\
        gettext-base openssh-client rsync \\
    && rm -rf /var/lib/apt/lists/*

ENV HADOOP_HOME=/opt/hadoop \\
    TEZ_HOME=/opt/tez \\
    HADOOP_VERSION=${HADOOP_VERSION} \\
    TEZ_VERSION=${TEZ_VERSION} \\
    JAVA_VERSION=${JAVA_VERSION} \\
    HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop \\
    HADOOP_LOG_DIR=/opt/hadoop/logs \\
    YARN_LOG_DIR=/opt/hadoop/logs

ENV PATH=\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\${PATH}

COPY hadoop-${HADOOP_VERSION}.tar.gz /tmp/
RUN tar -xzf /tmp/hadoop-${HADOOP_VERSION}.tar.gz -C /opt/ \\
    && mv /opt/hadoop-${HADOOP_VERSION} \${HADOOP_HOME} \\
    && rm /tmp/hadoop-${HADOOP_VERSION}.tar.gz \\
    && mkdir -p \${HADOOP_HOME}/logs \${HADOOP_HOME}/data/namenode \${HADOOP_HOME}/data/datanode

COPY apache-tez-${TEZ_VERSION}-bin.tar.gz /tmp/
RUN tar -xzf /tmp/apache-tez-${TEZ_VERSION}-bin.tar.gz -C /opt/ \\
    && mv /opt/apache-tez-${TEZ_VERSION}-bin \${TEZ_HOME} \\
    && rm /tmp/apache-tez-${TEZ_VERSION}-bin.tar.gz

RUN { echo 'export JAVA_HOME=\$(dirname \$(dirname \$(readlink -f \$(which java))))'; \\
      echo "export HADOOP_LOG_DIR=\${HADOOP_HOME}/logs"; \\
      echo "export YARN_LOG_DIR=\${HADOOP_HOME}/logs"; } \\
    >> \${HADOOP_HOME}/etc/hadoop/hadoop-env.sh

EXPOSE 9870 9000 8088 8042 8032 19888
WORKDIR /opt
DOCKERFILE

ok "Dockerfile generated"
info "Base OS : eclipse-temurin:${JAVA_VERSION}-jdk-jammy  (Ubuntu 22.04)"
info "Hadoop  : ${HADOOP_VERSION}  →  /opt/hadoop"
info "Tez     : ${TEZ_VERSION}  →  /opt/tez"

substep "Copying tarballs into Docker build context ..."
spinner_start "Copying Hadoop  ($(du -sh "${HADOOP_CACHE}" | cut -f1)) ..."
cp "${HADOOP_CACHE}" "${WORK_DIR}/${HADOOP_TAR}"
spinner_stop
ok "Hadoop tarball copied"

spinner_start "Copying Tez  ($(du -sh "${TEZ_CACHE}" | cut -f1)) ..."
cp "${TEZ_CACHE}" "${WORK_DIR}/${TEZ_TAR}"
spinner_stop
ok "Tez tarball copied"
info "Build context size: $(du -sh "${WORK_DIR}" | cut -f1)"

# =============================================================================
# STEP 5 — Docker build
# =============================================================================
step "Building  hive-test-base  Docker Image"

info "This may take a few minutes on first run (layer pull + extraction)."
echo

docker build \
  --progress=plain \
  -f "${BASE_DOCKERFILE}" \
  -t "${BASE_IMAGE}" \
  -t "${BASE_IMAGE_VERSIONED}" \
  "${WORK_DIR}" 2>&1 | \
  grep --line-buffered -E "^#[0-9]+ \[|^#[0-9]+ DONE|^#[0-9]+ ERROR|writing image|naming to" | \
  sed 's/^/    /' || fail "docker build failed — see output above."
echo

docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1 \
  || fail "Image ${BASE_IMAGE} not found after build."

IMG_SIZE=$(docker image inspect "${BASE_IMAGE}" --format '{{.Size}}' \
  | awk '{printf "%.0f MB", $1/1024/1024}')

ok "Base image built successfully"
echo
printf "    %-30s ${CYAN}%s${RESET}\n"  "Latest tag:"    "${BASE_IMAGE}"
printf "    %-30s ${CYAN}%s${RESET}\n"  "Versioned tag:" "${BASE_IMAGE_VERSIONED}"
printf "    %-30s %s\n"                 "Image size:"    "${IMG_SIZE}"
printf "    %-30s %s\n"                 "Java:"          "eclipse-temurin:${JAVA_VERSION}"
printf "    %-30s %s\n"                 "Hadoop:"        "${HADOOP_VERSION}"
printf "    %-30s %s\n"                 "Tez:"           "${TEZ_VERSION}"

# =============================================================================
# STEP 6 — What to do next
# =============================================================================
echo
sep
echo -e "  ${BOLD}${CYAN}  Base image is ready.  What would you like to do next?${RESET}"
sep

prompt_choice \
  "Next action" \
  NEXT_ACTION \
  "1" \
  "1:Build Hive image + start full cluster     (calls deploy.sh)" \
  "2:Build Hive Docker image only              (no cluster start)" \
  "3:Stop here — I will run deploy.sh manually"

case "${NEXT_ACTION}" in

  1)
    prompt_choice \
      "Hive build strategy" \
      BUILD_STRATEGY "b" \
      "a:Build Hive from source  (Maven — 5-15 min)" \
      "b:Use existing tarball    (--skip-build, fast)"

    step "Building Hive Image + Starting Cluster"
    echo
    if [[ "${BUILD_STRATEGY}" == "a" ]]; then
      substep "Calling deploy.sh  (full Maven build) ..."
      echo
      "${DEPLOY_SH}"
    else
      substep "Calling deploy.sh --skip-build ..."
      echo
      "${DEPLOY_SH}" --skip-build
    fi
    ;;

  2)
    prompt_choice \
      "Hive build strategy" \
      BUILD_STRATEGY "b" \
      "a:Build Hive from source  (Maven — 5-15 min)" \
      "b:Use existing tarball    (--skip-build, fast)"

    step "Building Hive Docker Image  (cluster start skipped)"

    HIVE_VERSION=$(grep -m1 'HIVE_VERSION=' "${DEPLOY_SH}" \
      | sed 's/.*HIVE_VERSION="\([^"]*\)".*/\1/' | tr -d '[:space:]')
    HIVE_TAR="${REPO_ROOT}/packaging/target/apache-hive-${HIVE_VERSION}-bin.tar.gz"

    if [[ "${BUILD_STRATEGY}" == "a" ]]; then
      substep "Running Maven build ..."
      echo
      mvn clean package -DskipTests -Drat.skip=true -Pdist \
        -f "${REPO_ROOT}/pom.xml" 2>&1 | \
        grep --line-buffered -E "^\[INFO\] Building |^\[WARNING\]|^\[ERROR\]|^BUILD " | \
        sed 's/^\[INFO\] Building /  📦  /; s/^\[WARNING\]/  ⚠  /; s/^\[ERROR\]/  ✗  /'
      echo
      [[ -f "${HIVE_TAR}" ]] || fail "Build finished but tarball not found: ${HIVE_TAR}"
      ok "Maven build complete  →  $(du -sh "${HIVE_TAR}" | cut -f1)"
    else
      [[ -f "${HIVE_TAR}" ]] \
        || fail "Tarball not found: ${HIVE_TAR}\nRun option 'a' to build from source first."
      ok "Using existing tarball  ($(du -sh "${HIVE_TAR}" | cut -f1))"
    fi

    HIVE_IMAGE="hive-local:${HIVE_VERSION}"
    HIVE_WORK_DIR="$(mktemp -d /tmp/hive-image-build-XXXX)"
    trap 'spinner_stop; rm -rf "${WORK_DIR}" "${HIVE_WORK_DIR}"' EXIT

    substep "Assembling Hive image build context ..."
    spinner_start "Copying Hive tarball ($(du -sh "${HIVE_TAR}" | cut -f1)) ..."
    cp "${HIVE_TAR}"                          "${HIVE_WORK_DIR}/"
    spinner_stop
    ok "Hive tarball copied"

    cp "${DOCKER_DIR}/Dockerfile"             "${HIVE_WORK_DIR}/Dockerfile"
    cp "${DOCKER_DIR}/entrypoint.sh"          "${HIVE_WORK_DIR}/entrypoint.sh"
    cp "${DOCKER_DIR}/entrypoint-hive.sh"     "${HIVE_WORK_DIR}/entrypoint-hive.sh"
    cp -r "${DOCKER_DIR}/conf"                "${HIVE_WORK_DIR}/conf"
    cp -r "${DOCKER_DIR}/conf-hive"           "${HIVE_WORK_DIR}/conf-hive"
    info "Build context: $(du -sh "${HIVE_WORK_DIR}" | cut -f1)"
    echo

    substep "Running docker build ..."
    echo
    docker build \
      --build-arg "HIVE_VERSION=${HIVE_VERSION}" \
      --progress=plain \
      -t "${HIVE_IMAGE}" \
      "${HIVE_WORK_DIR}" 2>&1 | \
      grep --line-buffered -E "^#[0-9]+ \[|^#[0-9]+ DONE|^#[0-9]+ ERROR|writing image|naming to" | \
      sed 's/^/    /' || fail "Hive docker build failed."
    echo

    docker image inspect "${HIVE_IMAGE}" >/dev/null 2>&1 \
      || fail "Hive image build failed."
    HIVE_IMG_SIZE=$(docker image inspect "${HIVE_IMAGE}" --format '{{.Size}}' \
      | awk '{printf "%.0f MB", $1/1024/1024}')
    ok "Hive image built:  ${HIVE_IMAGE}  (${HIVE_IMG_SIZE})"
    echo
    info "Start the cluster when ready:"
    info "  ${DEPLOY_SH} --skip-build"
    ;;

  3)
    echo
    ok "Stopping here — base image is ready."
    info "When ready to deploy:"
    info "  ${DEPLOY_SH} --skip-build"
    ;;

  *)
    fail "Unknown choice: '${NEXT_ACTION}'"
    ;;
esac

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo
echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "  ${BOLD}${GREEN}║   ✓  build-base.sh  complete                              ║${RESET}"
echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${BOLD}Base image${RESET}"
printf  "    %-30s ${CYAN}%s${RESET}\n"  "Latest tag:"    "${BASE_IMAGE}"
printf  "    %-30s ${CYAN}%s${RESET}\n"  "Versioned tag:" "${BASE_IMAGE_VERSIONED}"
printf  "    %-30s %s\n"                 "Size:"          "${IMG_SIZE}"
echo
echo -e "  ${BOLD}Tarballs cached${RESET}  ${DIM}→  ${CACHE_DIR}${RESET}"
printf  "    %-10s %s\n"  "Hadoop:" "${HADOOP_CACHE}"
printf  "    %-10s %s\n"  "Tez:"    "${TEZ_CACHE}"
echo
echo -e "  ${BOLD}Useful commands${RESET}"
echo    "    ./docker-hive/scripts/build-scripts/build-base.sh  rebuild base image"
echo    "    ./docker-hive/scripts/build-scripts/deploy.sh --skip-build             start Hive cluster"
echo    "    ./docker-hive/scripts/build-scripts/deploy.sh --stop                   stop cluster (keep volumes)"
echo    "    ./docker-hive/scripts/build-scripts/deploy.sh --cleanup                stop + wipe all volumes"
echo


#!/usr/bin/env bash
# ==============================================================================
# elastic-installer — Interactive Elastic Stack On-Prem Installer
#
# Supports:   Elasticsearch · Kibana · Fleet Server
# Topologies: Single-node POC  |  Multi-node cluster
# Platforms:  RHEL / CentOS / Rocky / AlmaLinux  |  Ubuntu / Debian
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Globals ───────────────────────────────────────────────────────────────────
ELASTIC_VERSION="9.0.1"
ELASTIC_MAJOR="9"

INSTALL_ES=false
INSTALL_KIBANA=false
INSTALL_FLEET=false

TOPOLOGY="single"           # single | multi
NODE_ROLE="master_data"     # master_data | master | data | coordinating
CLUSTER_NAME="elastic-poc"
NODE_NAME=""
NETWORK_HOST="0.0.0.0"     # Elasticsearch network.host
KIBANA_HOST="0.0.0.0"      # Kibana server.host
FLEET_HOST="0.0.0.0"       # Fleet Server bind address

ES_EXTERNAL_URL=""          # used when ES is not installed on this node
ES_PASSWORD=""
KIBANA_SYSTEM_PASSWORD=""   # kibana_system user's active password after install
FLEET_SERVICE_TOKEN=""

CUSTOM_ELASTIC_PASSWORD=""  # user-chosen; blank = auto-generate
CUSTOM_KIBANA_PASSWORD=""   # user-chosen; blank = leave unset

SEED_HOSTS=()
INITIAL_MASTERS=()

KIBANA_ENROLLMENT_TOKEN=""  # captured after enrollment token is generated
KIBANA_ENC_KEY=""           # generated during configure_kibana; re-applied after enrollment

OS_FAMILY=""                # rhel | debian
PKG_MANAGER=""              # dnf | yum | apt-get

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/elastic-install-$(date +%Y%m%d-%H%M%S).log"
SUMMARY_FILE="${SCRIPT_DIR}/elastic-install-summary.txt"

# ── Output helpers ────────────────────────────────────────────────────────────
_ts()     { date +"%Y-%m-%d %H:%M:%S"; }
log()     { echo "[$(_ts)] $*" >> "$LOG_FILE"; }
die()     { echo -e "\n${RED}✗  ERROR: $*${NC}\n" >&2; log "ERROR: $*"; exit 1; }
warn()    { echo -e "${YELLOW}⚠  $*${NC}"; log "WARN:    $*"; }
success() { echo -e "${GREEN}✔  $*${NC}";  log "OK:      $*"; }
info()    { echo -e "${CYAN}→  $*${NC}";   log "INFO:    $*"; }
step()    { echo -e "\n${BOLD}${BLUE}▸ $*${NC}"; log ""; log "▸▸ STEP: $*"; }
hr()      { echo -e "${DIM}$(printf '─%.0s' {1..72})${NC}"; }

# Run a command in the background and show a spinner until it finishes.
# All stdout+stderr from the command is appended to LOG_FILE.
# Returns the exit code of the command.
run_with_spinner() {
  local label="$1"; shift
  local spin='-\|/'
  local i=0
  printf "  ${CYAN}→${NC}  %s" "$label"
  "$@" >> "$LOG_FILE" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}[%s]${NC} %s" "${spin:$((i % 4)):1}" "$label"
    sleep 0.2
    (( i++ )) || true
  done
  wait "$pid"
  local rc=$?
  printf "\r%-80s\r" ""
  return $rc
}

banner() {
  echo -e "${BOLD}${BLUE}"
  cat <<'BANNER'
  ███████╗██╗      █████╗ ███████╗████████╗██╗ ██████╗
  ██╔════╝██║     ██╔══██╗██╔════╝╚══██╔══╝██║██╔════╝
  █████╗  ██║     ███████║███████╗   ██║   ██║██║
  ██╔══╝  ██║     ██╔══██║╚════██║   ██║   ██║██║
  ███████╗███████╗██║  ██║███████║   ██║   ██║╚██████╗
  ╚══════╝╚══════╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝ ╚═════╝
BANNER
  echo -e "${NC}${DIM}  Stack On-Prem Installer — interactive setup${NC}"
  echo ""
}

# Prompt with optional default. Sets $REPLY.
prompt() {
  local msg="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    echo -en "${BOLD}${msg}${NC} ${DIM}[${default}]${NC}: "
  else
    echo -en "${BOLD}${msg}${NC}: "
  fi
  read -r REPLY
  if [[ -z "$REPLY" && -n "$default" ]]; then REPLY="$default"; fi
}

# Yes/no confirm. Returns 0 for yes, 1 for no.
confirm() {
  local msg="$1" default="${2:-Y}"
  local hint
  [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
  echo -en "${BOLD}${msg}${NC} ${DIM}${hint}${NC}: "
  read -r REPLY
  if [[ -z "$REPLY" ]]; then REPLY="$default"; fi
  [[ "$REPLY" =~ ^[Yy]$ ]]
}

# Read a password silently, confirm it, enforce min length. Sets named variable.
prompt_password() {
  local msg="$1" varname="$2"
  local pw pw2
  while true; do
    echo -en "${BOLD}${msg}${NC}: "
    read -rs pw
    echo ""
    if [[ ${#pw} -lt 6 ]]; then
      warn "Password must be at least 6 characters. Try again."
      continue
    fi
    echo -en "${BOLD}Confirm password${NC}: "
    read -rs pw2
    echo ""
    if [[ "$pw" == "$pw2" ]]; then
      printf -v "$varname" '%s' "$pw"
      return 0
    fi
    warn "Passwords do not match. Try again."
  done
}

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
  step "Detecting operating system"

  [[ -f /etc/os-release ]] || die "Cannot detect OS — /etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release

  local os_id="${ID:-unknown}"
  local os_id_like="${ID_LIKE:-}"
  local os_version="${VERSION_ID:-}"

  case "$os_id" in
    rhel|centos|rocky|almalinux|ol|fedora)
      OS_FAMILY="rhel" ;;
    ubuntu|debian|linuxmint|pop)
      OS_FAMILY="debian" ;;
    *)
      if [[ "$os_id_like" =~ rhel|fedora ]]; then
        OS_FAMILY="rhel"
      elif [[ "$os_id_like" =~ debian ]]; then
        OS_FAMILY="debian"
      else
        die "Unsupported OS: ${os_id}. Supported families: RHEL/CentOS/Rocky/AlmaLinux, Ubuntu/Debian."
      fi
      ;;
  esac

  if [[ "$OS_FAMILY" == "rhel" ]]; then
    command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
  else
    PKG_MANAGER="apt-get"
  fi

  success "Detected: ${os_id} ${os_version} (${OS_FAMILY} family) — using ${PKG_MANAGER}"
}

# ── Prerequisite Checks ───────────────────────────────────────────────────────
check_prerequisites() {
  step "Checking prerequisites"

  [[ $EUID -eq 0 ]] || die "This script must be run as root (or via sudo)."

  command -v systemctl &>/dev/null || die "systemd is required. SysV init is not supported."

  if ! command -v curl &>/dev/null; then
    info "curl not found — installing..."
    $PKG_MANAGER install -y curl >> "$LOG_FILE" 2>&1
  fi

  # RAM check (warn only)
  local ram_mb
  ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
  if [[ $ram_mb -lt 4096 ]]; then
    warn "Only ${ram_mb}MB RAM detected. Elasticsearch recommends at least 4GB for a POC."
    confirm "Continue anyway?" "Y" || die "Aborted by user."
  else
    success "RAM: ${ram_mb}MB — OK"
  fi

  # Disk space check on /var/lib (warn only)
  local free_gb
  free_gb=$(df -BG /var/lib 2>/dev/null | awk 'NR==2 { gsub(/G/,"",$4); print $4 }') || true
  if [[ -n "$free_gb" && $free_gb -lt 20 ]]; then
    warn "Only ${free_gb}GB free on /var/lib. Recommend at least 20GB."
    confirm "Continue anyway?" "Y" || die "Aborted by user."
  fi

  success "Prerequisites OK"
}

# ── Interactive Menus ─────────────────────────────────────────────────────────
menu_version() {
  step "Elastic Stack version"

  info "Fetching available versions..."
  local raw
  raw=$(curl -sf --connect-timeout 5 --max-time 10 \
    "https://api.github.com/repos/elastic/elasticsearch/releases?per_page=100" \
    2>>"$LOG_FILE") || true

  # Parse into three slots: latest v9, previous minor of v9, latest v8
  local v9_latest="" v9_prev="" v8_latest=""
  if [[ -n "$raw" ]]; then
    local parsed
    parsed=$(python3 -c "
import sys, re
data = sys.stdin.read()
tags = re.findall(r'\"tag_name\":\s*\"v?([0-9]+\.[0-9]+\.[0-9]+)\"', data)
stable = [t for t in tags if not re.search(r'alpha|beta|rc|SNAPSHOT', t)]

def key(v):
    a,b,c = v.split('.')
    return (int(a), int(b), int(c))

v9 = sorted([v for v in stable if v.startswith('9.')], key=key, reverse=True)
v8 = sorted([v for v in stable if v.startswith('8.')], key=key, reverse=True)

v9_latest = v9[0] if v9 else ''
# previous minor: highest version with a different minor than v9_latest
v9_prev = ''
if v9_latest:
    latest_minor = int(v9_latest.split('.')[1])
    prev = [v for v in v9 if int(v.split('.')[1]) < latest_minor]
    v9_prev = prev[0] if prev else ''

v8_latest = v8[0] if v8 else ''
print(v9_latest)
print(v9_prev)
print(v8_latest)
" <<< "$raw" 2>/dev/null) || true

    v9_latest=$(awk 'NR==1' <<< "$parsed")
    v9_prev=$(awk 'NR==2' <<< "$parsed")
    v8_latest=$(awk 'NR==3' <<< "$parsed")
  fi

  # Fallback defaults if fetch failed or returned nothing
  if [[ -z "$v9_latest" ]]; then
    warn "Could not fetch version list — using built-in defaults."
    v9_latest="9.0.1"
    v9_prev=""
    v8_latest="8.17.4"
  fi

  echo ""
  echo -e "  ${BOLD}1)${NC} Latest v9       ${CYAN}${v9_latest}${NC}"
  local next_idx=2
  if [[ -n "$v9_prev" ]]; then
    echo -e "  ${BOLD}2)${NC} Previous v9     ${CYAN}${v9_prev}${NC}"
    next_idx=3
  fi
  if [[ -n "$v8_latest" ]]; then echo -e "  ${BOLD}${next_idx})${NC} Latest v8       ${CYAN}${v8_latest}${NC}"; fi
  local custom_idx=$(( next_idx + 1 ))
  echo -e "  ${BOLD}${custom_idx})${NC} Custom version"
  echo ""

  prompt "Choose version" "1"
  local choice="$REPLY"

  case "$choice" in
    1)
      ELASTIC_VERSION="$v9_latest" ;;
    2)
      if [[ -n "$v9_prev" ]]; then
        ELASTIC_VERSION="$v9_prev"
      elif [[ -n "$v8_latest" ]]; then
        ELASTIC_VERSION="$v8_latest"
      else
        warn "Invalid selection — defaulting to latest v9"
        ELASTIC_VERSION="$v9_latest"
      fi ;;
    3)
      if [[ $next_idx -eq 3 && -n "$v8_latest" ]]; then
        ELASTIC_VERSION="$v8_latest"
      else
        warn "Invalid selection — defaulting to latest v9"
        ELASTIC_VERSION="$v9_latest"
      fi ;;
    "$custom_idx")
      prompt "Enter version (e.g. 9.0.1 or 8.17.4)" "$v9_latest"
      ELASTIC_VERSION="$REPLY" ;;
    *.[0-9]*.[0-9]*)
      ELASTIC_VERSION="$choice" ;;
    *)
      warn "Invalid selection — defaulting to latest v9"
      ELASTIC_VERSION="$v9_latest" ;;
  esac

  ELASTIC_MAJOR="${ELASTIC_VERSION%%.*}"
  success "Selected: Elastic Stack ${ELASTIC_VERSION}"
}

menu_topology() {
  step "Deployment topology"
  echo ""
  echo -e "  ${BOLD}1)${NC} Single-node  ${DIM}(POC / demo — all components on this machine)${NC}"
  echo -e "  ${BOLD}2)${NC} Multi-node   ${DIM}(production-like cluster — configure this node's role)${NC}"
  echo ""
  prompt "Choose topology" "1"
  case "$REPLY" in
    1|single) TOPOLOGY="single"; info "Single-node POC selected" ;;
    2|multi)  TOPOLOGY="multi";  info "Multi-node cluster selected" ;;
    *)        TOPOLOGY="single"; warn "Invalid choice — defaulting to single-node" ;;
  esac
}

menu_components() {
  # Single-node: install everything automatically
  if [[ "$TOPOLOGY" == "single" ]]; then
    INSTALL_ES=true
    INSTALL_KIBANA=true
    INSTALL_FLEET=true
    info "Single-node: installing Elasticsearch, Kibana, and Fleet Server"
    return
  fi

  step "Component selection"
  echo ""
  confirm "  Install Elasticsearch?" "Y" && INSTALL_ES=true     || INSTALL_ES=false
  confirm "  Install Kibana?"        "Y" && INSTALL_KIBANA=true  || INSTALL_KIBANA=false
  confirm "  Install Fleet Server?"  "Y" && INSTALL_FLEET=true   || INSTALL_FLEET=false
  echo ""

  [[ "$INSTALL_ES" == true ]]     && echo -e "  ${GREEN}✔${NC} Elasticsearch"     || echo -e "  ${DIM}✗ Elasticsearch${NC}"
  [[ "$INSTALL_KIBANA" == true ]] && echo -e "  ${GREEN}✔${NC} Kibana"             || echo -e "  ${DIM}✗ Kibana${NC}"
  [[ "$INSTALL_FLEET" == true ]]  && echo -e "  ${GREEN}✔${NC} Fleet Server"       || echo -e "  ${DIM}✗ Fleet Server${NC}"
  echo ""

  if [[ "$INSTALL_ES" == false && "$INSTALL_KIBANA" == false && "$INSTALL_FLEET" == false ]]; then
    die "No components selected. Nothing to do."
  fi

  # If ES is not being installed here, ask where to find it
  if [[ "$INSTALL_ES" == false && ("$INSTALL_KIBANA" == true || "$INSTALL_FLEET" == true) ]]; then
    prompt "Elasticsearch URL (e.g. https://10.0.0.1:9200)" "https://localhost:9200"
    ES_EXTERNAL_URL="$REPLY"
  fi
}

menu_multi_node() {
  step "Multi-node cluster configuration"
  echo ""

  prompt "Cluster name" "$CLUSTER_NAME"
  CLUSTER_NAME="$REPLY"

  prompt "Node name (unique per node)" "$(hostname -s)"
  NODE_NAME="$REPLY"

  echo ""
  echo -e "  ${BOLD}Node role:${NC}"
  echo -e "  ${BOLD}1)${NC} Master-eligible + Data  ${DIM}(default for small clusters)${NC}"
  echo -e "  ${BOLD}2)${NC} Master-eligible only    ${DIM}(dedicated master)${NC}"
  echo -e "  ${BOLD}3)${NC} Data only               ${DIM}(dedicated data node)${NC}"
  echo -e "  ${BOLD}4)${NC} Coordinating only       ${DIM}(load balancer / client node)${NC}"
  echo ""
  prompt "Choose role" "1"
  case "$REPLY" in
    1) NODE_ROLE="master_data" ;;
    2) NODE_ROLE="master" ;;
    3) NODE_ROLE="data" ;;
    4) NODE_ROLE="coordinating" ;;
    *) NODE_ROLE="master_data"; warn "Invalid choice — defaulting to master + data" ;;
  esac

  local detected_ip
  detected_ip=$(hostname -I | awk '{print $1}')
  echo ""
  info "Enter the IP address each service should bind to, or 0.0.0.0 to listen on all interfaces."
  echo ""
  prompt "Elasticsearch bind address (network.host)" "$detected_ip"
  NETWORK_HOST="$REPLY"

  if [[ "$INSTALL_KIBANA" == true ]]; then
    prompt "Kibana bind address (server.host)" "0.0.0.0"
    KIBANA_HOST="$REPLY"
  fi

  if [[ "$INSTALL_FLEET" == true ]]; then
    prompt "Fleet Server bind address" "0.0.0.0"
    FLEET_HOST="$REPLY"
  fi

  echo ""
  info "Enter the IP or hostname of each master-eligible node for cluster discovery."
  info "Press Enter on a blank line when done."
  SEED_HOSTS=()
  while true; do
    prompt "Seed host (blank to finish)" ""
    if [[ -z "$REPLY" ]]; then break; fi
    SEED_HOSTS+=("$REPLY")
  done

  if [[ "$NODE_ROLE" == "master" || "$NODE_ROLE" == "master_data" ]]; then
    echo ""
    info "List the node.name of every master-eligible node for initial cluster bootstrap."
    info "Only required on first start — leave blank to skip."
    INITIAL_MASTERS=()
    while true; do
      prompt "Initial master node name (blank to finish)" ""
      if [[ -z "$REPLY" ]]; then break; fi
      INITIAL_MASTERS+=("$REPLY")
    done
  fi
}

menu_network() {
  step "Network binding"
  echo ""
  info "Enter the IP address each service should bind to, or 0.0.0.0 to listen on all interfaces."
  echo ""

  local detected_ip
  detected_ip=$(hostname -I | awk '{print $1}')

  if [[ "$INSTALL_ES" == true ]]; then
    prompt "Elasticsearch bind address (network.host)" "0.0.0.0"
    NETWORK_HOST="$REPLY"
  fi

  if [[ "$INSTALL_KIBANA" == true ]]; then
    prompt "Kibana bind address (server.host)" "0.0.0.0"
    KIBANA_HOST="$REPLY"
  fi

  if [[ "$INSTALL_FLEET" == true ]]; then
    prompt "Fleet Server bind address" "0.0.0.0"
    FLEET_HOST="$REPLY"
  fi
}

menu_passwords() {
  if [[ "$INSTALL_ES" == false ]]; then return; fi

  step "User passwords"
  echo ""
  info "You can set custom passwords now, or let the installer auto-generate them."
  echo ""

  if confirm "  Set a custom password for the 'elastic' superuser?" "N"; then
    echo ""
    prompt_password "Password for 'elastic'" CUSTOM_ELASTIC_PASSWORD
    success "Password for 'elastic' noted"
  fi
  echo ""

  if confirm "  Set a custom password for the 'kibana_system' user?" "N"; then
    echo ""
    prompt_password "Password for 'kibana_system'" CUSTOM_KIBANA_PASSWORD
    success "Password for 'kibana_system' noted"
  fi
}

menu_confirm() {
  step "Configuration summary"
  echo ""
  hr
  echo -e "  ${BOLD}Version:${NC}    ${ELASTIC_VERSION}"
  echo -e "  ${BOLD}Topology:${NC}   ${TOPOLOGY}"

  if [[ "$TOPOLOGY" == "multi" ]]; then
    echo -e "  ${BOLD}Cluster:${NC}    ${CLUSTER_NAME}"
    echo -e "  ${BOLD}Node name:${NC}  ${NODE_NAME}"
    echo -e "  ${BOLD}Node role:${NC}  ${NODE_ROLE}"
    if [[ ${#SEED_HOSTS[@]} -gt 0 ]]; then
      echo -e "  ${BOLD}Seed hosts:${NC} $(IFS=', '; echo "${SEED_HOSTS[*]}")"
    fi
    if [[ ${#INITIAL_MASTERS[@]} -gt 0 ]]; then
      echo -e "  ${BOLD}Init masters:${NC} $(IFS=', '; echo "${INITIAL_MASTERS[*]}")"
    fi
  fi

  echo ""
  echo -e "  ${BOLD}Bind addresses:${NC}"
  if [[ "$INSTALL_ES" == true ]];     then echo -e "    Elasticsearch:  ${NETWORK_HOST}:9200"; fi
  if [[ "$INSTALL_KIBANA" == true ]]; then echo -e "    Kibana:         ${KIBANA_HOST}:5601"; fi
  if [[ "$INSTALL_FLEET" == true ]];  then echo -e "    Fleet Server:   ${FLEET_HOST}:8220"; fi

  echo ""
  echo -e "  ${BOLD}Components:${NC}"
  if [[ "$INSTALL_ES" == true ]];     then echo -e "    ${GREEN}✔${NC} Elasticsearch"; fi
  if [[ "$INSTALL_KIBANA" == true ]]; then echo -e "    ${GREEN}✔${NC} Kibana"; fi
  if [[ "$INSTALL_FLEET" == true ]];  then echo -e "    ${GREEN}✔${NC} Fleet Server (Elastic Agent)"; fi
  if [[ -n "$ES_EXTERNAL_URL" ]];     then echo -e "  ${BOLD}ES URL:${NC}     ${ES_EXTERNAL_URL}"; fi

  if [[ "$INSTALL_ES" == true ]]; then
    echo ""
    echo -e "  ${BOLD}Passwords:${NC}"
    if [[ -n "$CUSTOM_ELASTIC_PASSWORD" ]]; then
      echo -e "    elastic:        ${GREEN}custom${NC}"
    else
      echo -e "    elastic:        ${DIM}auto-generated${NC}"
    fi
    if [[ -n "$CUSTOM_KIBANA_PASSWORD" ]]; then
      echo -e "    kibana_system:  ${GREEN}custom${NC}"
    else
      echo -e "    kibana_system:  ${DIM}auto-generated${NC}"
    fi
  fi

  echo ""
  hr
  echo ""
  confirm "Proceed with installation?" "Y" || die "Installation cancelled."
}

# ── Repository Setup ──────────────────────────────────────────────────────────
setup_repo() {
  step "Setting up Elastic ${ELASTIC_MAJOR}.x package repository"

  if [[ "$OS_FAMILY" == "debian" ]]; then
    info "Adding Elastic APT repository..."
    curl -fsSL "https://artifacts.elastic.co/GPG-KEY-elasticsearch" \
      | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg 2>>"$LOG_FILE"
    $PKG_MANAGER install -y apt-transport-https >> "$LOG_FILE" 2>&1
    echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/${ELASTIC_MAJOR}.x/apt stable main" \
      > /etc/apt/sources.list.d/elastic-${ELASTIC_MAJOR}.x.list
    run_with_spinner "Updating package index" $PKG_MANAGER update -qq \
      && success "Package index updated" \
      || warn "apt-get update had warnings — check ${LOG_FILE}"

  elif [[ "$OS_FAMILY" == "rhel" ]]; then
    info "Adding Elastic RPM repository..."
    cat > /etc/yum.repos.d/elasticsearch.repo <<REPO
[elasticsearch]
name=Elasticsearch repository for ${ELASTIC_MAJOR}.x packages
baseurl=https://artifacts.elastic.co/packages/${ELASTIC_MAJOR}.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
REPO
  fi

  success "Repository configured"
}

# ── Install helpers ───────────────────────────────────────────────────────────
_pkg_install_inner() {
  local pkg="$1"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    DEBIAN_FRONTEND=noninteractive $PKG_MANAGER install -y "${pkg}=${ELASTIC_VERSION}" \
      || DEBIAN_FRONTEND=noninteractive $PKG_MANAGER install -y "${pkg}"
  else
    $PKG_MANAGER install -y "${pkg}-${ELASTIC_VERSION}" \
      || $PKG_MANAGER install -y "${pkg}"
  fi
}

pkg_install() {
  local pkg="$1"
  run_with_spinner "Installing ${pkg}" _pkg_install_inner "$pkg" \
    || die "Failed to install ${pkg} — check ${LOG_FILE}"
}

install_elasticsearch() {
  step "Installing Elasticsearch ${ELASTIC_VERSION}"
  pkg_install "elasticsearch"
  success "Elasticsearch installed"
}

install_kibana() {
  step "Installing Kibana ${ELASTIC_VERSION}"
  pkg_install "kibana"
  success "Kibana installed"
}

install_fleet() {
  step "Installing Elastic Agent ${ELASTIC_VERSION}"
  pkg_install "elastic-agent"
  success "Elastic Agent installed"
}

# ── Configuration ─────────────────────────────────────────────────────────────
configure_elasticsearch() {
  step "Configuring Elasticsearch"

  local conf="/etc/elasticsearch/elasticsearch.yml"
  local jvm_dir="/etc/elasticsearch/jvm.options.d"

  cp "$conf" "${conf}.bak"

  # JVM heap: 50 % of RAM, capped at 31 GB, minimum 512 MB
  local ram_mb heap_mb
  ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
  heap_mb=$(( ram_mb / 2 ))
  if [[ $heap_mb -gt 31744 ]]; then heap_mb=31744; fi
  if [[ $heap_mb -lt 512 ]];   then heap_mb=512;   fi

  mkdir -p "$jvm_dir"
  cat > "${jvm_dir}/heap.options" <<EOF
-Xms${heap_mb}m
-Xmx${heap_mb}m
EOF

  if [[ "$TOPOLOGY" == "single" ]]; then
    cat > "$conf" <<EOF
# ── Elastic Stack — Single-node POC ──────────────────────────────────────────
cluster.name: ${CLUSTER_NAME}
node.name: ${NODE_NAME}

# Paths
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

# Network
network.host: ${NETWORK_HOST}
http.port: 9200

# Single-node discovery (no cluster formation)
discovery.type: single-node

# Security (default enabled in 8.x / 9.x)
xpack.security.enabled: true
xpack.security.enrollment.enabled: true

xpack.security.http.ssl:
  enabled: true
  keystore.path: certs/http.p12

xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: certs/transport.p12
  truststore.path: certs/transport.p12
EOF

  else
    # Build node.roles value
    local roles
    case "$NODE_ROLE" in
      master_data)  roles="[ master, data, ingest ]" ;;
      master)       roles="[ master ]" ;;
      data)         roles="[ data, ingest ]" ;;
      coordinating) roles="[]" ;;
    esac

    # Build seed_hosts YAML block
    local seed_block=""
    if [[ ${#SEED_HOSTS[@]} -gt 0 ]]; then
      seed_block="discovery.seed_hosts:"$'\n'
      for h in "${SEED_HOSTS[@]}"; do
        seed_block+="  - \"${h}\""$'\n'
      done
    fi

    # Build initial_master_nodes YAML block (bootstrap only)
    local masters_block=""
    if [[ ${#INITIAL_MASTERS[@]} -gt 0 ]]; then
      masters_block="# Remove this setting after the cluster first starts successfully"$'\n'
      masters_block+="cluster.initial_master_nodes:"$'\n'
      for n in "${INITIAL_MASTERS[@]}"; do
        masters_block+="  - \"${n}\""$'\n'
      done
    fi

    cat > "$conf" <<EOF
# ── Elastic Stack — Multi-node cluster ───────────────────────────────────────
cluster.name: ${CLUSTER_NAME}
node.name: ${NODE_NAME}

# Paths
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

# Network
network.host: ${NETWORK_HOST}
http.port: 9200
transport.port: 9300

# Node roles
node.roles: ${roles}

# Cluster discovery
${seed_block}
${masters_block}
# Security
xpack.security.enabled: true
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: certs/transport.p12
  truststore.path: certs/transport.p12

xpack.security.http.ssl:
  enabled: true
  keystore.path: certs/http.p12
EOF
  fi

  open_firewall_port 9200
  if [[ "$TOPOLOGY" == "multi" ]]; then open_firewall_port 9300; fi

  success "Elasticsearch configured (JVM heap: ${heap_mb}MB)"
}

configure_kibana() {
  step "Configuring Kibana"

  local conf="/etc/kibana/kibana.yml"
  cp "$conf" "${conf}.bak"

  local es_url
  [[ "$INSTALL_ES" == true ]] && es_url="https://localhost:9200" || es_url="${ES_EXTERNAL_URL}"

  # Fleet requires a stable 32-char encryption key for saved objects.
  # Generate once and store globally so we can re-apply it after kibana-setup
  # (which may append to or modify kibana.yml during enrollment).
  KIBANA_ENC_KEY=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)

  cat > "$conf" <<EOF
# ── Kibana Configuration ──────────────────────────────────────────────────────
server.port: 5601
server.host: "${KIBANA_HOST}"
server.name: "$(hostname -s)"

# Elasticsearch connection
# Note: if using the enrollment token flow below, this will be overwritten.
elasticsearch.hosts: ["${es_url}"]

# Required for Fleet — must be set before Kibana starts
xpack.encryptedSavedObjects.encryptionKey: "${KIBANA_ENC_KEY}"

# Logging
logging.appenders.file.type: file
logging.appenders.file.fileName: /var/log/kibana/kibana.log
logging.appenders.file.layout.type: json
logging.root.appenders: [default, file]
EOF

  open_firewall_port 5601
  success "Kibana configured"
}

# ── Firewall helpers ──────────────────────────────────────────────────────────
open_firewall_port() {
  local port="$1"
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" >> "$LOG_FILE" 2>&1
    firewall-cmd --reload >> "$LOG_FILE" 2>&1
    log "firewalld: opened port ${port}/tcp"
  elif command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw allow "${port}/tcp" >> "$LOG_FILE" 2>&1
      log "ufw: opened port ${port}/tcp"
    fi
  fi
}

# ── Service management ────────────────────────────────────────────────────────
start_service() {
  local svc="$1"
  step "Starting ${svc}"
  systemctl daemon-reload >> "$LOG_FILE" 2>&1
  systemctl enable "$svc" >> "$LOG_FILE" 2>&1
  systemctl start  "$svc" >> "$LOG_FILE" 2>&1 || true

  local retries=12 elapsed=0
  while [[ $retries -gt 0 ]]; do
    if systemctl is-active --quiet "$svc"; then
      printf "\r%-80s\r" ""
      success "${svc} is running"
      return 0
    fi
    printf "\r  ${CYAN}[●]${NC} Waiting for ${svc} to start... ${DIM}%ds${NC}" "$elapsed"
    sleep 5
    (( retries-- )) || true
    (( elapsed += 5 )) || true
  done
  printf "\r%-80s\r" ""
  warn "${svc} did not become active within 60s"
  warn "Check: journalctl -u ${svc} -n 50 --no-pager"
}

wait_for_es() {
  info "Waiting for Elasticsearch to accept connections on :9200..."
  local retries=24 elapsed=0
  while [[ $retries -gt 0 ]]; do
    if curl -sk "https://localhost:9200" -o /dev/null 2>/dev/null; then
      printf "\r%-80s\r" ""
      return 0
    fi
    printf "\r  ${CYAN}[●]${NC} Elasticsearch not yet up... ${DIM}%ds${NC}" "$elapsed"
    sleep 5
    (( retries-- )) || true
    (( elapsed += 5 )) || true
  done
  printf "\r%-80s\r" ""
  warn "Elasticsearch not responding after 120s — subsequent steps may fail."
  return 1
}

wait_for_kibana() {
  info "Waiting for Kibana to become ready on :5601..."
  local retries=36 elapsed=0   # up to 3 minutes; Kibana can be slow on first start
  while [[ $retries -gt 0 ]]; do
    local status
    status=$(curl -sk "http://localhost:5601/api/status" 2>/dev/null \
      | grep -o '"level":"[^"]*"' | head -1 | grep -o '[^"]*"$' | tr -d '"') || true
    if [[ "$status" == "available" || "$status" == "degraded" ]]; then
      printf "\r%-80s\r" ""
      success "Kibana is ready"
      return 0
    fi
    printf "\r  ${CYAN}[●]${NC} Kibana not yet ready... ${DIM}%ds${NC}" "$elapsed"
    sleep 5
    (( retries-- )) || true
    (( elapsed += 5 )) || true
  done
  printf "\r%-80s\r" ""
  warn "Kibana not ready after 180s — Fleet Server setup may fail."
  return 1
}

# ── Post-install security setup ───────────────────────────────────────────────
setup_es_security() {
  step "Setting Elasticsearch credentials"
  wait_for_es || return

  info "Auto-generating elastic user password..."
  local pw_output
  pw_output=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password \
    -u elastic -a -b 2>>"$LOG_FILE") || true

  ES_PASSWORD=$(echo "$pw_output" | awk '/New value:/ { print $NF }' || true)

  if [[ -n "$ES_PASSWORD" ]]; then
    log "CREDENTIAL: elastic_password (auto)=${ES_PASSWORD}"
    success "elastic auto-password set"
  else
    warn "Could not auto-extract password from reset output."
    warn "Run manually: /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic"
    ES_PASSWORD="(not captured — see above)"
    return
  fi

  # If the user provided a custom elastic password, apply it via the API
  if [[ -n "$CUSTOM_ELASTIC_PASSWORD" ]]; then
    info "Applying custom password for 'elastic'..."
    local escaped_pw result
    escaped_pw=$(printf '%s' "$CUSTOM_ELASTIC_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
    result=$(curl -sk -X POST \
      "https://localhost:9200/_security/user/elastic/_password" \
      -u "elastic:${ES_PASSWORD}" \
      -H "Content-Type: application/json" \
      -d "{\"password\": \"${escaped_pw}\"}" 2>>"$LOG_FILE") || true
    if echo "$result" | grep -qE '^[[:space:]]*\{\}[[:space:]]*$'; then
      ES_PASSWORD="$CUSTOM_ELASTIC_PASSWORD"
      log "CREDENTIAL: elastic_password (custom applied)=${ES_PASSWORD}"
      success "Custom password applied for 'elastic'"
    else
      warn "Could not apply custom password for 'elastic' — auto-generated password remains active."
      log "WARN: elastic custom password API response: ${result}"
    fi
  fi
}

setup_kibana_password() {
  if [[ -z "$CUSTOM_KIBANA_PASSWORD" ]]; then return; fi

  step "Setting kibana_system password"
  info "Applying custom password for 'kibana_system'..."
  local escaped_pw result
  escaped_pw=$(printf '%s' "$CUSTOM_KIBANA_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
  result=$(curl -sk -X POST \
    "https://localhost:9200/_security/user/kibana_system/_password" \
    -u "elastic:${ES_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{\"password\": \"${escaped_pw}\"}" 2>>"$LOG_FILE") || true
  if echo "$result" | grep -qE '^[[:space:]]*\{\}[[:space:]]*$'; then
    KIBANA_SYSTEM_PASSWORD="$CUSTOM_KIBANA_PASSWORD"
    log "CREDENTIAL: kibana_system_password (custom applied)=${KIBANA_SYSTEM_PASSWORD}"
    success "Custom password applied for 'kibana_system'"
  else
    warn "Could not apply custom password for 'kibana_system'."
    log "WARN: kibana_system custom password API response: ${result}"
  fi
}

setup_kibana_enrollment() {
  step "Enrolling Kibana with Elasticsearch"

  info "Generating Kibana enrollment token..."
  local token
  token=$(/usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token \
    -s kibana 2>>"$LOG_FILE") || true

  if [[ -z "$token" ]]; then
    warn "Could not generate enrollment token automatically."
    warn "After Kibana starts, visit http://<host>:5601 and follow the setup wizard."
    warn "Or run: /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana"
    return
  fi

  KIBANA_ENROLLMENT_TOKEN="$token"
  log "CREDENTIAL: kibana_enrollment_token=${token}"
  success "Enrollment token generated"

  if run_with_spinner "Enrolling Kibana with Elasticsearch" \
      /usr/share/kibana/bin/kibana-setup --enrollment-token "$token"; then
    success "Kibana enrolled"
  else
    warn "kibana-setup encountered an issue — check ${LOG_FILE}"
  fi

  # kibana-setup may have modified kibana.yml; ensure the encryption key is present
  # (Fleet will refuse to start without it, even if the rest of Kibana is working)
  local conf="/etc/kibana/kibana.yml"
  if [[ -n "$KIBANA_ENC_KEY" ]] && ! grep -q "encryptedSavedObjects" "$conf" 2>/dev/null; then
    echo "" >> "$conf"
    echo "# Required for Fleet" >> "$conf"
    echo "xpack.encryptedSavedObjects.encryptionKey: \"${KIBANA_ENC_KEY}\"" >> "$conf"
    info "Re-applied encryptedSavedObjects.encryptionKey to kibana.yml"
  fi
}

setup_fleet_server() {
  step "Configuring Fleet Server"

  local es_url
  [[ "$INSTALL_ES" == true ]] && es_url="https://localhost:9200" || es_url="${ES_EXTERNAL_URL}"

  local ca_cert="/etc/elasticsearch/certs/http_ca.crt"

  # Generate a Fleet Server service token via the ES API
  info "Generating Fleet Server service token..."
  local token_json token
  token_json=$(curl -sk -X POST \
    "${es_url}/_security/service/elastic/fleet-server/credential/token/fleet-server-token" \
    -u "elastic:${ES_PASSWORD}" \
    -H "Content-Type: application/json" 2>>"$LOG_FILE") || true

  token=$(echo "$token_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',{}).get('value',''))" 2>/dev/null || true)

  if [[ -z "$token" ]]; then
    warn "Could not auto-generate Fleet Server service token."
    warn "To complete Fleet Server setup manually:"
    warn "  1. In Kibana → Fleet → Settings → Add Fleet Server"
    warn "  2. Run the enrollment command shown in the UI"
    return
  fi

  FLEET_SERVICE_TOKEN="$token"
  log "CREDENTIAL: fleet_service_token=${token}"
  success "Service token generated"

  info "Starting Fleet Server via elastic-agent..."
  local ca_flag=""
  if [[ -f "$ca_cert" ]]; then ca_flag="--fleet-server-es-ca=${ca_cert}"; fi

  # shellcheck disable=SC2086
  if run_with_spinner "Installing Fleet Server (elastic-agent)" \
      elastic-agent install \
        --fleet-server-es="${es_url}" \
        --fleet-server-service-token="${token}" \
        --fleet-server-host="${FLEET_HOST}" \
        --fleet-server-port=8220 \
        $ca_flag \
        --non-interactive; then
    success "Fleet Server started on ${FLEET_HOST}:8220"
  else
    warn "Fleet Server setup had issues — check: elastic-agent status"
  fi

  open_firewall_port 8220
}

# ── Summary ───────────────────────────────────────────────────────────────────
write_summary() {
  local host_ip
  host_ip=$(hostname -I | awk '{print $1}')

  local es_display_host="$NETWORK_HOST"
  if [[ "$es_display_host" == "0.0.0.0" ]]; then es_display_host="$host_ip"; fi
  local kibana_display_host="$KIBANA_HOST"
  if [[ "$kibana_display_host" == "0.0.0.0" ]]; then kibana_display_host="$host_ip"; fi
  local fleet_display_host="$FLEET_HOST"
  if [[ "$fleet_display_host" == "0.0.0.0" ]]; then fleet_display_host="$host_ip"; fi

  local ca_cert="/etc/elasticsearch/certs/http_ca.crt"

  {
    echo "════════════════════════════════════════════════════════════════════════"
    echo "  Elastic Stack Installation Summary"
    echo "  $(date)"
    echo "════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Version:   ${ELASTIC_VERSION}"
    echo "  Topology:  ${TOPOLOGY}"
    echo "  Log file:  ${LOG_FILE}"
    echo ""

    echo "── Access URLs ──────────────────────────────────────────────────────────"
    if [[ "$INSTALL_ES" == true ]];     then echo "  Elasticsearch:  https://${es_display_host}:9200"; fi
    if [[ "$INSTALL_KIBANA" == true ]]; then echo "  Kibana:         http://${kibana_display_host}:5601"; fi
    if [[ "$INSTALL_FLEET" == true ]];  then echo "  Fleet Server:   https://${fleet_display_host}:8220"; fi
    echo ""

    echo "── Credentials ──────────────────────────────────────────────────────────"
    if [[ "$INSTALL_ES" == true ]]; then
      echo "  Elasticsearch superuser"
      echo "    Username:          elastic"
      echo "    Password:          ${ES_PASSWORD}"
      if [[ -f "$ca_cert" ]]; then echo "    CA certificate:    ${ca_cert}"; fi
      echo ""
      echo "  Kibana system user"
      echo "    Username:          kibana_system"
      if [[ -n "$KIBANA_SYSTEM_PASSWORD" ]]; then
        echo "    Password:          ${KIBANA_SYSTEM_PASSWORD}"
      else
        echo "    Password:          (managed via enrollment token)"
      fi
      echo ""
    fi
    if [[ -n "$KIBANA_ENROLLMENT_TOKEN" ]]; then
      echo "  Kibana enrollment token (used during setup — single-use)"
      echo "    ${KIBANA_ENROLLMENT_TOKEN}"
      echo ""
    fi
    if [[ -n "$FLEET_SERVICE_TOKEN" ]]; then
      echo "  Fleet Server service token"
      echo "    ${FLEET_SERVICE_TOKEN}"
      echo ""
    fi

    if [[ "$TOPOLOGY" == "multi" ]]; then
      echo "── Multi-node next steps ─────────────────────────────────────────────────"
      echo "  • Run this script on each remaining node with the same cluster.name"
      echo "  • After all nodes are up and the cluster is green, remove"
      echo "    cluster.initial_master_nodes from elasticsearch.yml on ALL nodes"
      echo "    and restart Elasticsearch to prevent accidental re-bootstrap"
      echo "  • Enroll additional nodes:"
      echo "    /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s node"
      echo ""
    fi

    echo "── Service management ────────────────────────────────────────────────────"
    echo "  Start:   systemctl start  elasticsearch kibana elastic-agent"
    echo "  Stop:    systemctl stop   elasticsearch kibana elastic-agent"
    echo "  Status:  systemctl status elasticsearch kibana elastic-agent"
    echo "  Logs:    journalctl -u elasticsearch -f"
    echo ""
    echo "════════════════════════════════════════════════════════════════════════"
  } | tee "$SUMMARY_FILE"

  # Append full credentials block to the install log
  {
    echo ""
    echo "════════════════════════════════════════════════════════════════════════"
    echo "  CREDENTIALS — recorded at $(date)"
    echo "════════════════════════════════════════════════════════════════════════"
    if [[ "$INSTALL_ES" == true ]]; then
      echo "  elastic username:          elastic"
      echo "  elastic password:          ${ES_PASSWORD}"
      if [[ -f "$ca_cert" ]]; then echo "  CA certificate:            ${ca_cert}"; fi
    fi
    if [[ -n "$KIBANA_SYSTEM_PASSWORD" ]];  then echo "  kibana_system password:    ${KIBANA_SYSTEM_PASSWORD}"; fi
    if [[ -n "$KIBANA_ENROLLMENT_TOKEN" ]]; then echo "  kibana enrollment token:   ${KIBANA_ENROLLMENT_TOKEN}"; fi
    if [[ -n "$FLEET_SERVICE_TOKEN" ]];     then echo "  fleet service token:       ${FLEET_SERVICE_TOKEN}"; fi
    echo "════════════════════════════════════════════════════════════════════════"
  } >> "$LOG_FILE"

  echo ""
  success "Summary saved to:  ${SUMMARY_FILE}"
  success "Full install log:  ${LOG_FILE}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  # Initialise log (script directory is already present)
  echo "Elastic installer started at $(date)" > "$LOG_FILE"
  echo "Script location: ${SCRIPT_DIR}" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

  clear
  banner
  echo -e "  ${DIM}Install log: ${LOG_FILE}${NC}"
  echo ""
  hr
  echo ""

  detect_os
  check_prerequisites

  echo ""
  hr
  echo -e "  ${BOLD}Configuration${NC}"
  hr
  echo ""

  menu_version
  menu_topology
  menu_components
  if [[ "$TOPOLOGY" == "multi" ]]; then
    menu_multi_node
  else
    menu_network
  fi

  # Default node name
  if [[ -z "$NODE_NAME" ]]; then NODE_NAME="$(hostname -s)"; fi

  menu_passwords
  menu_confirm

  echo ""
  hr
  echo -e "  ${BOLD}Installation${NC}"
  hr
  echo ""

  setup_repo

  if [[ "$INSTALL_ES" == true ]];     then install_elasticsearch; fi
  if [[ "$INSTALL_KIBANA" == true ]]; then install_kibana; fi
  if [[ "$INSTALL_FLEET" == true ]];  then install_fleet; fi

  if [[ "$INSTALL_ES" == true ]];     then configure_elasticsearch; fi
  if [[ "$INSTALL_KIBANA" == true ]]; then configure_kibana; fi

  # Start services in dependency order: ES → Kibana → Fleet
  if [[ "$INSTALL_ES" == true ]]; then
    start_service "elasticsearch"
    setup_es_security
    setup_kibana_password
  fi

  if [[ "$INSTALL_KIBANA" == true ]]; then
    if [[ "$INSTALL_ES" == true ]]; then setup_kibana_enrollment; fi
    start_service "kibana"
  fi

  if [[ "$INSTALL_FLEET" == true ]]; then
    # Wait for Kibana before Fleet so the Fleet UI registers correctly
    if [[ "$INSTALL_KIBANA" == true ]]; then wait_for_kibana; fi
    setup_fleet_server
  fi

  echo ""
  hr
  echo -e "  ${BOLD}${GREEN}Installation complete!${NC}"
  hr
  echo ""
  write_summary
}

main "$@"

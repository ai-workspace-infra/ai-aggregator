#!/usr/bin/env bash
# ==============================================================================
# setup-ai-gateway.sh: Quick-start installer for AI Aggregator Gateway
#
# Components:
#   - Caddy (2.8.4-alpine): Automatic HTTPS reverse proxy
#   - New API (v0.4.10): User, quota, and model permissions
#   - LiteLLM (v1.51.0): Routing, load balancing, retries, cost tracking
#
# Target OS: Debian 12+, Ubuntu 22.04+
# Target Directory: /opt/ai-gateway
# ==============================================================================

set -euo pipefail

# Pinned component versions
PINNED_CADDY_IMAGE="caddy:2.8.4-alpine"
PINNED_NEW_API_IMAGE="calciumion/new-api:v0.4.10"
PINNED_LITELLM_IMAGE="ghcr.io/berriai/litellm:v1.51.0"

# Target installation directory paths
INSTALL_ROOT="/opt/ai-gateway"
CONFIG_DIR="${INSTALL_ROOT}/config"
DATA_DIR="${INSTALL_ROOT}/data"
BACKUP_DIR="${INSTALL_ROOT}/backups"
SCRIPTS_DIR="${INSTALL_ROOT}/scripts"
VERSION_FILE="${INSTALL_ROOT}/installed.version"
COMPOSE_FILE="${INSTALL_ROOT}/docker-compose.yml"
CADDYFILE="${INSTALL_ROOT}/Caddyfile"
LITELLM_CONFIG="${CONFIG_DIR}/litellm_config.yaml"
ENV_FILE="${CONFIG_DIR}/.env"

# Log helpers
log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARNING] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

# Cryptographically secure random secret generator
generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 64
  fi
}

# Resolve docker compose command
get_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo ""
  fi
}

# Usage / Help
show_usage() {
  cat <<'EOF'
Usage: setup-ai-gateway.sh --domain <fqdn> [--standalone | --with-mcp] [options]
       setup-ai-gateway.sh --uninstall
       setup-ai-gateway.sh --help

One-line installer for AI Aggregator (New API + LiteLLM) + Caddy TLS Reverse Proxy.

Commands & Flags:
  --domain <fqdn>       Fully Qualified Domain Name for the AI Gateway (e.g. ai.example.com)
  --standalone          Deploy standalone mode (mock/local upstream configuration)
  --with-mcp            Deploy team mode with MCP integration (requires runtime environment variables)
  --dry-run             Perform preflight validation, render configurations, and simulate execution without changes
  --uninstall           Stop running containers and clean up gateway services (backups are preserved)
  --help, -h            Show this help message and exit

Team Mode Environment Variables (required with --with-mcp):
  AI_GATEWAY_DOMAIN     Gateway domain (must match --domain)
  MCP_DOMAIN            MCP server domain
  UPSTREAM_API_KEY      Upstream AI Provider API key
  MCP_SERVICE_TOKEN     Service token for MCP authentication

Supported Operating Systems:
  Debian 12+ (Bookworm or newer)
  Ubuntu 22.04+ (Jammy Jellyfish or newer)
EOF
}

# Preflight: Check DNS A record against host public IP
check_dns_preflight() {
  local domain="$1"
  local public_ip=""
  local domain_ip=""

  if command -v curl >/dev/null 2>&1; then
    public_ip=$(curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null || curl -fsS4 --max-time 3 https://ifconfig.me 2>/dev/null || true)
  fi

  if command -v getent >/dev/null 2>&1; then
    domain_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -n 1 || true)
  elif command -v dig >/dev/null 2>&1; then
    domain_ip=$(dig +short "$domain" A 2>/dev/null | head -n 1 || true)
  elif command -v host >/dev/null 2>&1; then
    domain_ip=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}' | head -n 1 || true)
  elif command -v nslookup >/dev/null 2>&1; then
    domain_ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1 || true)
  fi

  if [[ -z "$public_ip" ]]; then
    log_warn "DNS Preflight: Unable to determine host public IP (no internet connection or API timeout). Caddy TLS challenge will require public DNS reachability."
  elif [[ -z "$domain_ip" ]]; then
    log_warn "DNS Preflight: Domain '$domain' does not resolve to an A record. Host public IP is $public_ip. Caddy ACME TLS issuance may fail until DNS propagates."
  elif [[ "$domain_ip" != "$public_ip" ]]; then
    log_warn "DNS Preflight: Domain '$domain' resolves to $domain_ip, but host public IP is $public_ip. Caddy ACME TLS issuance may fail if traffic does not reach this host."
  else
    log_info "DNS Preflight: Domain '$domain' correctly points to host public IP ($public_ip)."
  fi
}

# Render health check / simulation summary
render_health_summary() {
  local status="$1"
  if [[ "$status" == "DRY_RUN" ]]; then
    cat <<EOF

============================================================
           AI Gateway Preflight & Simulation Summary
============================================================
Status:            DRY RUN (Success - Ready to Deploy)
Gateway URL:       https://${DOMAIN}
Mode:              ${MODE}
New API Image:     ${PINNED_NEW_API_IMAGE}
LiteLLM Image:     ${PINNED_LITELLM_IMAGE}
Caddy Image:       ${PINNED_CADDY_IMAGE}
Target Directory:  ${INSTALL_ROOT}
============================================================
EOF
  else
    cat <<EOF

============================================================
              AI Gateway Installation Summary
============================================================
Status:            ONLINE
Gateway URL:       https://${DOMAIN}
Mode:              ${MODE}
New API Status:    RUNNING (${PINNED_NEW_API_IMAGE})
LiteLLM Status:    RUNNING (${PINNED_LITELLM_IMAGE})
Caddy TLS Status:  RUNNING (${PINNED_CADDY_IMAGE})
Install Root:      ${INSTALL_ROOT}
============================================================
EOF
  fi
}

# Install Docker prerequisites if missing (Live run only)
install_docker_prerequisites() {
  log_info "Installing Docker and Compose plugin prerequisites..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  local codename="${VERSION_CODENAME:-}"
  if [[ -z "$codename" && -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
  fi
  if [[ "$OS_ID" == "debian" ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list
  elif [[ "$OS_ID" == "ubuntu" ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list
  fi
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker || true
}

# ------------------------------------------------------------------------------
# 1. Parse Command Line Arguments
# ------------------------------------------------------------------------------
DOMAIN=""
MODE=""
DRY_RUN=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        log_error "--domain requires a non-empty FQDN argument"
        show_usage >&2
        exit 1
      fi
      DOMAIN="$2"
      shift 2
      ;;
    --standalone)
      if [[ "$MODE" == "team" ]]; then
        log_error "Cannot specify both --standalone and --with-mcp"
        exit 1
      fi
      MODE="standalone"
      shift
      ;;
    --with-mcp)
      if [[ "$MODE" == "standalone" ]]; then
        log_error "Cannot specify both --standalone and --with-mcp"
        exit 1
      fi
      MODE="team"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --help|-h)
      show_usage
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      show_usage >&2
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 2. Validate Flags & Input
# ------------------------------------------------------------------------------
if [[ "$UNINSTALL" != true ]]; then
  if [[ -z "$DOMAIN" ]]; then
    log_error "Missing required argument: --domain <fqdn>"
    show_usage >&2
    exit 1
  fi

  if ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    log_error "Invalid domain name: '$DOMAIN'. Must be a valid FQDN (e.g. ai.example.com)."
    exit 1
  fi

  if [[ -z "$MODE" ]]; then
    log_error "Must specify deployment mode: either --standalone or --with-mcp"
    show_usage >&2
    exit 1
  fi

  if [[ "$MODE" == "team" ]]; then
    missing_vars=()
    [[ -z "${AI_GATEWAY_DOMAIN:-}" ]] && missing_vars+=("AI_GATEWAY_DOMAIN")
    [[ -z "${MCP_DOMAIN:-}" ]] && missing_vars+=("MCP_DOMAIN")
    [[ -z "${UPSTREAM_API_KEY:-}" ]] && missing_vars+=("UPSTREAM_API_KEY")
    [[ -z "${MCP_SERVICE_TOKEN:-}" ]] && missing_vars+=("MCP_SERVICE_TOKEN")

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
      log_error "Team mode (--with-mcp) missing required environment variables: ${missing_vars[*]}"
      log_error "Fail-closed: All team mode credentials and domains must be provided."
      exit 1
    fi

    if [[ "$DOMAIN" != "$AI_GATEWAY_DOMAIN" ]]; then
      log_error "Domain mismatch: --domain ($DOMAIN) does not match AI_GATEWAY_DOMAIN ($AI_GATEWAY_DOMAIN)"
      exit 1
    fi

    if ! [[ "$MCP_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      log_error "Invalid MCP domain name: '$MCP_DOMAIN'. Must be a valid FQDN."
      exit 1
    fi
  fi
fi

# ------------------------------------------------------------------------------
# 3. Privilege & Target OS Validation
# ------------------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
  log_error "This script must be run as root (uid 0)."
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  log_error "Cannot determine operating system (/etc/os-release not found)."
  exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release

OS_ID="${ID:-}"
OS_VER="${VERSION_ID:-}"

is_supported_os=false
if [[ "$OS_ID" == "debian" ]]; then
  major_ver="${OS_VER%%.*}"
  if [[ "$major_ver" =~ ^[0-9]+$ ]] && [[ "$major_ver" -ge 12 ]]; then
    is_supported_os=true
  fi
elif [[ "$OS_ID" == "ubuntu" ]]; then
  major_ver="${OS_VER%%.*}"
  if [[ "$major_ver" =~ ^[0-9]+$ ]] && [[ "$major_ver" -ge 22 ]]; then
    is_supported_os=true
  fi
fi

if [[ "$is_supported_os" != true ]]; then
  log_error "Unsupported operating system: ${OS_ID:-unknown} ${OS_VER:-unknown}."
  log_error "Supported operating systems: Debian 12+, Ubuntu 22.04+."
  exit 1
fi

# ------------------------------------------------------------------------------
# 4. Uninstall Execution
# ------------------------------------------------------------------------------
if [[ "$UNINSTALL" == true ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Uninstall requested."
    if [[ -d "$INSTALL_ROOT" ]]; then
      log_info "[DRY-RUN] Would stop containers via docker compose at ${COMPOSE_FILE}."
      log_info "[DRY-RUN] Would backup data directory ${DATA_DIR} to /opt/ai-gateway-backup-YYYYMMDDHHMMSS."
      log_info "[DRY-RUN] Would remove container resources and installation."
    else
      log_info "[DRY-RUN] No installation found at ${INSTALL_ROOT}. Nothing to uninstall."
    fi
    exit 0
  fi

  log_info "Starting AI Gateway uninstallation..."
  if [[ -d "$INSTALL_ROOT" ]]; then
    compose_bin=$(get_compose_cmd)
    if [[ -n "$compose_bin" && -f "$COMPOSE_FILE" ]]; then
      log_info "Stopping running gateway containers..."
      $compose_bin -f "$COMPOSE_FILE" down || true
    elif command -v docker >/dev/null 2>&1; then
      docker stop ai-gateway-caddy ai-gateway-new-api ai-gateway-litellm 2>/dev/null || true
      docker rm ai-gateway-caddy ai-gateway-new-api ai-gateway-litellm 2>/dev/null || true
    fi

    if [[ -d "$DATA_DIR" ]]; then
      backup_target="/opt/ai-gateway-backup-$(date +%Y%m%d%H%M%S)"
      cp -a "$DATA_DIR" "$backup_target"
      log_info "Data directory backed up to: $backup_target"
    fi

    log_info "AI Gateway services stopped and removed."
    log_info "Configuration directory retained at: $INSTALL_ROOT"
    log_info "Uninstallation complete."
  else
    log_info "No installation found at ${INSTALL_ROOT}. Nothing to uninstall."
  fi
  exit 0
fi

# ------------------------------------------------------------------------------
# 5. Preflight: TLS & DNS Validation
# ------------------------------------------------------------------------------
log_info "Executing DNS and TLS preflight checks for domain: $DOMAIN..."
check_dns_preflight "$DOMAIN"

if [[ "$MODE" == "team" ]]; then
  log_info "Executing DNS and TLS preflight checks for MCP domain: $MCP_DOMAIN..."
  check_dns_preflight "$MCP_DOMAIN"
fi

# ------------------------------------------------------------------------------
# 6. Idempotency Check
# ------------------------------------------------------------------------------
if [[ -f "$VERSION_FILE" ]]; then
  installed_caddy=""
  installed_new_api=""
  installed_litellm=""
  installed_domain=""
  installed_mode=""

  # Read key-values safely
  while IFS='=' read -r key val; do
    case "$key" in
      CADDY_IMAGE) installed_caddy="$val" ;;
      NEW_API_IMAGE) installed_new_api="$val" ;;
      LITELLM_IMAGE) installed_litellm="$val" ;;
      DOMAIN) installed_domain="$val" ;;
      MODE) installed_mode="$val" ;;
    esac
  done < "$VERSION_FILE"

  if [[ "$installed_caddy" == "$PINNED_CADDY_IMAGE" && \
        "$installed_new_api" == "$PINNED_NEW_API_IMAGE" && \
        "$installed_litellm" == "$PINNED_LITELLM_IMAGE" && \
        "$installed_domain" == "$DOMAIN" && \
        "$installed_mode" == "$MODE" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log_info "[DRY-RUN] Idempotency check: AI Gateway is already configured with identical pinned versions and settings at ${INSTALL_ROOT}."
      log_info "[DRY-RUN] Pinned components: New API ($PINNED_NEW_API_IMAGE), LiteLLM ($PINNED_LITELLM_IMAGE), Caddy ($PINNED_CADDY_IMAGE)"
      log_info "[DRY-RUN] No configuration changes required."
      render_health_summary "DRY_RUN"
      exit 0
    else
      compose_bin=$(get_compose_cmd)
      if [[ -n "$compose_bin" && -f "$COMPOSE_FILE" ]]; then
        running_count=$($compose_bin -f "$COMPOSE_FILE" ps --status running -q 2>/dev/null | wc -l || echo 0)
        if [[ "$running_count" -ge 3 ]]; then
          log_info "AI Gateway is already installed at pinned versions and running (idempotent skip)."
          render_health_summary "ONLINE"
          exit 0
        fi
      fi
    fi
  else
    log_info "Existing installation detected with configuration differences. Creating backup before updating..."
    backup_timestamp=$(date +%Y%m%d%H%M%S)
    backup_dest="${BACKUP_DIR}/backup-${backup_timestamp}"
    mkdir -p "$backup_dest"
    [[ -f "$COMPOSE_FILE" ]] && cp "$COMPOSE_FILE" "$backup_dest/"
    [[ -f "$CADDYFILE" ]] && cp "$CADDYFILE" "$backup_dest/"
    [[ -f "$LITELLM_CONFIG" ]] && cp "$LITELLM_CONFIG" "$backup_dest/"
    [[ -f "$VERSION_FILE" ]] && cp "$VERSION_FILE" "$backup_dest/"
    log_info "Existing configuration backed up to: $backup_dest"
  fi
fi

# ------------------------------------------------------------------------------
# 7. Dry-run Mode Simulation & Early Return
# ------------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  log_info "[DRY-RUN] Preflight checks passed."
  log_info "[DRY-RUN] Simulating configuration generation for domain: $DOMAIN (Mode: $MODE)"
  log_info "[DRY-RUN] Target directory: $INSTALL_ROOT"
  log_info "[DRY-RUN] Pinned components: New API ($PINNED_NEW_API_IMAGE), LiteLLM ($PINNED_LITELLM_IMAGE), Caddy ($PINNED_CADDY_IMAGE)"
  if [[ "$MODE" == "team" ]]; then
    log_info "[DRY-RUN] Team Mode: Validated MCP_DOMAIN ($MCP_DOMAIN), UPSTREAM_API_KEY ([MASKED]), MCP_SERVICE_TOKEN ([MASKED])"
  else
    log_info "[DRY-RUN] Standalone Mode: Root token and LiteLLM master key would be generated securely at runtime."
  fi
  log_info "[DRY-RUN] Container service definitions and reverse proxy rules verified."
  render_health_summary "DRY_RUN"
  log_info "[DRY-RUN] Dry run simulation finished successfully. No system changes made."
  exit 0
fi

# ------------------------------------------------------------------------------
# 8. Setup Directory Structure & Permissions (Live Run)
# ------------------------------------------------------------------------------
log_info "Preparing directory structure at ${INSTALL_ROOT}..."
mkdir -p "$CONFIG_DIR" "$DATA_DIR/new-api" "$DATA_DIR/caddy" "$DATA_DIR/caddy-config" "$BACKUP_DIR" "$SCRIPTS_DIR"
chmod 0700 "$INSTALL_ROOT" "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_DIR" "$SCRIPTS_DIR"

if [[ -f "$0" ]]; then
  cp "$0" "$SCRIPTS_DIR/setup-ai-gateway.sh"
  chmod 0700 "$SCRIPTS_DIR/setup-ai-gateway.sh"
fi

# Check Docker and Compose availability
compose_bin=$(get_compose_cmd)
if [[ -z "$compose_bin" ]] || ! command -v docker >/dev/null 2>&1; then
  install_docker_prerequisites
  compose_bin=$(get_compose_cmd)
  if [[ -z "$compose_bin" ]]; then
    log_error "Failed to initialize Docker Compose. Please verify Docker installation."
    exit 1
  fi
fi

# ------------------------------------------------------------------------------
# 9. Secrets & Credentials Management
# ------------------------------------------------------------------------------
IS_NEW_CREDENTIALS=false
INITIAL_ROOT_TOKEN=""
LITELLM_MASTER_KEY=""

if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r key val; do
    case "$key" in
      INITIAL_ROOT_TOKEN) INITIAL_ROOT_TOKEN="$val" ;;
      LITELLM_MASTER_KEY) LITELLM_MASTER_KEY="$val" ;;
    esac
  done < "$ENV_FILE"
fi

if [[ -z "$INITIAL_ROOT_TOKEN" ]]; then
  INITIAL_ROOT_TOKEN=$(generate_secret)
  IS_NEW_CREDENTIALS=true
fi

if [[ -z "$LITELLM_MASTER_KEY" ]]; then
  LITELLM_MASTER_KEY="sk-litellm-$(generate_secret)"
fi

# Write environment file with restrictive permissions (0600)
cat <<EOF > "$ENV_FILE"
# AI Gateway Runtime Environment
AI_GATEWAY_DOMAIN=${DOMAIN}
NEW_API_ROOT_TOKEN=${INITIAL_ROOT_TOKEN}
INITIAL_ROOT_TOKEN=${INITIAL_ROOT_TOKEN}
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
EOF

if [[ "$MODE" == "team" ]]; then
  cat <<EOF >> "$ENV_FILE"
MCP_DOMAIN=${MCP_DOMAIN}
UPSTREAM_API_KEY=${UPSTREAM_API_KEY}
MCP_SERVICE_TOKEN=${MCP_SERVICE_TOKEN}
EOF
fi
chmod 0600 "$ENV_FILE"

# ------------------------------------------------------------------------------
# 10. Render Caddyfile Configuration
# ------------------------------------------------------------------------------
log_info "Rendering Caddyfile reverse proxy rules..."
if [[ "$MODE" == "standalone" ]]; then
  cat <<'EOF' > "$CADDYFILE"
{$AI_GATEWAY_DOMAIN} {
    encode gzip zstd

    # Route client traffic to New API
    reverse_proxy new-api:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF
else
  cat <<'EOF' > "$CADDYFILE"
{$AI_GATEWAY_DOMAIN} {
    encode gzip zstd

    # Route client traffic to New API
    reverse_proxy new-api:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}

{$MCP_DOMAIN} {
    encode gzip zstd

    # MCP upstream routing with token validation
    @authorized header Authorization "Bearer {$MCP_SERVICE_TOKEN}"

    handle @authorized {
        reverse_proxy litellm:4000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    handle {
        respond "Unauthorized: Invalid or missing MCP service token" 401
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF
fi
chmod 0644 "$CADDYFILE"

# ------------------------------------------------------------------------------
# 11. Render LiteLLM Configuration
# ------------------------------------------------------------------------------
log_info "Rendering LiteLLM configuration..."
if [[ "$MODE" == "standalone" ]]; then
  cat <<'EOF' > "$LITELLM_CONFIG"
model_list:
  - model_name: default-mock
    litellm_params:
      model: mock_response/default-mock
      mock_response: "Hello! AI Gateway standalone mock model is operational."
  - model_name: gpt-4o
    litellm_params:
      model: mock_response/gpt-4o
      mock_response: "Mock response for gpt-4o from AI Gateway."
  - model_name: claude-3-5-sonnet
    litellm_params:
      model: mock_response/claude-3-5-sonnet
      mock_response: "Mock response for claude-3-5-sonnet from AI Gateway."

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

litellm_settings:
  json_logs: true
  drop_params: false
EOF
else
  cat <<'EOF' > "$LITELLM_CONFIG"
model_list:
  - model_name: "*"
    litellm_params:
      model: openai/*
      api_key: os.environ/UPSTREAM_API_KEY
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/UPSTREAM_API_KEY
  - model_name: claude-3-5-sonnet
    litellm_params:
      model: anthropic/claude-3-5-sonnet-20241022
      api_key: os.environ/UPSTREAM_API_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

litellm_settings:
  json_logs: true
  drop_params: false
EOF
fi
chmod 0644 "$LITELLM_CONFIG"

# ------------------------------------------------------------------------------
# 12. Render docker-compose.yml
# ------------------------------------------------------------------------------
log_info "Rendering docker-compose.yml..."
cat <<EOF > "$COMPOSE_FILE"
services:
  caddy:
    image: ${PINNED_CADDY_IMAGE}
    container_name: ai-gateway-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    env_file:
      - ./config/.env
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data/caddy:/data
      - ./data/caddy-config:/config
    networks:
      - ai-gateway-net
    depends_on:
      - new-api
      - litellm

  new-api:
    image: ${PINNED_NEW_API_IMAGE}
    container_name: ai-gateway-new-api
    restart: unless-stopped
    env_file:
      - ./config/.env
    environment:
      - PORT=3000
      - SQL_DSN=/data/new-api.db
      - GLOBAL_WEB_REDIRECT_URL=
    volumes:
      - ./data/new-api:/data
    networks:
      - ai-gateway-net
    expose:
      - "3000"

  litellm:
    image: ${PINNED_LITELLM_IMAGE}
    container_name: ai-gateway-litellm
    restart: unless-stopped
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    env_file:
      - ./config/.env
    volumes:
      - ./config/litellm_config.yaml:/app/config.yaml:ro
    networks:
      - ai-gateway-net
    expose:
      - "4000"

networks:
  ai-gateway-net:
    driver: bridge
EOF
chmod 0644 "$COMPOSE_FILE"

# ------------------------------------------------------------------------------
# 13. Write Version Metadata File
# ------------------------------------------------------------------------------
cat <<EOF > "$VERSION_FILE"
VERSION=1.0.0
CADDY_IMAGE=${PINNED_CADDY_IMAGE}
NEW_API_IMAGE=${PINNED_NEW_API_IMAGE}
LITELLM_IMAGE=${PINNED_LITELLM_IMAGE}
DOMAIN=${DOMAIN}
MODE=${MODE}
UPDATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
chmod 0644 "$VERSION_FILE"

# ------------------------------------------------------------------------------
# 14. Pull and Start Services
# ------------------------------------------------------------------------------
log_info "Deploying AI Gateway services via Docker Compose..."
$compose_bin -f "$COMPOSE_FILE" up -d

log_info "Waiting for container services to initialize..."
for attempt in {1..30}; do
  caddy_status=$(docker inspect -f '{{.State.Status}}' ai-gateway-caddy 2>/dev/null || echo "starting")
  new_api_status=$(docker inspect -f '{{.State.Status}}' ai-gateway-new-api 2>/dev/null || echo "starting")
  litellm_status=$(docker inspect -f '{{.State.Status}}' ai-gateway-litellm 2>/dev/null || echo "starting")

  if [[ "$caddy_status" == "running" && "$new_api_status" == "running" && "$litellm_status" == "running" ]]; then
    log_info "All gateway containers are running (checked on attempt ${attempt}/30)."
    break
  fi
  sleep 1
done

# ------------------------------------------------------------------------------
# 15. Health Check & Credentials Summary
# ------------------------------------------------------------------------------
render_health_summary "ONLINE"

if [[ "$MODE" == "standalone" && "$IS_NEW_CREDENTIALS" == true ]]; then
  cat <<EOF

************************************************************
                INITIAL ADMIN CREDENTIALS
************************************************************
New API Initial Root Token:
  ${INITIAL_ROOT_TOKEN}

LiteLLM Master Key:
  ${LITELLM_MASTER_KEY}

[SECURITY GUIDANCE]
Store these credentials immediately in HashiCorp Vault or your
secure secrets manager:
  - Vault path: kv/<env>/ai-aggregator/gateway/new-api (root_token)
  - Vault path: kv/<env>/ai-aggregator/gateway/litellm (master_key)
These credentials will NOT be displayed again.
Permissions for ${ENV_FILE} are set to 0600.
************************************************************
EOF
fi

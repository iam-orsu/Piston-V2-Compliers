#!/usr/bin/env bash
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m';  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Platform Detection ───────────────────────────────────────────────────────
detect_platform() {
    if grep -qiE 'microsoft|WSL' /proc/version 2>/dev/null; then
        echo "wsl2"
    else
        echo "linux"
    fi
}
PLATFORM=$(detect_platform)

# ── Script Directory ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Docker Compose Command ───────────────────────────────────────────────────
if docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null 2>&1; then
    DC="docker-compose"
else
    echo -e "${RED}Error: docker compose not found.${NC}"
    if [[ "$PLATFORM" == "wsl2" ]]; then
        echo "  Install Docker Desktop for Windows: https://docs.docker.com/desktop/install/windows-install/"
    else
        echo "  Install: sudo apt-get install -y docker-compose-plugin"
    fi
    exit 1
fi

DEFAULT_RUNTIMES=(python node typescript java gcc go rust bash)

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { echo -e "${GREEN}▶  ${NC}$*"; }
info() { echo -e "   ${CYAN}ℹ  ${NC}$*"; }
warn() { echo -e "   ${YELLOW}⚠  ${NC}$*" >&2; }
err()  { echo -e "${RED}✗  $*${NC}" >&2; exit 1; }
step() { echo -e "   ${BLUE}→  ${NC}$*"; }

# ── Banner ───────────────────────────────────────────────────────────────────
banner() {
    echo -e "${BLUE}${BOLD}"
    echo "  ██████╗ ██╗███████╗████████╗ ██████╗ ███╗   ██╗"
    echo "  ██╔══██╗██║██╔════╝╚══██╔══╝██╔═══██╗████╗  ██║"
    echo "  ██████╔╝██║███████╗   ██║   ██║   ██║██╔██╗ ██║"
    echo "  ██╔═══╝ ██║╚════██║   ██║   ██║   ██║██║╚██╗██║"
    echo "  ██║     ██║███████║   ██║   ╚██████╔╝██║ ╚████║"
    echo "  ╚═╝     ╚═╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═══╝"
    echo -e "${NC}${CYAN}  Code Execution Engine + IDE${NC}"
    echo -e "  ${BLUE}Platform: ${BOLD}${PLATFORM}${NC}"
    echo ""
}

# ── Pre-flight Checks ────────────────────────────────────────────────────────
check_docker() {
    command -v docker &>/dev/null || {
        if [[ "$PLATFORM" == "wsl2" ]]; then
            err "Docker not found. Install Docker Desktop for Windows and enable WSL2 integration."
        else
            err "Docker not found. Install: curl -fsSL https://get.docker.com | sh"
        fi
    }

    if ! docker info &>/dev/null 2>&1; then
        if [[ "$PLATFORM" == "wsl2" ]]; then
            err "Docker daemon not running. Start Docker Desktop."
        else
            err "Docker daemon not running. Try: sudo systemctl start docker"
        fi
    fi
}

check_cgroup_v2() {
    # Piston's isolate sandbox requires cgroup v2 — only check on real Linux
    if [[ "$PLATFORM" == "linux" ]]; then
        if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
            warn "cgroup v2 may not be active. Piston requires cgroup v2."
            info "On Ubuntu 20.04 add to GRUB: systemd.unified_cgroup_hierarchy=1"
            info "On Ubuntu 22.04+ cgroup v2 is the default — if you see this, reboot."
        fi
    fi
}

check_disk_space() {
    if [[ "$PLATFORM" == "linux" ]]; then
        local avail_gb
        avail_gb=$(df -BG "$SCRIPT_DIR" | awk 'NR==2 {gsub("G",""); print $4}' || echo "0")
        if [[ "${avail_gb:-0}" -lt 5 ]]; then
            warn "Low disk space: ${avail_gb}GB available (recommend 10GB+ for language runtimes)"
        fi
    fi
}

kill_port() {
    local port="$1"
    local pids
    pids=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' || true)
    if [[ -z "$pids" ]]; then
        pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
    fi
    if [[ -n "$pids" ]]; then
        echo -e "   ${YELLOW}⚡  Port ${port} in use — killing PID(s): ${pids}${NC}"
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi
}

check_port_conflict() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       lsof -ti tcp:"$port" &>/dev/null 2>&1; then
        kill_port "$port"
    fi
}

# ── API Helpers ───────────────────────────────────────────────────────────────
wait_for_api() {
    echo -e "${YELLOW}⏳  Waiting for Piston API (replica 1)...${NC}"
    local attempts=0
    while [[ $attempts -lt 90 ]]; do
        if curl -sf http://localhost:2000/api/v2/runtimes &>/dev/null; then
            echo -e "${GREEN}✅  API is ready.${NC}"
            return 0
        fi
        sleep 2
        ((attempts++))
    done
    warn "API did not become ready in 180s. Run: ./deploy.sh logs api1"
    return 1
}

runtime_count() {
    curl -sf http://localhost:2000/api/v2/runtimes 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null \
        || echo "0"
}

ensure_cli_deps() {
    if [[ ! -d "$SCRIPT_DIR/cli/node_modules" ]]; then
        log "Installing CLI dependencies..."
        (cd "$SCRIPT_DIR/cli" && npm install --silent)
    fi
}

install_runtime() {
    local lang="$1"
    if curl -sf http://localhost:2000/api/v2/runtimes 2>/dev/null \
            | grep -q "\"language\":\"${lang}\""; then
        step "$lang already installed — skipping."
        return 0
    fi
    echo -e "   ${YELLOW}⬇  Installing ${BOLD}${lang}${NC}${YELLOW}...${NC}"
    (cd "$SCRIPT_DIR/cli" && node index.js ppman install "$lang") 2>&1 | tail -3 || {
        warn "Failed to install $lang — run './deploy.sh logs api' for details"
    }
}

auto_install_runtimes() {
    ensure_cli_deps

    echo ""
    echo -e "${CYAN}${BOLD}🚀  Checking default runtimes...${NC}"

    local installed_any=0
    for lang in "${DEFAULT_RUNTIMES[@]}"; do
        if curl -sf http://localhost:2000/api/v2/runtimes 2>/dev/null \
                | grep -q "\"language\":\"${lang}\""; then
            step "$lang already installed — skipping."
        else
            echo -e "   ${YELLOW}⬇  Installing ${BOLD}${lang}${NC}${YELLOW}...${NC}"
            (cd "$SCRIPT_DIR/cli" && node index.js ppman install "$lang") 2>&1 | tail -3 || {
                warn "Failed to install $lang"
            }
            installed_any=1
        fi
    done

    echo ""
    if [[ "$installed_any" -eq 1 ]]; then
        echo -e "${GREEN}${BOLD}✅  All default runtimes ready!${NC}"
    else
        echo -e "${GREEN}${BOLD}✅  All default runtimes already installed.${NC}"
    fi
}

# ── Commands ─────────────────────────────────────────────────────────────────
cmd_start() {
    banner
    check_docker
    check_disk_space
    check_cgroup_v2
    check_port_conflict 8080
    check_port_conflict 2000

    if [[ "$PLATFORM" == "wsl2" ]]; then
        info "Windows/WSL2 mode: packages stored in Docker named volume (Linux fs)"
    else
        info "Linux mode: standard configuration"
    fi

    log "Building and starting containers..."
    $DC up -d --build

    if wait_for_api; then
        auto_install_runtimes
    fi

    echo ""
    echo -e "${GREEN}${BOLD}✅  Piston IDE is ready!${NC}"
    echo ""

    if [[ "$PLATFORM" == "wsl2" ]]; then
        echo -e "   ${BOLD}📝 Code Editor UI${NC}  →  ${CYAN}http://localhost:8080${NC}"
        echo -e "   ${BOLD}🔌 Piston API${NC}      →  ${CYAN}http://localhost:2000${NC}"
    else
        local ip
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
        echo -e "   ${BOLD}📝 Code Editor UI${NC}  →  ${CYAN}http://${ip}:8080${NC}  (or http://localhost:8080)"
        echo -e "   ${BOLD}🔌 Piston API${NC}      →  ${CYAN}http://${ip}:2000${NC}  (internal only — firewall recommended)"
        echo ""
        echo -e "   ${YELLOW}🔒 Production tip: allow only UI port externally:${NC}"
        echo -e "      sudo ufw allow 8080/tcp && sudo ufw deny 2000/tcp"
    fi
    echo ""
}

cmd_stop() {
    check_docker
    log "Stopping Piston IDE..."
    $DC down
    echo -e "${GREEN}✅  All containers stopped.${NC}"
}

cmd_restart() {
    check_docker
    log "Rebuilding and restarting (applying changes)..."
    $DC up -d --build
    wait_for_api
    echo ""
    echo -e "${GREEN}${BOLD}✅  Restarted!${NC}"
    echo -e "   📝 Code Editor UI  →  ${CYAN}http://localhost:8080${NC}"
    echo ""
}

cmd_status() {
    check_docker
    echo -e "${BLUE}${BOLD}● Container Status${NC}  [Platform: ${PLATFORM}]"
    echo ""
    $DC ps
    echo ""

    local count
    count=$(runtime_count)
    if [[ "$count" == "0" ]]; then
        echo -e "   ${YELLOW}⚠  No runtimes installed. Run: ./deploy.sh start${NC}"
    else
        echo -e "   ${GREEN}✅  Installed runtimes: ${BOLD}${count}${NC}"
        echo -e "       Run './deploy.sh runtimes' to list them."
    fi
    echo ""
    echo -e "   ${CYAN}ℹ  3 API replicas running — capacity: ~450 concurrent students${NC}"
    echo -e "   ${CYAN}ℹ  Per-job memory limit: 256 MB · Run timeout: 15s${NC}"
    echo ""
}

cmd_logs() {
    check_docker
    local service="${1:-}"
    # Allow legacy alias: "api" → "api1"
    if [[ "$service" == "api" ]]; then service="api1"; fi
    echo -e "${BLUE}${BOLD}● Logs${service:+ ($service)}${NC}  (Ctrl+C to stop)"
    echo ""
    # shellcheck disable=SC2086
    $DC logs -f --tail=100 $service
}

cmd_install() {
    local lang="${1:-}"
    [[ -z "$lang" ]] && err "Usage: ./deploy.sh install <language>  (e.g. python, java, rust)"
    check_docker
    ensure_cli_deps
    wait_for_api
    install_runtime "$lang"
    echo -e "${GREEN}✅  Done! Refresh the IDE to see ${lang} in the dropdown.${NC}"
}

cmd_list() {
    check_docker
    ensure_cli_deps
    echo -e "${BLUE}${BOLD}Available packages:${NC}"
    (cd "$SCRIPT_DIR/cli" && node index.js ppman list)
}

cmd_runtimes() {
    check_docker
    echo -e "${BLUE}${BOLD}Installed runtimes:${NC}"
    curl -sf http://localhost:2000/api/v2/runtimes 2>/dev/null \
        | python3 -c "
import json, sys
rts = json.load(sys.stdin)
if not rts:
    print('  (none installed)')
else:
    for r in rts:
        print(f'  {r[\"language\"]:15s} {r[\"version\"]}')
" || warn "API unreachable — is the stack running? Try: ./deploy.sh start"
}

cmd_help() {
    banner
    echo -e "${BOLD}Usage:${NC}  ./deploy.sh <command> [options]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${GREEN}start${NC}               Build, start, and auto-install runtimes"
    echo -e "  ${RED}stop${NC}                Stop all containers"
    echo -e "  ${YELLOW}restart${NC}             Rebuild and restart (applies code changes)"
    echo -e "  ${BLUE}status${NC}              Container status + runtime count"
    echo -e "  ${BLUE}logs${NC} [service]      Tail logs  (service: api1 | api2 | api3 | frontend)"
    echo -e "  ${CYAN}runtimes${NC}            List installed language runtimes"
    echo -e "  ${CYAN}install${NC} <lang>      Install a specific language runtime"
    echo -e "  ${CYAN}list${NC}                List all available packages from registry"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ./deploy.sh start"
    echo -e "  ./deploy.sh install python"
    echo -e "  ./deploy.sh install javascript"
    echo -e "  ./deploy.sh logs api1"
    echo -e "  ./deploy.sh runtimes"
    echo -e "  ./deploy.sh restart"
    echo ""
    echo -e "${BOLD}Platform:${NC}  ${PLATFORM}"
    if [[ "$PLATFORM" == "linux" ]]; then
        echo -e "${BOLD}Prod tips:${NC}"
        echo -e "  • Firewall: sudo ufw allow 8080/tcp && sudo ufw deny 2000/tcp"
        echo -e "  • cgroup v2: required — Ubuntu 22.04+ has it by default"
        echo -e "  • Auto-start: containers use 'restart: always' (survives reboots)"
        echo -e "  • Logs:       sudo journalctl -u docker or ./deploy.sh logs"
    fi
    echo ""
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-help}" in
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    restart)  cmd_restart ;;
    status)   cmd_status ;;
    logs)     cmd_logs "${2:-}" ;;
    install)  cmd_install "${2:-}" ;;
    list)     cmd_list ;;
    runtimes) cmd_runtimes ;;
    help|--help|-h) cmd_help ;;
    *)
        echo -e "${RED}Unknown command: ${1}${NC}"
        echo ""
        cmd_help
        exit 1
        ;;
esac

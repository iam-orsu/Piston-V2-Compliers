#!/bin/bash
set -e

# ── Colors ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Detect compose command ─────────────────────────────────────────────────
if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
elif docker-compose version &>/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo -e "${RED}Error: docker compose is not installed.${NC}"
    exit 1
fi

# ── Banner ─────────────────────────────────────────────────────────────────
banner() {
    echo -e "${BLUE}${BOLD}"
    echo "  ██████╗ ██╗███████╗████████╗ ██████╗ ███╗   ██╗"
    echo "  ██╔══██╗██║██╔════╝╚══██╔══╝██╔═══██╗████╗  ██║"
    echo "  ██████╔╝██║███████╗   ██║   ██║   ██║██╔██╗ ██║"
    echo "  ██╔═══╝ ██║╚════██║   ██║   ██║   ██║██║╚██╗██║"
    echo "  ██║     ██║███████║   ██║   ╚██████╔╝██║ ╚████║"
    echo "  ╚═╝     ╚═╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═══╝"
    echo -e "${NC}${CYAN}  Code Execution Engine + IDE${NC}"
    echo ""
}

# Default runtimes to auto-install on first start
DEFAULT_RUNTIMES=(python javascript typescript java c++ go rust bash)

# ── Helpers ────────────────────────────────────────────────────────────────

# Wait for the Piston API to be ready (up to 30s)
wait_for_api() {
    echo -e "${YELLOW}⏳  Waiting for Piston API to be ready...${NC}"
    for i in $(seq 1 30); do
        if curl -sf http://localhost:2000/api/v2/runtimes > /dev/null 2>&1; then
            echo -e "${GREEN}✅  API is ready.${NC}"
            return 0
        fi
        sleep 1
    done
    echo -e "${RED}⚠️  API did not become ready in time. Check: ./deploy.sh logs api${NC}"
    return 1
}

# Ensure CLI node_modules are installed
ensure_cli_deps() {
    if [ ! -d "cli/node_modules" ]; then
        echo -e "${YELLOW}📦  Installing CLI dependencies...${NC}"
        (cd cli && npm install --silent)
    fi
}

# Install a single runtime, skip if already installed
install_runtime() {
    local lang="$1"
    local already
    already=$(curl -sf http://localhost:2000/api/v2/runtimes 2>/dev/null | grep -o "\"language\":\"${lang}\"" || true)
    if [ -n "$already" ]; then
        echo -e "   ${BLUE}↷  ${lang} already installed, skipping.${NC}"
        return
    fi
    echo -e "   ${YELLOW}⬇  Installing ${BOLD}${lang}${NC}${YELLOW}...${NC}"
    node cli/index.js ppman install "$lang" 2>&1 | tail -1
}

# Auto-install all default runtimes if none are present
auto_install_runtimes() {
    ensure_cli_deps

    local count
    count=$(curl -sf http://localhost:2000/api/v2/runtimes 2>/dev/null | grep -o '"language"' | wc -l || echo 0)

    if [ "$count" -gt 0 ]; then
        echo -e "${GREEN}✅  Runtimes already installed (${count} found), skipping auto-install.${NC}"
        return
    fi

    echo ""
    echo -e "${CYAN}${BOLD}🚀  First run — auto-installing default language runtimes...${NC}"
    echo -e "${YELLOW}   This may take a few minutes depending on your internet speed.${NC}"
    echo ""

    for lang in "${DEFAULT_RUNTIMES[@]}"; do
        install_runtime "$lang"
    done

    echo ""
    echo -e "${GREEN}${BOLD}✅  All default runtimes installed!${NC}"
}

# ── Commands ───────────────────────────────────────────────────────────────

cmd_start() {
    banner
    echo -e "${GREEN}▶  Starting Piston IDE...${NC}"
    echo ""

    # Ensure data directory exists
    mkdir -p data/piston/packages

    $COMPOSE up -d --build

    # Wait for API then auto-install runtimes
    if wait_for_api; then
        auto_install_runtimes
    fi

    echo ""
    echo -e "${GREEN}${BOLD}✅  Piston IDE is ready!${NC}"
    echo ""
    echo -e "   ${BOLD}📝 Code Editor UI${NC}  →  ${CYAN}http://localhost:8080${NC}"
    echo -e "   ${BOLD}🔌 Piston API${NC}      →  ${CYAN}http://localhost:2000${NC}"
    echo ""
}

cmd_stop() {
    echo -e "${RED}■  Stopping Piston IDE...${NC}"
    $COMPOSE down
    echo -e "${GREEN}✅  All containers stopped.${NC}"
}

cmd_restart() {
    echo -e "${YELLOW}↺  Restarting Piston IDE...${NC}"
    $COMPOSE down
    $COMPOSE up -d --build
    echo ""
    echo -e "${GREEN}${BOLD}✅  Restarted!${NC}"
    echo -e "   📝 Code Editor UI  →  ${CYAN}http://localhost:8080${NC}"
    echo ""
}

cmd_status() {
    echo -e "${BLUE}${BOLD}● Container Status${NC}"
    echo ""
    $COMPOSE ps
    echo ""
}

cmd_logs() {
    local service="${2:-}"
    echo -e "${BLUE}${BOLD}● Streaming logs${service:+ ($service)}...${NC}  (Ctrl+C to stop)"
    echo ""
    $COMPOSE logs -f --tail=50 $service
}

cmd_install() {
    local lang="${2:-}"
    if [ -z "$lang" ]; then
        echo -e "${RED}Usage: ./deploy.sh install <language>${NC}"
        echo -e "       ./deploy.sh install python"
        exit 1
    fi

    # Check CLI deps
    if [ ! -d "cli/node_modules" ]; then
        echo -e "${YELLOW}Installing CLI dependencies...${NC}"
        cd cli && npm install --silent && cd ..
    fi

    echo -e "${YELLOW}⬇  Installing runtime: ${BOLD}$lang${NC}"
    node cli/index.js ppman install "$lang"
    echo -e "${GREEN}✅  Done! Refresh the IDE to see $lang in the language list.${NC}"
}

cmd_list() {
    if [ ! -d "cli/node_modules" ]; then
        echo -e "${YELLOW}Installing CLI dependencies...${NC}"
        cd cli && npm install --silent && cd ..
    fi
    echo -e "${BLUE}${BOLD}Available language runtimes:${NC}"
    node cli/index.js ppman list
}

cmd_help() {
    banner
    echo -e "${BOLD}Usage:${NC}  ./deploy.sh <command> [options]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${GREEN}start${NC}              Start Piston API + IDE frontend"
    echo -e "  ${RED}stop${NC}               Stop all containers"
    echo -e "  ${YELLOW}restart${NC}            Restart everything (applies code changes)"
    echo -e "  ${BLUE}status${NC}             Show container status"
    echo -e "  ${BLUE}logs${NC} [service]     Tail logs  (service: api | frontend)"
    echo -e "  ${CYAN}install${NC} <lang>     Install a language runtime"
    echo -e "  ${CYAN}list${NC}               List all available language packages"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ./deploy.sh start"
    echo -e "  ./deploy.sh install python"
    echo -e "  ./deploy.sh install javascript"
    echo -e "  ./deploy.sh logs api"
    echo -e "  ./deploy.sh restart"
    echo ""
}

# ── Dispatch ───────────────────────────────────────────────────────────────
case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    logs)    cmd_logs "$@" ;;
    install) cmd_install "$@" ;;
    list)    cmd_list ;;
    help|--help|-h) cmd_help ;;
    *)
        echo -e "${RED}Unknown command: ${1:-<none>}${NC}"
        echo ""
        cmd_help
        exit 1
        ;;
esac

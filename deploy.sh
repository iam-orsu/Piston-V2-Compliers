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

# Pinned to exact versions known to work on Debian Bookworm.
# Format: language=version  (used by auto_install_runtimes and install_runtime)
DEFAULT_RUNTIMES=(
    "python=3.12.0"
    "node=20.11.1"
    "typescript=5.0.3"
    "java=15.0.2"
    "gcc=10.2.0"
    "go=1.16.2"
    "rust=1.68.2"
    "bash=5.2.0"
    "mono="
    "rscript="
    "ruby="
    "sqlite3="
)

# Custom AI/ML package compiled from source inside the container.
# NOT in the remote registry — handled by build_datascience_runtime().
DS_PKG_VERSION="3.12.7"

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

check_ulimits() {
    # 500 concurrent WebSocket sessions each holding a file descriptor —
    # the kernel hard limit must be at least 65535 or the API will hit EMFILE.
    if [[ "$PLATFORM" == "linux" ]]; then
        local hard_limit
        hard_limit=$(ulimit -Hn 2>/dev/null || echo "0")
        if [[ "$hard_limit" != "unlimited" && "${hard_limit:-0}" -lt 65535 ]]; then
            warn "Open file descriptor hard limit is ${hard_limit} (need ≥ 65535 for 500 concurrent sessions)"
            info "Fix — add these lines to /etc/security/limits.conf, then reboot or re-login:"
            info "  *    soft    nofile    65536"
            info "  *    hard    nofile    65536"
            info "Also add to /etc/sysctl.conf and run 'sudo sysctl -p':"
            info "  fs.file-max = 200000"
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
    echo -e "${YELLOW}⏳  Waiting for Piston API...${NC}"
    local attempts=0
    while [[ $attempts -lt 90 ]]; do
        if curl -sf http://localhost/api/v2/runtimes &>/dev/null; then
            echo -e "${GREEN}✅  API is ready.${NC}"
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    warn "API did not become ready in 180s. Run: ./deploy.sh logs api1"
    return 1
}

runtime_count() {
    curl -sf http://localhost/api/v2/runtimes 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null \
        || echo "0"
}

ensure_cli_deps() {
    if [[ ! -d "$SCRIPT_DIR/cli/node_modules" ]]; then
        log "Installing CLI dependencies..."
        (cd "$SCRIPT_DIR/cli" && npm install --silent)
    fi
}

# Install a single runtime by calling POST /api/v2/packages directly via curl.
# No dependency on node being installed on the host.
# Usage: install_runtime python 3.12.0
install_runtime() {
    local lang="$1"
    local ver="${2:-}"

    # Skip if already installed
    if curl -sf http://localhost/api/v2/runtimes 2>/dev/null \
            | grep -q "\"language\":\"${lang}\""; then
        step "$lang already installed — skipping."
        return 0
    fi

    # If no version given, look up the latest from the remote package index.
    # Index format (CSV): language,version,sha256,url
    # Use semver sort to pick the highest version (not alphabetical tail).
    if [[ -z "$ver" ]]; then
        ver=$(curl -sfL 'https://github.com/engineer-man/piston/releases/download/pkgs/index' \
            2>/dev/null \
            | grep "^${lang}," \
            | cut -d',' -f2 \
            | python3 -c "
import sys, re
vers = [l.strip() for l in sys.stdin if l.strip()]
def semver_key(v):
    parts = re.split(r'[.\-]', v)
    return [int(p) if p.isdigit() else p for p in parts]
if vers:
    print(sorted(vers, key=semver_key)[-1])
" 2>/dev/null || echo "")
        if [[ -z "$ver" ]]; then
            warn "Could not find $lang in the package registry — try: ./deploy.sh install $lang <version>"
            return 1
        fi
    fi

    echo -e "   ${YELLOW}⬇  Installing ${BOLD}${lang}=${ver}${NC}${YELLOW}...${NC}"
    local response
    # Use printf %s to safely encode lang/ver — prevents JSON injection if either
    # value contains quotes, braces, or other special characters.
    local json_body
    json_body=$(printf '{"language":"%s","version":"%s"}' \
        "$(printf '%s' "$lang" | sed 's/["\\]/\\&/g')" \
        "$(printf '%s' "$ver"  | sed 's/["\\]/\\&/g')")
    response=$(curl -sf -X POST http://localhost/api/v2/packages \
        -H 'Content-Type: application/json' \
        -d "$json_body" 2>&1)
    local exit_code=$?
    if [[ $exit_code -ne 0 || "$response" == *'"message"'* ]]; then
        warn "Failed to install $lang — run './deploy.sh logs api1' for details"
        [[ -n "$response" ]] && warn "  $response"
        return 1
    fi
    step "$lang=$ver installed."
}

# On startup: install any DEFAULT_RUNTIMES that are missing from the packages volume.
# Uses the remote registry. Skips runtimes that are already present.
auto_install_runtimes() {
    echo ""
    echo -e "${CYAN}${BOLD}🚀  Checking default runtimes...${NC}"

    local runtimes_json
    runtimes_json=$(curl -sf http://localhost/api/v2/runtimes 2>/dev/null || echo "[]")

    local missing_langs=()
    local missing_vers=()
    for entry in "${DEFAULT_RUNTIMES[@]}"; do
        local lang ver
        lang="${entry%%=*}"
        ver="${entry##*=}"
        if echo "$runtimes_json" | grep -q "\"language\":\"${lang}\""; then
            step "${lang}  ${ver}"
        else
            missing_langs+=("$lang")
            missing_vers+=("$ver")
        fi
    done

    if [[ ${#missing_langs[@]} -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}${BOLD}✅  All default runtimes are present.${NC}"
        return 0
    fi

    echo ""
    echo -e "${CYAN}  Installing missing runtimes (this may take a few minutes)...${NC}"
    local installed_count=0
    for i in "${!missing_langs[@]}"; do
        if install_runtime "${missing_langs[$i]}" "${missing_vers[$i]}"; then
            installed_count=$((installed_count + 1))
        fi
    done

    # Runtimes are loaded into memory at container startup.
    # After installing packages we must restart the API replicas so they
    # re-scan the packages directory and register the new languages.
    if [[ $installed_count -gt 0 ]]; then
        echo ""
        echo -e "${CYAN}  Restarting API replicas to load new runtimes...${NC}"
        $DC restart api1 api2 api3 2>/dev/null || true
        wait_for_api || true
    fi

    echo ""
    echo -e "${GREEN}${BOLD}✅  Runtime installation complete.${NC}"
}

# Patch language runtimes whose scripts differ from the registry defaults.
# Called after auto_install_runtimes so the packages directory already exists.
# Safe to re-run — it only overwrites the specific files we need to change.
patch_runtimes() {
    echo ""
    echo -e "${CYAN}${BOLD}🔧  Patching language runtimes...${NC}"

    # ── Java ─────────────────────────────────────────────────────────────────
    # The registry run script uses the Java source launcher (java File.java),
    # which recompiles a single file and cannot resolve multi-file workspace
    # classes. We replace it with a proper compile + run split.
    local java_pkg
    java_pkg=$(docker exec piston_api1 \
        find /piston/packages/java -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)

    if [[ -z "$java_pkg" ]]; then
        warn "Java package not found in volume — skipping patch (install java first)"
    else
        step "Patching java runtime at ${java_pkg}"

        local compile_src="$SCRIPT_DIR/packages/java/15.0.2/compile"
        local run_src="$SCRIPT_DIR/packages/java/15.0.2/run"

        if [[ ! -f "$compile_src" ]]; then
            warn "packages/java/15.0.2/compile missing from repo — cannot patch"
        else
            step "  compile src: $compile_src"
            step "  run src:     $run_src"

            docker cp "$compile_src" "piston_api1:${java_pkg}/compile" \
                && step "  compile cp OK" || warn "  compile cp FAILED"
            docker cp "$run_src"     "piston_api1:${java_pkg}/run" \
                && step "  run cp OK"     || warn "  run cp FAILED"

            # Strip Windows CRLF line endings in case files were checked out on Windows
            docker exec piston_api1 \
                sed -i 's/\r//' "${java_pkg}/compile" "${java_pkg}/run" 2>/dev/null || true
            docker exec piston_api1 \
                chmod +x "${java_pkg}/compile" "${java_pkg}/run"

            if docker exec piston_api1 test -f "${java_pkg}/compile"; then
                step "Java compile script contents:"
                docker exec piston_api1 cat "${java_pkg}/compile"
                step "Java runtime patched successfully."
            else
                warn "Java compile script still missing after cp"
            fi
        fi
    fi

    # No container restart needed — runtime.compiled is lazily evaluated per-job.
    # The patched compile script will be picked up on the next Java execution.
    echo ""
    echo -e "${GREEN}${BOLD}✅  Runtime patches applied.${NC}"
}

# Build and install the python-datascience runtime inside the running container.
# This custom package is NOT in the remote registry so install_runtime() cannot
# be used. Python 3.12 is compiled from source and the DS library stack is
# installed via pip. The compiled output lives in the packages volume so it
# survives container restarts. pkg-info.json is written only after a successful
# build so a failed build is automatically retried on the next deploy.
build_datascience_runtime() {
    local DS_PKG_DIR="/piston/packages/python-datascience/${DS_PKG_VERSION}"

    echo ""
    echo -e "${CYAN}${BOLD}🧪  Checking AI/ML data-science runtime...${NC}"

    # Skip rebuild if pkg-info.json exists (written only after a successful build).
    if docker exec piston_api1 test -f "${DS_PKG_DIR}/pkg-info.json" 2>/dev/null; then
        # index.js filters packages by .ppman-installed at startup. If it's missing
        # (e.g., older deploy), touch it and restart so the runtime is actually loaded.
        if ! docker exec piston_api1 test -f "${DS_PKG_DIR}/.ppman-installed" 2>/dev/null; then
            docker exec piston_api1 touch "${DS_PKG_DIR}/.ppman-installed"
            step "python-datascience ${DS_PKG_VERSION}: install marker repaired — restarting API..."
            $DC restart api1 api2 api3 2>/dev/null || true
            wait_for_api
        else
            step "python-datascience ${DS_PKG_VERSION} already installed — skipping build."
        fi
        return 0
    fi

    local src_dir="${SCRIPT_DIR}/packages/python-datascience/${DS_PKG_VERSION}"
    if [[ ! -f "${src_dir}/build.sh" ]]; then
        warn "python-datascience source not found at ${src_dir} — DS runtime will not be available."
        return 1
    fi

    echo ""
    echo -e "   ${YELLOW}${BOLD}python-datascience ${DS_PKG_VERSION} is not installed.${NC}"
    echo -e "   ${CYAN}Bundles: NumPy · Pandas · Matplotlib · Seaborn · scikit-learn · SciPy · Pillow · Statsmodels · Plotly${NC}"
    echo ""
    echo -e "   ${YELLOW}⏱  Installing Python 3.12 (pre-built) — one-time setup, expect 5-8 minutes.${NC}"
    echo ""

    # ── Step 1: Ensure curl is available in the container ────────────────────
    # build.sh downloads a pre-built Python binary (no compilation needed).
    step "Ensuring curl is available in container..."
    docker exec piston_api1 bash -c "
        command -v curl >/dev/null 2>&1 || (export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y --no-install-recommends curl 2>&1 | tail -3)
    " || { warn "Failed to install curl — check apt sources inside container"; return 1; }
    step "curl ready."

    # ── Step 2: Copy package source into the container volume ────────────────
    step "Copying package source files..."
    docker exec piston_api1 mkdir -p "${DS_PKG_DIR}"

    for f in build.sh run environment metadata.json; do
        docker cp "${src_dir}/${f}" "piston_api1:${DS_PKG_DIR}/${f}" \
            || { warn "Failed to copy ${f} — missing from packages/python-datascience/${DS_PKG_VERSION}/"; return 1; }
    done

    # Strip Windows CRLF line endings (files may be checked out on Windows)
    docker exec piston_api1 bash -c "
        sed -i 's/\r//' \
            '${DS_PKG_DIR}/build.sh' \
            '${DS_PKG_DIR}/run' \
            '${DS_PKG_DIR}/environment'
    " 2>/dev/null || true

    docker exec piston_api1 chmod +x \
        "${DS_PKG_DIR}/build.sh" \
        "${DS_PKG_DIR}/run" \
        "${DS_PKG_DIR}/environment"
    step "Source files ready."

    # ── Step 3: Compile Python and install DS library stack ──────────────────
    echo ""
    echo -e "   ${CYAN}▶  Running build.sh — downloading Python 3.12 pre-built binary and pip-installing DS stack...${NC}"
    echo ""

    if docker exec piston_api1 bash -c "cd '${DS_PKG_DIR}' && bash ./build.sh"; then
        step "Python 3.12 + DS stack built successfully."
    else
        warn "python-datascience build FAILED."
        warn "To debug: docker exec -it piston_api1 bash"
        warn "          then: cd ${DS_PKG_DIR} && bash ./build.sh"
        return 1
    fi

    # ── Step 4: Write pkg-info.json (marks runtime as ready for loading) ─────
    # runtime.js scans each package dir for pkg-info.json on startup.
    # Writing it only here ensures a partially-built package is never loaded.
    step "Writing pkg-info.json..."
    docker exec piston_api1 node -e "
const fs = require('fs');
const meta = JSON.parse(fs.readFileSync('${DS_PKG_DIR}/metadata.json', 'utf8'));
meta.build_platform = 'docker-debian';
fs.writeFileSync('${DS_PKG_DIR}/pkg-info.json', JSON.stringify(meta, null, 2));
process.stdout.write('pkg-info.json written\n');
" || { warn "Failed to write pkg-info.json — check node is available in container"; return 1; }

    # Mark package as installed — index.js filters by this file at startup
    docker exec piston_api1 touch "${DS_PKG_DIR}/.ppman-installed" \
        || { warn "Failed to create .ppman-installed"; return 1; }

    # ── Step 5: Restart API replicas so they pick up the new runtime ─────────
    echo ""
    echo -e "${GREEN}${BOLD}✅  python-datascience ${DS_PKG_VERSION} installed.${NC}"
    echo -e "${CYAN}   Restarting API replicas to load the new runtime...${NC}"
    $DC restart api1 api2 api3 2>/dev/null || true
    wait_for_api
}

# ── Commands ─────────────────────────────────────────────────────────────────
build_sandbox_image() {
    echo -e "${CYAN}${BOLD}🔒  Building hardened sandbox image...${NC}"
    docker build -t piston-sandbox:latest "$SCRIPT_DIR/sandbox" \
        --label "piston.role=sandbox" \
    && echo -e "${GREEN}✅  piston-sandbox image ready.${NC}" \
    || { warn "Sandbox image build failed — terminal shell tab will not work"; }
}

cmd_start() {
    banner
    check_docker
    check_disk_space
    check_cgroup_v2
    check_ulimits
    check_port_conflict 80

    if [[ "$PLATFORM" == "wsl2" ]]; then
        info "Windows/WSL2 mode: packages stored in Docker named volume (Linux fs)"
    else
        info "Linux mode: standard configuration"
    fi

    build_sandbox_image

    log "Building and starting containers..."
    $DC up -d --build --remove-orphans

    if wait_for_api; then
        auto_install_runtimes
        patch_runtimes
        build_datascience_runtime || warn "AI/ML runtime build did not complete — run ./deploy.sh restart to retry"
    fi

    print_ready_banner
}

print_ready_banner() {
    local ip
    if [[ "$PLATFORM" == "wsl2" ]]; then
        ip="localhost"
    else
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    fi

    # Wait up to 15s for nginx to be reachable
    local fe_ok=0
    for _ in {1..15}; do
        if curl -sf "http://localhost" &>/dev/null; then
            fe_ok=1; break
        fi
        sleep 1
    done

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║          PISTON IDE — DEPLOYMENT COMPLETE        ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "   ${BOLD}📝  Code Editor UI${NC}"
    echo -e "       ${CYAN}${BOLD}http://${ip}${NC}"
    echo ""
    echo -e "   ${BOLD}🔌  API Endpoint (for developers / external UIs)${NC}"
    echo -e "       ${CYAN}${BOLD}http://${ip}:2000/api/v2/${NC}"
    echo -e "       POST /api/v2/execute   — run code"
    echo -e "       GET  /api/v2/runtimes  — list languages"
    echo -e "       WS   /api/v2/connect   — interactive terminal"
    echo ""
    $DC ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || $DC ps
    echo ""
    if [[ "$fe_ok" -eq 0 ]]; then
        warn "Frontend did not respond on port 80 — check: ./deploy.sh logs nginx"
    else
        echo -e "${GREEN}${BOLD}✅  All systems operational. Open the URL above in your browser.${NC}"
    fi
    if [[ "$PLATFORM" == "linux" ]]; then
        echo ""
        echo -e "   ${YELLOW}🔒 Firewall tip:${NC}"
        echo -e "      sudo ufw allow 80/tcp"
    fi
    echo ""
}

cmd_stop() {
    check_docker
    log "Stopping Piston IDE..."
    # Kill any lingering student sandbox containers first
    local orphans
    orphans=$(docker ps -q --filter "name=student-" 2>/dev/null || true)
    if [[ -n "$orphans" ]]; then
        echo -e "   ${YELLOW}⚡  Removing student sandbox containers...${NC}"
        # shellcheck disable=SC2086
        docker rm -f $orphans 2>/dev/null || true
    fi
    $DC down --remove-orphans
    echo -e "${GREEN}✅  All containers stopped.${NC}"
}

cmd_restart() {
    check_docker
    build_sandbox_image
    log "Rebuilding and restarting (applying changes)..."
    $DC up -d --build --remove-orphans
    if wait_for_api; then
        auto_install_runtimes
        patch_runtimes
        build_datascience_runtime || warn "AI/ML runtime build did not complete — run ./deploy.sh restart to retry"
    fi
    print_ready_banner
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
    echo -e "   ${CYAN}ℹ  3 API replicas running — capacity: ~2300 concurrent students${NC}"
    echo -e "   ${CYAN}ℹ  Per-job memory limit: 256 MB · Run timeout: 15s${NC}"
    echo ""

    local ds_dir="/piston/packages/python-datascience/${DS_PKG_VERSION}"
    if docker exec piston_api1 test -f "${ds_dir}/.ppman-installed" 2>/dev/null; then
        echo -e "   ${GREEN}✅  AI/ML runtime: python-datascience ${DS_PKG_VERSION} installed${NC}"
    else
        echo -e "   ${YELLOW}⚠  AI/ML runtime: python-datascience not yet built${NC}"
        echo -e "      Run ./deploy.sh restart to trigger the one-time build (20-35 min)."
    fi
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
    local ver="${2:-}"
    [[ -z "$lang" ]] && err "Usage: ./deploy.sh install <language> [version]  (e.g. python, java=15.0.2)"
    check_docker
    wait_for_api
    install_runtime "$lang" "$ver"
    echo -e "${GREEN}✅  Done! Refresh the IDE to see ${lang} in the dropdown.${NC}"
}

cmd_patch() {
    check_docker
    patch_runtimes
}

cmd_list() {
    check_docker
    echo -e "${BLUE}${BOLD}Available packages from registry:${NC}"
    curl -sfL 'https://github.com/engineer-man/piston/releases/download/pkgs/index' \
        2>/dev/null \
        | awk -F',' '{printf "  %-20s %s\n", $1, $2}' \
        | sort \
        || warn "Could not fetch package registry — check internet connectivity"
}

cmd_runtimes() {
    check_docker
    echo -e "${BLUE}${BOLD}Installed runtimes:${NC}"
    curl -sf http://localhost/api/v2/runtimes 2>/dev/null \
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
    echo -e "  ${CYAN}patch${NC}               Re-apply runtime script patches (e.g. Java multi-file)"
    echo ""
    echo -e "${BOLD}AI/ML / Data Science runtime:${NC}"
    echo -e "  python-datascience is installed automatically on first start/restart."
    echo -e "  One-time install — ~5-8 min (pre-built binary, no compilation). Subsequent restarts skip it."
    echo -e "  Libraries: NumPy · Pandas · Matplotlib · Seaborn · scikit-learn · SciPy · Pillow · Statsmodels · Plotly"
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
        echo -e "  • Firewall: sudo ufw allow 80/tcp"
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
    patch)    cmd_patch ;;
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

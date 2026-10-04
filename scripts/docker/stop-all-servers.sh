#!/bin/bash

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_header() { echo -e "\n# --- $1 ---"; }
print_step() { echo -e "  → $1..."; }
print_success() { echo -e "  ✓ $1"; }
print_info() { echo -e "  - $1"; }

require_cmd() {
    if ! command -v "$1" &> /dev/null; then
        printf "\n  %b! %s is not installed.%b %s\n\n" "${RED}" "$1" "${NC}" "$2" >&2
        exit 1
    fi
}

require_docker() {
    require_cmd docker "Install Docker Desktop: https://docs.docker.com/get-docker/"
    if ! docker info &> /dev/null; then
        printf "\n  %b! Docker is installed but not running.%b Start it and try again.\n\n" "${RED}" "${NC}" >&2
        exit 1
    fi
}

require_docker

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    LINK_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
    SOURCE="$( readlink "$SOURCE" )"
    [[ "$SOURCE" != /* ]] && SOURCE="$LINK_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR/../.." || exit 1

print_header "STOPPING ALL STRATA SERVERS"
print_step "Stopping active Docker containers"

RUNNING=$(docker ps -q --filter "name=^strata")
[ -n "$RUNNING" ] && docker stop $RUNNING > /dev/null 2>&1

ENV_ARGS=()
[ -f .env ] && ENV_ARGS=(--env-file .env)
for COMPOSE in docker/*.yml; do
    [ -f "$COMPOSE" ] || continue
    STRATA_REF=${STRATA_REF:-none} STRATA_FAMILY=${STRATA_FAMILY:-none} STRATA_MODEL=${STRATA_MODEL:-none} \
        docker compose "${ENV_ARGS[@]}" -f "$COMPOSE" down > /dev/null 2>&1
done

print_success "All server instances stopped"

print_header "RESOURCING STATUS"
if command -v nvidia-smi &> /dev/null; then
    print_info "VRAM currently used: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -n 1) MiB"
fi
if command -v free &> /dev/null; then
    print_info "Free System RAM: $(free -h | awk '/^Mem:/ {print $4}')"
fi

echo -e "\n${CYAN}--------------------------------------------${NC}\n"

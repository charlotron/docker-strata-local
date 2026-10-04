#!/bin/bash

# --- Colors and Aesthetics ---
BOLD='\033[1m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_header() { printf "\n%b# --- %s ---%b\n" "${BOLD}${BLUE}" "$1" "${NC}"; }
print_step() { printf "  → %s...\n" "$1"; }
print_success() { printf "  %b✓%b %s\n" "${GREEN}" "${NC}" "$1"; }
print_warn() { printf "  %b! %s%b\n" "${YELLOW}" "$1" "${NC}"; }
print_error() { printf "  %b! ERROR:%b %s\n" "${RED}" "${NC}" "$1"; }
print_info() { printf "  - %s: %s\n" "$1" "$2"; }

# --- Dependency checks ---
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
require_cmd curl "Install it with your package manager."

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    LINK_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
    SOURCE="$( readlink "$SOURCE" )"
    [[ "$SOURCE" != /* ]] && SOURCE="$LINK_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
INVOCATION_DIR="$PWD"
cd "$SCRIPT_DIR/../.." || exit 1

print_header "LOCAL INFRASTRUCTURE"

ENV_FILE="${1:-.env}"
if [ -n "$1" ] && [[ "$ENV_FILE" != /* ]]; then
    ENV_FILE="$INVOCATION_DIR/$ENV_FILE"
fi

if [ -f "$ENV_FILE" ]; then
    print_step "Loading configuration ($ENV_FILE)"
    set -a
    source "$ENV_FILE"
    set +a
    print_success "Configuration loaded"
else
    print_error "$ENV_FILE not found"
    exit 1
fi

for required in COMPOSE_FILE STRATA_REF STRATA_FAMILY STRATA_MODEL; do
    if [ -z "${!required}" ]; then
        print_error "$required is not set in $ENV_FILE"
        exit 1
    fi
done

STRATA_PORT=${STRATA_PORT:-12345}
STRATA_HOST=${STRATA_HOST:-127.0.0.1}
STRATA_START_TIMEOUT=${STRATA_START_TIMEOUT:-10800}

# Compose resolves a relative path against the compose file's directory, not
# the repo root, so hand it an absolute one.
DATA_DIR="${STRATA_DATA_DIR:-./docker/data/strata}"
mkdir -p "$DATA_DIR"
export STRATA_DATA_DIR="$(cd "$DATA_DIR" && pwd)"

CONTAINER_NAME=$(grep -m1 'container_name:' "$COMPOSE_FILE" | sed 's/.*container_name:[[:space:]]*//')
if [ -z "$CONTAINER_NAME" ]; then
    print_error "No container_name in $COMPOSE_FILE"
    exit 1
fi
IMAGE="strata-local:$STRATA_REF"

print_header "MODEL CONFIGURATION"
print_info "Strata ref" "$STRATA_REF"
print_info "Model     " "$STRATA_FAMILY / $STRATA_MODEL"
print_info "Context   " "${STRATA_CONTEXT_SIZE:-131072}"
print_info "Data dir  " "$STRATA_DATA_DIR"
print_info "Port      " "$STRATA_PORT"

# The experts are mapped from disk and the rest needs headroom: below this the
# VM thrashes instead of failing cleanly.
VM_RAM_GB=$(awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null)
if [ -n "$VM_RAM_GB" ] && [ "$VM_RAM_GB" -lt 26 ]; then
    print_warn "This VM sees only ${VM_RAM_GB} GB of RAM. Set memory=28GB in %USERPROFILE%\\.wslconfig and run 'wsl --shutdown' (see AGENTS.md)."
fi

print_header "IMAGE"
BASE_IMAGE="strata-upstream:$STRATA_REF"
if docker image inspect "$BASE_IMAGE" &> /dev/null; then
    print_success "$BASE_IMAGE already built"
else
    print_step "Building $BASE_IMAGE from Strata's Dockerfile (compiles the CUDA engine)"
    if ! docker build -t "$BASE_IMAGE" \
            --build-arg CUDA_ARCHITECTURES="${STRATA_CUDA_ARCH:-89}" --build-arg BUILD_VISION=0 \
            "https://github.com/Niko1221/Strata.git#$STRATA_REF"; then
        print_error "Base image build failed"
        exit 1
    fi
fi
# Cached when docker/strata is unchanged; rebuilds the engine when a patch changes.
print_step "Applying local patches ($IMAGE)"
if ! docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" build; then
    print_error "Image build failed"
    exit 1
fi
print_success "$IMAGE ready"

print_header "DOCKER DEPLOYMENT"
print_step "Restarting services"

# llama.cpp and Strata containers share the port and the 12 GB GPU: only one runs.
RUNNING=$(docker ps -q --filter "name=^llama-cpp"; docker ps -q --filter "name=^strata")
[ -n "$RUNNING" ] && docker stop $RUNNING > /dev/null 2>&1
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down > /dev/null 2>&1
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d || exit 1

if [ ! -f "$STRATA_DATA_DIR/config/strata-$( [ "$STRATA_FAMILY" = qwen ] || printf '%s-' "$STRATA_FAMILY")$(printf '%s' "$STRATA_MODEL" | tr 'A-Z' 'a-z').json" ]; then
    print_warn "First start for this model: it downloads ~60 GB before serving. This can take a long time."
fi

print_step "Waiting for http://$STRATA_HOST:$STRATA_PORT/health"
printf "%b--------------------------------------------%b\n" "${CYAN}" "${NC}"

docker logs -f "$CONTAINER_NAME" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null' EXIT

ELAPSED=0
while [ $ELAPSED -lt $STRATA_START_TIMEOUT ]; do
    if curl -fs -m 3 "http://$STRATA_HOST:$STRATA_PORT/health" > /dev/null 2>&1; then
        break
    fi
    STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    if [ "$STATE" != "running" ]; then
        printf "\n%b! ERROR: Container is %s.%b\n" "${RED}" "${STATE:-gone}" "${NC}"
        print_error "Check the logs printed above."
        exit 1
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

kill $LOG_PID 2>/dev/null
if [ $ELAPSED -ge $STRATA_START_TIMEOUT ]; then
    print_error "Timeout reached (${STRATA_START_TIMEOUT}s). The container keeps running; follow it with scripts/docker/attach-server-logs.sh"
    exit 1
fi

printf "%b--------------------------------------------%b\n" "${CYAN}" "${NC}"
print_success "Server active on http://$STRATA_HOST:$STRATA_PORT (web UI, /v1 OpenAI, /v1/messages Anthropic)"
printf "%b--------------------------------------------%b\n\n" "${CYAN}" "${NC}"

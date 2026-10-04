#!/bin/bash

# --- Colors and Aesthetics ---
BOLD='\033[1m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_header() {
    echo -e "\n${MAGENTA}${BOLD}# $1${NC}"
    echo -e "${MAGENTA}--------------------------------------------${NC}"
}

print_info() { echo -e "  ${CYAN}- $1:${NC} $2"; }

require_cmd() {
    if ! command -v "$1" &> /dev/null; then
        printf "\n  %b! %s is not installed.%b %s\n\n" "${RED}" "$1" "${NC}" "$2" >&2
        exit 1
    fi
}

require_cmd opencode "Install it with: npm install -g opencode-ai"
require_cmd node "Install Node.js."
require_cmd jq "Install it with your package manager."

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    LINK_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
    SOURCE="$( readlink "$SOURCE" )"
    [[ "$SOURCE" != /* ]] && SOURCE="$LINK_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"

if [ -f "$SCRIPT_DIR/../../.env" ]; then
    set -a
    source "$SCRIPT_DIR/../../.env"
    set +a
fi

export STRATA_HOST=${STRATA_HOST:-127.0.0.1}
export STRATA_PORT=${STRATA_PORT:-12345}
export STRATA_API_KEY=${STRATA_API_KEY:-sk-local}
MODEL="strata-local/strata-local"

AUTH=()
[ "$STRATA_API_KEY" != "sk-local" ] && AUTH=(-H "Authorization: Bearer $STRATA_API_KEY")

print_header "RESOLVING STRATA CONFIGURATION"

# Strata answers /slots and /props like llama-server, so the real context and
# model come from the running server, not from the env file.
DETECTED_CTX=$(curl -s --max-time 3 "${AUTH[@]}" "http://$STRATA_HOST:$STRATA_PORT/slots" | jq '.[0].n_ctx' 2>/dev/null)
if [[ "$DETECTED_CTX" =~ ^[0-9]+$ ]]; then
    export STRATA_CONTEXT_SIZE=$DETECTED_CTX
    printf "  ${GREEN}✓ Context window from the server: ${BOLD}${STRATA_CONTEXT_SIZE} tokens${NC}\n"
else
    export STRATA_CONTEXT_SIZE=${STRATA_CONTEXT_SIZE:-131072}
    printf "  ${YELLOW}! Server unreachable. Using the configured context: ${BOLD}${STRATA_CONTEXT_SIZE} tokens${NC}\n"
fi

MODEL_NAME=$(curl -s --max-time 3 "${AUTH[@]}" "http://$STRATA_HOST:$STRATA_PORT/props" | jq -r '.model_path // empty' 2>/dev/null)
MODEL_NAME=$(basename "${MODEL_NAME:-strata-local}" .gguf)
export MODEL_NAME

# Output cap: a third of the context, at most 32768 (the full 32768 from 100K
# up, so the compaction buffer holds a whole response). Compaction keeps twice
# that, at most half the context.
STRATA_OUTPUT_LIMIT=$((STRATA_CONTEXT_SIZE / 3))
(( STRATA_OUTPUT_LIMIT > 32768 )) && STRATA_OUTPUT_LIMIT=32768
export STRATA_OUTPUT_LIMIT
export STRATA_COMPACT_BUFFER=$((STRATA_OUTPUT_LIMIT + 1000))
STRATA_COMPACT_KEEP=$((STRATA_OUTPUT_LIMIT * 2))
(( STRATA_COMPACT_KEEP > STRATA_CONTEXT_SIZE / 2 )) && STRATA_COMPACT_KEEP=$((STRATA_CONTEXT_SIZE / 2))
export STRATA_COMPACT_KEEP

export OPENCODE_CONFIG="${TMPDIR:-/tmp}/opencode-strata.json"
trap 'rm -f "$OPENCODE_CONFIG"' EXIT SIGINT SIGTERM

# Merge the global opencode.json so MCPs and plugins are kept.
node -e '
const fs = require("fs");
const path = require("path");
const env = process.env;

let base = {};
const globalPath = path.join(env.HOME, ".config", "opencode", "opencode.json");
if (fs.existsSync(globalPath)) {
  try {
    const raw = fs.readFileSync(globalPath, "utf8").trim();
    if (raw) base = JSON.parse(raw);
  } catch (e) {
    console.error("Warning: failed to parse global opencode.json:", e.message);
  }
}

const dynamic = {
  model: "strata-local/strata-local",
  autoCompact: true,
  compaction: { auto: true, keep: { tokens: Number(env.STRATA_COMPACT_KEEP) }, buffer: Number(env.STRATA_COMPACT_BUFFER) },
  performance: { maxConcurrentAgents: 1 },
  agents: { maxConcurrent: 1 },
  provider: {
    "strata-local": {
      npm: "@ai-sdk/openai-compatible",
      name: "Strata Local Server",
      options: { baseURL: "http://" + env.STRATA_HOST + ":" + env.STRATA_PORT + "/v1", apiKey: env.STRATA_API_KEY },
      models: {
        "strata-local": {
          name: env.MODEL_NAME,
          limit: { context: Number(env.STRATA_CONTEXT_SIZE), output: Number(env.STRATA_OUTPUT_LIMIT) }
        }
      }
    }
  }
};

function deepMerge(target, source) {
  for (const key of Object.keys(source)) {
    const s = source[key], t = target[key];
    if (s instanceof Object && t instanceof Object && !Array.isArray(s) && !Array.isArray(t)) deepMerge(t, s);
    else if (Array.isArray(s) && Array.isArray(t)) target[key] = Array.from(new Set([...t, ...s]));
    else target[key] = s;
  }
  return target;
}

const merged = deepMerge(base, dynamic);
if (!merged["$schema"]) merged["$schema"] = "https://opencode.ai/config.json";
fs.writeFileSync(env.OPENCODE_CONFIG, JSON.stringify(merged, null, 2), "utf8");
'

print_header "OPENCODE STRATA CLIENT"
print_info "Host " "http://$STRATA_HOST:$STRATA_PORT"
print_info "Model" "$MODEL_NAME"
echo -e "\n  ${YELLOW}! Press Ctrl+C to exit${NC}"
echo -e "${MAGENTA}--------------------------------------------${NC}\n"

if [[ "$(basename "$0")" == *"yolo"* ]]; then
    opencode "$@" --model "$MODEL" --auto
else
    opencode "$@" --model "$MODEL"
fi

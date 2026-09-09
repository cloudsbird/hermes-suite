#!/bin/bash
# =============================================================================
# down.sh — Stop Hermes Suite container
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yaml"

# --- Load config from versions.env ---
if [ -f "${SCRIPT_DIR}/versions.env" ]; then
    eval "$(grep -E '^(AGENT_VERSION|WEBUI_VERSION|CONTAINER_RUNTIME|USE_SUDO|ENABLE_BROWSER)=' "${SCRIPT_DIR}/versions.env")"
fi
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"
USE_SUDO="${USE_SUDO:-false}"

# --- Auto-detect ---
if [ "$CONTAINER_RUNTIME" = "auto" ]; then
    if command -v podman &>/dev/null; then
        CONTAINER_RUNTIME="podman"
    elif command -v docker &>/dev/null; then
        CONTAINER_RUNTIME="docker"
    else
        echo "ERROR: Neither podman nor docker found."
        exit 1
    fi
fi

# --- Determine sudo prefix ---
SUDO_PREFIX=""
if [ "$USE_SUDO" = "true" ]; then
    SUDO_PREFIX="sudo"
fi

# --- Derive image tag from versions.env ---
AGENT_VER_CLEAN="${AGENT_VERSION#v}"
WEBUI_VER_CLEAN="${WEBUI_VERSION#v}"
# Match build.sh: browser-less builds carry a -slim tag suffix
ENABLE_BROWSER="${ENABLE_BROWSER:-true}"
IMAGE_SUFFIX=""
if [ "$ENABLE_BROWSER" = "false" ]; then
    IMAGE_SUFFIX="-slim"
fi
export HERMES_SUITE_IMAGE_TAG="${AGENT_VER_CLEAN}-${WEBUI_VER_CLEAN}${IMAGE_SUFFIX}"

# For sudo: compose needs explicit env passthrough
if [ "$USE_SUDO" = "true" ]; then
    COMPOSE_PREFIX="sudo env HERMES_SUITE_IMAGE_TAG=${HERMES_SUITE_IMAGE_TAG}"
else
    COMPOSE_PREFIX=""
fi

# --- Stop ---
case "$CONTAINER_RUNTIME" in
    podman)
        export PATH="$HOME/.local/bin:$PATH"
        PODMAN_COMPOSE="$(command -v podman-compose)"
        $COMPOSE_PREFIX "$PODMAN_COMPOSE" -f "${COMPOSE_FILE}" down
        ;;
    docker|docker-nolog)
        $COMPOSE_PREFIX docker compose -f "${COMPOSE_FILE}" down
        ;;
    *)
        echo "ERROR: Unknown CONTAINER_RUNTIME: $CONTAINER_RUNTIME"
        exit 1
        ;;
esac

echo "Hermes Suite stopped."

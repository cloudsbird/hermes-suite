#!/bin/bash
# =============================================================================
# up.sh — Start Hermes Suite container
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yaml"

# --- Load config from versions.env ---
if [ -f "${SCRIPT_DIR}/versions.env" ]; then
    eval "$(grep -E '^(AGENT_VERSION|WEBUI_VERSION|CONTAINER_RUNTIME|USE_SUDO|DASHBOARD_CREDENTIAL|HERMES_WEBUI_PASSWORD|ENABLE_BROWSER)=' "${SCRIPT_DIR}/versions.env")"
fi
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"
USE_SUDO="${USE_SUDO:-false}"

# --- Dashboard credentials ---
# DASHBOARD_CREDENTIAL controls the dashboard login. Options:
#   admin:admin    — default, works immediately
#   auto           — auto-generate a random password (persisted, printed below)
#   user:password  — custom credentials
DASHBOARD_CREDENTIAL="${DASHBOARD_CREDENTIAL:-admin:admin}"

if [ "$DASHBOARD_CREDENTIAL" = "auto" ]; then
    CRED_FILE="${SCRIPT_DIR}/.dashboard_credential"
    if [ -f "$CRED_FILE" ]; then
        DASHBOARD_CREDENTIAL=$(cat "$CRED_FILE")
    else
        PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")
        DASHBOARD_CREDENTIAL="admin:${PASSWORD}"
        echo "$DASHBOARD_CREDENTIAL" > "$CRED_FILE"
        chmod 600 "$CRED_FILE"
    fi
fi

export DASHBOARD_CREDENTIAL

# --- WebUI password ---
# Separate mechanism from DASHBOARD_CREDENTIAL — hermes-webui enforces this
# itself. No default and no "auto" option; unset means no WebUI login.
export HERMES_WEBUI_PASSWORD="${HERMES_WEBUI_PASSWORD:-}"

# --- Persistent data paths ---
# Preserve the previous host-path behavior for local Podman/Docker use.
# docker-compose.yaml falls back to named volumes when these are unset
# (e.g. under Dokploy or a plain `docker compose up`).
export HERMES_DATA="${HERMES_DATA:-$HOME/.hermes}"
export HERMES_WORKSPACE="${HERMES_WORKSPACE:-$HOME/workspace}"

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
    COMPOSE_PREFIX="sudo env HERMES_SUITE_IMAGE_TAG=${HERMES_SUITE_IMAGE_TAG} DASHBOARD_CREDENTIAL=${DASHBOARD_CREDENTIAL} HERMES_WEBUI_PASSWORD=${HERMES_WEBUI_PASSWORD} HERMES_DATA=${HERMES_DATA} HERMES_WORKSPACE=${HERMES_WORKSPACE}"
else
    COMPOSE_PREFIX=""
fi

# --- Start ---
case "$CONTAINER_RUNTIME" in
    podman)
        export PATH="$HOME/.local/bin:$PATH"
        PODMAN_COMPOSE="$(command -v podman-compose)"
        $COMPOSE_PREFIX "$PODMAN_COMPOSE" -f "${COMPOSE_FILE}" up -d
        ;;
    docker|docker-nolog)
        $COMPOSE_PREFIX docker compose -f "${COMPOSE_FILE}" up -d
        ;;
    *)
        echo "ERROR: Unknown CONTAINER_RUNTIME: $CONTAINER_RUNTIME"
        exit 1
        ;;
esac

echo ""
echo "Hermes Suite is running:"
echo "  Gateway:    http://localhost:8642"
echo "  WebUI:      http://localhost:8787"
echo "  Dashboard:  http://localhost:9119"
echo ""
DASH_USER="${DASHBOARD_CREDENTIAL%%:*}"
DASH_PASS="${DASHBOARD_CREDENTIAL#*:}"
echo "  Dashboard Login ID: $DASH_USER"
echo "  Dashboard Password: $DASH_PASS"
if [ -n "$HERMES_WEBUI_PASSWORD" ]; then
    echo "  WebUI Password:     set"
else
    echo "  WebUI Password:     NOT SET — no login on the WebUI (see README: WebUI Authentication)"
fi
echo ""
echo "Logs: ./logs.sh"
echo "Stop: ./down.sh"

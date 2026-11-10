#!/bin/bash
# =============================================================================
# start.sh — Hermes Suite container entrypoint
# Handles UID/GID remapping, directory setup, and launches supervisord.
# Detects Podman vs Docker to choose the appropriate privilege model.
# Detection uses /proc/1/cgroup (reliable at runtime) rather than
# /run/.containerenv (can be baked into the image by Podman at build time).
#
# Podman path:  root → chown → s6-setuidgid hermes → re-exec → setup → supervisord (as hermes)
# Docker path:  root → setup → chown → supervisord (as root, children as hermes via user=)
# =============================================================================
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
INSTALL_DIR="/opt/hermes"

# --- Helper: runtime detection ---
# Detect Docker runtime. We check /.dockerenv first (created by Docker at
# runtime, not by Podman) to handle cgroup v2 where /proc/1/cgroup shows
# "0::/". Then fall back to cgroup v1 check as a backup. Podman-built images
# may contain a stale /run/.containerenv baked into the image layer, so that
# file alone is unreliable.
is_docker() {
    [ -f /.dockerenv ] && return 0
    grep -qaE '/docker/|docker-|containerd' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

# --- Helper: dashboard auth credential setup ---
# Upstream v2026.7.1 removed unauthenticated public dashboard access.
# Credentials are provided via DASHBOARD_CREDENTIAL env var (format:
# "username:password"), set by up.sh from versions.env. Parse and export
# the two vars the dashboard's BasicAuthProvider reads.
setup_dashboard_auth() {
    local cred="${DASHBOARD_CREDENTIAL:-admin:admin}"
    DASH_USER="${cred%%:*}"
    DASH_PASS="${cred#*:}"
    export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$DASH_USER"
    export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$DASH_PASS"
}

# --- Helper: WebUI password setup ---
# HERMES_WEBUI_PASSWORD is a separate, unrelated auth mechanism enforced by
# hermes-webui itself. docker-compose always sets this key (falling back to
# an empty string when the operator left it unset) — unset it entirely here
# so hermes-webui sees a genuinely absent variable, not an empty password.
setup_webui_auth() {
    if [ -z "${HERMES_WEBUI_PASSWORD:-}" ]; then
        unset HERMES_WEBUI_PASSWORD
    fi
}

# --- Helper: Portcullis PII gateway setup (transparent mode) ---
# Portcullis runs as a supervisord program on 127.0.0.1:8080. On by default;
# PORTCULLIS_ENABLED=false turns it off. Hermes' config is never modified: an
# httpx hook in the Hermes venvs (portcullis_hook.py) routes every LLM call
# through Portcullis while $HERMES_HOME/portcullis/transparent exists, and
# Portcullis forwards it to the real provider with Hermes' own key/headers.
# Settings go to $HERMES_HOME/portcullis/env, read by portcullis-run.sh, so the
# program survives supervisord restarts. Never blocks container startup.
setup_portcullis() {
    local state_dir="$HERMES_HOME/portcullis"
    local enabled="${PORTCULLIS_ENABLED:-true}"
    case "${enabled,,}" in false|0|no|off) enabled=false ;; *) enabled=true ;; esac
    PORTCULLIS_STATUS="NOT ACTIVE — setup failed (see log above)"
    export PORTCULLIS_STATUS

    if ! { mkdir -p "$state_dir" && chmod 700 "$state_dir" && [ -w "$state_dir" ]; } 2>/dev/null; then
        echo "Warning: $state_dir is not writable — Portcullis disabled, LLM calls NOT redacted"
        PORTCULLIS_STATUS="NOT ACTIVE — $state_dir not writable"
        return 0
    fi

    # Migration: older releases rewrote model.* in config.yaml. Put it back.
    local mig=0
    HERMES_HOME="$HERMES_HOME" python3 -I /opt/hermes-suite/portcullis-wire.py || mig=$?
    if [ "$mig" -ne 0 ]; then
        echo "Warning: config.yaml still points at Portcullis or could not be restored (see above)"
    fi

    if [ "$enabled" = "false" ]; then
        rm -f "$state_dir/transparent"
        printf 'PORTCULLIS_ENABLED=false\n' > "$state_dir/env"
        PORTCULLIS_STATUS="disabled (PORTCULLIS_ENABLED=false)"
        return 0
    fi

    # Admin token guards /teach, /unteach, /terms, /suggestions.
    local token="${PORTCULLIS_ADMIN_TOKEN:-}"
    if [ -z "$token" ]; then
        if [ ! -s "$state_dir/admin_token" ]; then
            ( umask 077 && python3 -c "import secrets; print(secrets.token_hex(24))" \
                > "$state_dir/admin_token" ) || true
        fi
        token="$(cat "$state_dir/admin_token" 2>/dev/null || true)"
    fi

    {
        echo "PORTCULLIS_ENABLED=true"
        if [ -n "$token" ]; then printf 'PORTCULLIS_ADMIN_TOKEN=%q\n' "$token"; fi
        for v in PORTCULLIS_MODEL_DIR PORTCULLIS_THRESHOLD PORTCULLIS_STORE_KEY_FILE PORTCULLIS_LOG_FORMAT; do
            if [ -n "${!v:-}" ]; then printf '%s=%q\n' "$v" "${!v}"; fi
        done
        true
    } > "$state_dir/env.tmp" && chmod 600 "$state_dir/env.tmp" && mv "$state_dir/env.tmp" "$state_dir/env"

    # Turns the httpx hook on (it checks for this file on every request).
    : > "$state_dir/transparent"

    # Report what is really loaded, not what should be: the hook must have been
    # imported by its .pth in both venvs that make LLM calls.
    local py missing=""
    for py in /opt/hermes/.venv/bin/python3 /opt/hermes-webui/venv/bin/python3; do
        if [ -x "$py" ] && ! "$py" /opt/hermes-suite/portcullis-hook-check.py >/dev/null 2>&1; then
            missing="$missing $py"
        fi
    done
    if [ "$mig" -eq 3 ]; then
        PORTCULLIS_STATUS="ACTION NEEDED — config.yaml model.base_url points at Portcullis; restore your provider (see warning above)"
    elif [ -n "$missing" ]; then
        echo "WARNING: Portcullis hook NOT loaded in:$missing — those LLM calls are NOT redacted"
        PORTCULLIS_STATUS="NOT ACTIVE — hook not loaded (see warning above)"
    else
        PORTCULLIS_STATUS="active — every LLM call is redacted (transparent; config.yaml untouched)"
    fi
    return 0
}

# --- Helper: directory and config setup (shared by both paths) ---
setup_hermes() {
    source "${INSTALL_DIR}/.venv/bin/activate"

    # Create essential directory structure (mirrors official entrypoint)
    mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home,webui,cache}

    # .env — only create if missing (newer agent images may not ship .env.example)
    if [ ! -f "$HERMES_HOME/.env" ] && [ -f "$INSTALL_DIR/.env.example" ]; then
        cp "$INSTALL_DIR/.env.example" "$HERMES_HOME/.env"
        echo "Created default .env — edit $HERMES_HOME/.env to add your API keys"
    fi

    # config.yaml — only create if missing
    if [ ! -f "$HERMES_HOME/config.yaml" ] && [ -f "$INSTALL_DIR/cli-config.yaml.example" ]; then
        cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
        echo "Created default config.yaml"
    fi

    # Ensure config permissions
    if [ -f "$HERMES_HOME/config.yaml" ]; then
        chown hermes:hermes "$HERMES_HOME/config.yaml"
        chmod 640 "$HERMES_HOME/config.yaml"
    fi

    # SOUL.md — only create if missing
    if [ ! -f "$HERMES_HOME/SOUL.md" ] && [ -f "$INSTALL_DIR/docker/SOUL.md" ]; then
        cp "$INSTALL_DIR/docker/SOUL.md" "$HERMES_HOME/SOUL.md"
    fi

    # Sync bundled skills
    if [ -d "$INSTALL_DIR/skills" ]; then
        python3 "$INSTALL_DIR/tools/skills_sync.py" 2>/dev/null || true
    fi

    # --- Dashboard basic auth (upstream v2026.7.1 security hardening) ---
    setup_dashboard_auth

    # --- WebUI password (separate mechanism, see setup_webui_auth) ---
    setup_webui_auth

    # --- Portcullis PII gateway (needs config.yaml + .env in place) ---
    setup_portcullis

    # --- Clean up stale PID/lock files from previous container runs ---
    for f in gateway.pid gateway.lock; do
        if [ -f "$HERMES_HOME/$f" ]; then
            echo "Removing stale $f from previous container run"
            rm -f "$HERMES_HOME/$f"
        fi
    done

    # --- Ensure supervisord directories exist ---
    mkdir -p /var/log/supervisor /var/run/supervisor
}

# --- Helper: startup banner ---
print_banner() {
    echo "=========================================="
    echo " Hermes Suite — All-in-One Container"
    echo "=========================================="
    echo " Gateway:    http://0.0.0.0:8642"
    echo " Dashboard:  http://0.0.0.0:9119"
    echo " WebUI:      http://0.0.0.0:8787"
    echo " Portcullis: 127.0.0.1:8080 (internal) — ${PORTCULLIS_STATUS:-unknown}"
    echo "=========================================="
    echo " Dashboard login: $HERMES_DASHBOARD_BASIC_AUTH_USERNAME / $HERMES_DASHBOARD_BASIC_AUTH_PASSWORD"
    if [ -n "${HERMES_WEBUI_PASSWORD:-}" ]; then
        echo " WebUI password:  set"
    else
        echo " WebUI password:  NOT SET — no login on the WebUI (see README: WebUI Authentication)"
    fi
    echo "=========================================="
}

# =============================================================================
# Main entry point
# =============================================================================
if [ "$(id -u)" = "0" ]; then
    # --- Privilege dropping (mirrors official hermes-agent entrypoint) ---
    if [ -n "$HERMES_UID" ] && [ "$HERMES_UID" != "$(id -u hermes)" ]; then
        echo "Changing hermes UID to $HERMES_UID"
        usermod -u "$HERMES_UID" hermes
    fi

    if [ -n "$HERMES_GID" ] && [ "$HERMES_GID" != "$(id -g hermes)" ]; then
        echo "Changing hermes GID to $HERMES_GID"
        groupmod -o -g "$HERMES_GID" hermes 2>/dev/null || true
    fi

    actual_hermes_uid=$(id -u hermes)
    if [ "$(stat -c %u "$HERMES_HOME" 2>/dev/null)" != "$actual_hermes_uid" ]; then
        echo "$HERMES_HOME is not owned by $actual_hermes_uid, fixing"
        chown -R hermes:hermes "$HERMES_HOME" 2>/dev/null || \
            echo "Warning: chown failed (rootless container?) — continuing anyway"
    fi

    # --- Runtime-specific startup ---
    if is_docker; then
        # Docker: stay as root for supervisord (fixes /dev/stdout permission issue)
        # supervisord.conf user=hermes ensures child processes run as hermes
        echo "Detected Docker runtime — supervisord as root, services as hermes"
        setup_hermes

        # Ensure all created files/dirs are owned by hermes
        chown -R hermes:hermes "$HERMES_HOME" 2>/dev/null || \
            echo "Warning: chown failed — continuing anyway"

        print_banner
        exec "$@"
    fi

    # Podman (or unknown runtime): drop to hermes via s6-setuidgid, re-exec this script
    # s6-setuidgid is provided by the s6-overlay in the base agent image (v2026.5.29+)
    echo "Detected Podman runtime"
    echo "Dropping root privileges"
    exec /command/s6-setuidgid hermes "$0" "$@"
fi

# --- Running as hermes (Podman path only, via s6-setuidgid re-exec) ---
setup_hermes
print_banner
exec "$@"
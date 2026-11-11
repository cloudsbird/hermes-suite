#!/bin/bash
# =============================================================================
# portcullis-run.sh — supervisord launcher for the Portcullis PII gateway
#
# Reads its settings from $HERMES_HOME/portcullis/env (written by start.sh)
# instead of relying on supervisord's inherited environment, so restarting
# the program — or supervisord itself — always comes back up identically.
#
# Transparent mode: Portcullis runs with PORTCULLIS_PASSTHROUGH=1 and no fixed
# upstream. The httpx hook in the Hermes venvs routes each LLM call here with
# its real URL in x-portcullis-upstream; Hermes' own key and headers are
# forwarded as-is. Nothing provider-specific is configured here.
# =============================================================================
STATE_DIR="${HERMES_HOME:-/opt/data}/portcullis"

if [ -f "$STATE_DIR/env" ]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/env"
fi

if [ "${PORTCULLIS_ENABLED:-true}" = "false" ]; then
    echo "[portcullis] disabled (PORTCULLIS_ENABLED=false) — not starting"
    exit 0   # supervisord: exitcodes=0 + autorestart=unexpected => stays stopped
fi

if [ -z "${PORTCULLIS_ADMIN_TOKEN:-}" ] && [ -s "$STATE_DIR/admin_token" ]; then
    PORTCULLIS_ADMIN_TOKEN="$(cat "$STATE_DIR/admin_token")"
fi

export PORTCULLIS_PASSTHROUGH=1
# Every main-model call now goes through Portcullis, so its limits must not be
# tighter than talking to the provider directly: long agent histories, tool
# output and re-sent images easily exceed the 2 MiB default body cap, and
# reasoning models can stay silent mid-stream longer than the 180s default.
export PORTCULLIS_MAX_BODY_BYTES="${PORTCULLIS_MAX_BODY_BYTES:-67108864}"   # 64 MiB
export PORTCULLIS_READ_TIMEOUT_SECS="${PORTCULLIS_READ_TIMEOUT_SECS:-600}"
export PORTCULLIS_REQUEST_TIMEOUT_SECS="${PORTCULLIS_REQUEST_TIMEOUT_SECS:-900}"
export PORTCULLIS_STORE="${PORTCULLIS_STORE:-$STATE_DIR/store.json}"
[ -n "${PORTCULLIS_ADMIN_TOKEN:-}" ] && export PORTCULLIS_ADMIN_TOKEN
for v in PORTCULLIS_MODEL_DIR PORTCULLIS_THRESHOLD PORTCULLIS_DETECTOR_FAIL_CLOSED PORTCULLIS_STORE_KEY_FILE PORTCULLIS_LOG_FORMAT; do
    if [ -n "${!v:-}" ]; then export "${v?}"; else unset "$v"; fi
done
# A fixed upstream is not used in transparent mode; drop any stale value so a
# request without the routing header fails loudly instead of going somewhere.
unset PORTCULLIS_UPSTREAM_URL PORTCULLIS_UPSTREAM_KEY

cd "$STATE_DIR" 2>/dev/null || cd /
exec /usr/local/bin/portcullis serve --bind 127.0.0.1:8080

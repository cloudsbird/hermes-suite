#!/bin/bash
# =============================================================================
# tests/test_portcullis.sh — QA for the Portcullis PII-gateway integration
#
# Pure shell + Python: no container runtime, no network (podman is stubbed).
#   bash tests/test_portcullis.sh
#
# Wire-script cases need a Python with ruamel.yaml (it ships in the image's
# hermes-agent venv). Point PYTHON at one; they are skipped if unavailable:
#   PYTHON=/path/to/venv/bin/python bash tests/test_portcullis.sh
# =============================================================================
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TEST_DIR")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hs-pc-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="${WORK}/bin"; mkdir -p "$BIN"
PYTHON="${PYTHON:-python3}"
WIRE="${REPO_DIR}/portcullis-wire.py"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (want '$2' got '$3')"; }
has() { grep -qF -- "$2" "$3" && ok "$1" || bad "$1"; }
hasnt() { grep -qF -- "$2" "$3" && bad "$1" || ok "$1"; }

cat > "${BIN}/podman" <<'EOF'
#!/bin/bash
echo "PODMAN-ARGS: $*" >> "${CAPTURE_FILE:?}"
exit 0
EOF
chmod +x "${BIN}/podman"

fresh_repo() {
    rm -rf "${WORK}/repo"; cp -r "${REPO_DIR}" "${WORK}/repo"; rm -rf "${WORK}/repo/.git"
}
run_build() { ( cd "${WORK}/repo" && env PATH="${BIN}:$PATH" \
    CAPTURE_FILE="${WORK}/$1.args" ./build.sh "${@:2}" ) >"${WORK}/$1.out" 2>&1; }

PIN="$(grep -E '^PORTCULLIS_VERSION=' "${REPO_DIR}/versions.env" | cut -d= -f2)"

echo "== pin consistency =="
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] && ok "versions.env pins a full commit SHA" || bad "versions.env pins a full commit SHA (got '$PIN')"
eq "Dockerfile default ARGs match versions.env" "2" \
    "$(grep -c "^ARG PORTCULLIS_VERSION=${PIN}\$" "${REPO_DIR}/Dockerfile")"

echo "== build.sh passes PORTCULLIS_VERSION =="
fresh_repo
run_build def
eq "exit code" "0" "$?"
has "build-arg from versions.env" "--build-arg PORTCULLIS_VERSION=${PIN}" "${WORK}/def.args"
fresh_repo
run_build ov --portcullis deadbeef
has "--portcullis override" "--build-arg PORTCULLIS_VERSION=deadbeef" "${WORK}/ov.args"
fresh_repo
sed -i '/^PORTCULLIS_VERSION=/d' "${WORK}/repo/versions.env"
run_build miss
[ "$?" != "0" ] && ok "missing pin rejected" || bad "missing pin rejected"

echo "== compose never publishes 8080 =="
for f in docker-compose.yaml docker-compose.dokploy.yaml; do
    grep -qE '^[[:space:]]*-[[:space:]]*"?[^#]*:8080"?[[:space:]]*$' "${REPO_DIR}/$f" \
        && bad "$f: no 8080 port mapping" || ok "$f: no 8080 port mapping"
    has "$f: PORTCULLIS_ENABLED passthrough" 'PORTCULLIS_ENABLED=${PORTCULLIS_ENABLED:-true}' "${REPO_DIR}/$f"
done
has "supervisord binds loopback only" "serve --bind 127.0.0.1:8080" "${REPO_DIR}/supervisord.conf"

echo "== start.sh syntax =="
bash -n "${REPO_DIR}/start.sh" && ok "bash -n start.sh" || bad "bash -n start.sh"

if ! "$PYTHON" -c "import ruamel.yaml" 2>/dev/null; then
    echo "== wire script: SKIPPED (no ruamel.yaml in $PYTHON) =="
    SKIP=1
else
    wire() { env -u PORTCULLIS_UPSTREAM_URL -u PORTCULLIS_UPSTREAM_KEY -u OPENROUTER_API_KEY \
        HERMES_HOME="$1" "${@:2}" "$PYTHON" -I "$WIRE" >"$1/wire.out" 2>&1; }
    envval() { ( . "$1/portcullis/env"; eval "echo \"\${$2:-}\"" ); }

    echo "== wire: openrouter config is rewired, comments kept =="
    H="${WORK}/h1"; mkdir -p "$H"
    cat > "$H/config.yaml" <<'EOF'
# keep me
model:
  default: "anthropic/claude-opus-4.6"
  provider: "auto"
  base_url: "https://openrouter.ai/api/v1"
EOF
    echo 'OPENROUTER_API_KEY="sk-or-test"' > "$H/.env"
    cp "$H/config.yaml" "$H/config.orig"
    wire "$H"
    eq "exit code" "0" "$?"
    has "comment preserved" "# keep me" "$H/config.yaml"
    has "base_url -> proxy" 'base_url: "http://127.0.0.1:8080/v1"' "$H/config.yaml"
    has "provider -> custom" 'provider: "custom"' "$H/config.yaml"
    has "api_mode pinned" "api_mode: chat_completions" "$H/config.yaml"
    eq "autostart" "true" "$(envval "$H" PORTCULLIS_AUTOSTART)"
    eq "upstream url" "https://openrouter.ai/api/v1" "$(envval "$H" PORTCULLIS_UPSTREAM_URL)"
    eq "upstream key from .env" "sk-or-test" "$(envval "$H" PORTCULLIS_UPSTREAM_KEY)"
    eq "env file mode" "600" "$(stat -c %a "$H/portcullis/env")"

    echo "== wire: idempotent re-run =="
    cp "$H/config.yaml" "$H/config.wired"
    wire "$H"
    cmp -s "$H/config.yaml" "$H/config.wired" && ok "config unchanged on re-run" || bad "config unchanged on re-run"
    eq "upstream still resolved from backup" "https://openrouter.ai/api/v1" "$(envval "$H" PORTCULLIS_UPSTREAM_URL)"

    echo "== wire: env override wins =="
    wire "$H" PORTCULLIS_UPSTREAM_URL=https://api.deepseek.com/v1 PORTCULLIS_UPSTREAM_KEY=sk-ds
    eq "override url" "https://api.deepseek.com/v1" "$(envval "$H" PORTCULLIS_UPSTREAM_URL)"
    eq "override key" "sk-ds" "$(envval "$H" PORTCULLIS_UPSTREAM_KEY)"

    echo "== wire: disabled restores original =="
    wire "$H" PORTCULLIS_ENABLED=false
    cmp -s "$H/config.yaml" "$H/config.orig" && ok "config restored byte-identical" || bad "config restored byte-identical"
    eq "autostart off" "false" "$(envval "$H" PORTCULLIS_AUTOSTART)"
    [ ! -e "$H/portcullis/original-model.json" ] && ok "backup removed" || bad "backup removed"

    echo "== wire: unsupported provider left alone =="
    H="${WORK}/h2"; mkdir -p "$H"
    printf 'model:\n  default: claude\n  provider: anthropic\n' > "$H/config.yaml"
    cp "$H/config.yaml" "$H/config.orig"
    wire "$H"
    cmp -s "$H/config.yaml" "$H/config.orig" && ok "anthropic config untouched" || bad "anthropic config untouched"
    eq "autostart off" "false" "$(envval "$H" PORTCULLIS_AUTOSTART)"

    echo "== wire: no key -> not active, untouched =="
    H="${WORK}/h3"; mkdir -p "$H"
    printf 'model:\n  default: x\n  provider: auto\n' > "$H/config.yaml"
    cp "$H/config.yaml" "$H/config.orig"
    wire "$H"
    cmp -s "$H/config.yaml" "$H/config.orig" && ok "config untouched" || bad "config untouched"
    eq "autostart off" "false" "$(envval "$H" PORTCULLIS_AUTOSTART)"

    echo "== wire: no config.yaml yet =="
    H="${WORK}/h4"; mkdir -p "$H"
    wire "$H"
    eq "exit code" "0" "$?"
    eq "autostart off" "false" "$(envval "$H" PORTCULLIS_AUTOSTART)"

    echo "== wire: provider changed while wired -> rewired to new upstream =="
    H="${WORK}/h5"; mkdir -p "$H"
    printf 'model:\n  default: m\n  provider: custom\n  base_url: http://ollama:11434/v1\n' > "$H/config.yaml"
    wire "$H"
    eq "local upstream needs no key" "true" "$(envval "$H" PORTCULLIS_AUTOSTART)"
    sed -i 's|http://127.0.0.1:8080/v1|https://api.groq.com/openai/v1|' "$H/config.yaml"
    sed -i 's|portcullis-local|gsk-test|' "$H/config.yaml"
    wire "$H"
    eq "new upstream picked up" "https://api.groq.com/openai/v1" "$(envval "$H" PORTCULLIS_UPSTREAM_URL)"
    eq "new key picked up" "gsk-test" "$(envval "$H" PORTCULLIS_UPSTREAM_KEY)"
    has "rewired" "http://127.0.0.1:8080/v1" "$H/config.yaml"

    echo "== wire: bypass routes are reported =="
    H="${WORK}/h6"; mkdir -p "$H"
    cat > "$H/config.yaml" <<'EOF'
model:
  default: m
  provider: openrouter
auxiliary:
  compression:
    provider: auto
  vision:
    provider: gemini
fallback_providers:
  - provider: nous
    model: x
EOF
    wire "$H" PORTCULLIS_UPSTREAM_KEY=k
    eq "still active" "true" "$(envval "$H" PORTCULLIS_AUTOSTART)"
    has "aux vision warned" "auxiliary.vision has its own provider" "$H/wire.out"
    has "fallback warned" "fallback_providers has its own provider" "$H/wire.out"
    hasnt "aux auto not warned" "auxiliary.compression" "$H/wire.out"
    has "status mentions bypass" "2 route(s) bypass it" "$H/portcullis/env"
fi

echo ""
echo "=========================================="
echo " Passed: $PASS   Failed: $FAIL   $([ $SKIP = 1 ] && echo '(wire tests skipped)')"
echo "=========================================="
[ "$FAIL" -eq 0 ]

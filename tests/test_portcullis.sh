#!/bin/bash
# =============================================================================
# tests/test_portcullis.sh — QA for the Portcullis PII-gateway integration
#
# Pure shell + Python: no container runtime, no network (podman is stubbed).
#   bash tests/test_portcullis.sh
#
# Migration cases need a Python with ruamel.yaml, hook cases one with httpx
# (both ship in the image's hermes-agent venv). Point PYTHON at one; cases are
# skipped if the module is missing:
#   PYTHON=/path/to/venv/bin/python bash tests/test_portcullis.sh
#
# Optional end-to-end run of the transparent route (and portcullis-ctl) through
# a real Portcullis binary using the openai/anthropic SDKs:
#   PORTCULLIS_BIN=/path/to/portcullis PYTHON=... bash tests/test_portcullis.sh
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
has "launcher binds loopback only" "serve --bind 127.0.0.1:8080" "${REPO_DIR}/portcullis-run.sh"
has "launcher enables passthrough" "PORTCULLIS_PASSTHROUGH=1" "${REPO_DIR}/portcullis-run.sh"
has "supervisord runs the launcher" "command=/opt/hermes-suite/portcullis-run.sh" "${REPO_DIR}/supervisord.conf"
hasnt "no env-dependent autostart" "ENV_PORTCULLIS" "${REPO_DIR}/supervisord.conf"
has "hook installed into venvs" "portcullis_hook.pth" "${REPO_DIR}/Dockerfile"

echo "== shell syntax =="
for f in start.sh portcullis-run.sh portcullis-ctl; do
    bash -n "${REPO_DIR}/$f" && ok "bash -n $f" || bad "bash -n $f"
done
has "image ships portcullis-ctl" "ln -sf /opt/hermes-suite/portcullis-ctl /usr/local/bin/portcullis-ctl" "${REPO_DIR}/Dockerfile"
has "image ships the skill" "COPY skills/portcullis/SKILL.md" "${REPO_DIR}/Dockerfile"
[ -f "${REPO_DIR}/skills/portcullis/SKILL.md" ] && ok "skill file exists" || bad "skill file exists"

echo "== portcullis-run.sh: disabled exits 0 without starting =="
H="${WORK}/run"; mkdir -p "$H/portcullis"
echo "PORTCULLIS_ENABLED=false" > "$H/portcullis/env"
HERMES_HOME="$H" bash "${REPO_DIR}/portcullis-run.sh" > "$H/out" 2>&1
eq "exit code 0 when disabled" "0" "$?"
has "says disabled" "disabled" "$H/out"

echo "== portcullis-run.sh: portcullis-ctl off keeps it stopped =="
H="${WORK}/run2"; mkdir -p "$H/portcullis"
echo "PORTCULLIS_ENABLED=true" > "$H/portcullis/env"; echo off > "$H/portcullis/override"
HERMES_HOME="$H" bash "${REPO_DIR}/portcullis-run.sh" > "$H/out" 2>&1
eq "exit code 0 when overridden off" "0" "$?"
has "says portcullis-ctl off" "portcullis-ctl off" "$H/out"

echo "== start.sh setup_portcullis: precedence env > override > default =="
# Run just the function; the image-only paths it touches are absent here and skipped.
eval "$(sed -n '/^setup_portcullis() {/,/^}/p' "${REPO_DIR}/start.sh")"
setup() { ( HERMES_HOME="$1"; shift; export "$@"; setup_portcullis >/dev/null 2>&1; echo "$PORTCULLIS_STATUS" ); }
H="${WORK}/sp1"; mkdir -p "$H"
st="$(setup "$H" PORTCULLIS_ENABLED=true)"
[ -e "$H/portcullis/transparent" ] && ok "default: routing marker created" || bad "default: routing marker created"
case "$st" in active*) ok "default: status active" ;; *) bad "default: status active (got '$st')" ;; esac
H="${WORK}/sp2"; mkdir -p "$H/portcullis"; echo off > "$H/portcullis/override"; touch "$H/portcullis/transparent"
st="$(setup "$H" PORTCULLIS_ENABLED=true)"
[ ! -e "$H/portcullis/transparent" ] && ok "override off: no routing marker" || bad "override off: no routing marker"
has "override off: env still enabled (so 'on' works later)" "PORTCULLIS_ENABLED=true" "$H/portcullis/env"
has "override off: token still written" "PORTCULLIS_ADMIN_TOKEN=" "$H/portcullis/env"
case "$st" in *"portcullis-ctl off"*) ok "override off: banner says so" ;; *) bad "override off: banner says so (got '$st')" ;; esac
H="${WORK}/sp3"; mkdir -p "$H/portcullis"; echo on > "$H/portcullis/override"
setup "$H" PORTCULLIS_ENABLED=false >/dev/null
[ ! -e "$H/portcullis/transparent" ] && ok "env false beats override on" || bad "env false beats override on"
has "env false: launcher told to stay off" "PORTCULLIS_ENABLED=false" "$H/portcullis/env"

echo "== portcullis-ctl: off / on safety =="
printf '%s\n' '#!/bin/bash' 'echo "supervisorctl $*" >> "${CTL_LOG:?}"' > "${BIN}/supervisorctl"
printf '%s\n' '#!/bin/bash' '[ "$1" = "-n" ] && shift' 'exec "$@"' > "${BIN}/sudo"
chmod +x "${BIN}/supervisorctl" "${BIN}/sudo"
ctl() { env PATH="${BIN}:$PATH" HERMES_HOME="$H" CTL_LOG="$H/ctl.log" \
    PORTCULLIS_GATEWAY=http://127.0.0.1:1 PORTCULLIS_CTL_HEALTH_WAIT=1 \
    bash "${REPO_DIR}/portcullis-ctl" "$@"; }
H="${WORK}/ctl1"; mkdir -p "$H/portcullis"; touch "$H/portcullis/transparent"
echo "PORTCULLIS_ENABLED=true" > "$H/portcullis/env"
ctl off > "$H/out" 2>&1
eq "off: exit 0" "0" "$?"
eq "off: override persisted" "off" "$(cat "$H/portcullis/override")"
[ ! -e "$H/portcullis/transparent" ] && ok "off: routing stopped" || bad "off: routing stopped"
has "off: process stopped" "supervisorctl -c /etc/supervisor/supervisord.conf stop portcullis" "$H/ctl.log"
ctl on > "$H/out" 2>&1
[ "$?" != "0" ] && ok "on: fails when the gateway never gets healthy" || bad "on: fails when the gateway never gets healthy"
[ ! -e "$H/portcullis/transparent" ] && ok "on: never routes to a dead gateway" || bad "on: never routes to a dead gateway"
has "on: says chats still work" "routing NOT enabled" "$H/out"
echo "PORTCULLIS_ENABLED=false" > "$H/portcullis/env"
ctl on > "$H/out" 2>&1
[ "$?" != "0" ] && ok "on: refused when PORTCULLIS_ENABLED=false" || bad "on: refused when PORTCULLIS_ENABLED=false"
has "on: explains the env override" "PORTCULLIS_ENABLED=false" "$H/out"
ctl status > "$H/out" 2>&1
has "status: reports off" "Portcullis: OFF" "$H/out"
echo "PORTCULLIS_ENABLED=true" > "$H/portcullis/env"; touch "$H/portcullis/transparent"
ctl status > "$H/out" 2>&1
[ "$?" != "0" ] && ok "status: non-zero when routing to a dead gateway" || bad "status: non-zero when routing to a dead gateway"
has "status: says BROKEN" "BROKEN" "$H/out"
H="${WORK}/ctl2"; mkdir -p "$H/portcullis"
ctl status > "$H/out" 2>&1
hasnt "status: no noise without an override file" "No such file" "$H/out"

pyhas() { "$PYTHON" -c "import $1" 2>/dev/null; }

# --------------------------------------------------------------------------
if ! pyhas ruamel.yaml; then
    echo "== migration: SKIPPED (no ruamel.yaml in $PYTHON) =="; SKIP=1
else
    mig() { HERMES_HOME="$1" "$PYTHON" -I "$WIRE" >"$1/mig.out" 2>&1; }

    echo "== migration: old rewrite is restored, comments kept =="
    H="${WORK}/m1"; mkdir -p "$H/portcullis"
    cat > "$H/config.orig" <<'EOF'
# keep me
model:
  default: "glm-5.3-flash"
  provider: "opencode-go"
  base_url: "https://opencode.ai/zen/go/v1"
EOF
    cat > "$H/config.yaml" <<'EOF'
# keep me
model:
  default: "glm-5.3-flash"
  provider: "custom"
  base_url: "http://127.0.0.1:8080/v1"
  api_key: portcullis-local
  api_mode: chat_completions
EOF
    echo '{"provider":"opencode-go","base_url":"https://opencode.ai/zen/go/v1","api_key":null,"api_mode":null}' \
        > "$H/portcullis/original-model.json"
    mig "$H"
    eq "exit code" "0" "$?"
    cmp -s "$H/config.yaml" "$H/config.orig" && ok "config restored byte-identical" || bad "config restored byte-identical"
    [ ! -e "$H/portcullis/original-model.json" ] && ok "backup removed" || bad "backup removed"
    cp "$H/config.yaml" "$H/config.after"; mig "$H"
    cmp -s "$H/config.yaml" "$H/config.after" && ok "idempotent" || bad "idempotent"

    echo "== migration: user already changed provider -> config left alone =="
    H="${WORK}/m2"; mkdir -p "$H/portcullis"
    printf 'model:\n  provider: openrouter\n  base_url: https://openrouter.ai/api/v1\n' > "$H/config.yaml"
    cp "$H/config.yaml" "$H/config.orig"
    echo '{"provider":"auto","base_url":null,"api_key":null,"api_mode":null}' > "$H/portcullis/original-model.json"
    mig "$H"
    cmp -s "$H/config.yaml" "$H/config.orig" && ok "config untouched" || bad "config untouched"
    [ ! -e "$H/portcullis/original-model.json" ] && ok "stale backup removed" || bad "stale backup removed"

    echo "== migration: hand-pointed at gateway without backup -> loud warning =="
    H="${WORK}/m4"; mkdir -p "$H/portcullis"
    printf 'model:\n  provider: custom\n  base_url: http://127.0.0.1:8080/v1\n' > "$H/config.yaml"
    cp "$H/config.yaml" "$H/config.orig"
    mig "$H"
    eq "exit code 3 (action needed)" "3" "$?"
    has "warns about HTTP 400" "fail with HTTP 400" "$H/mig.out"
    cmp -s "$H/config.yaml" "$H/config.orig" && ok "config untouched" || bad "config untouched"

    echo "== migration: fresh install is a no-op =="
    H="${WORK}/m3"; mkdir -p "$H"
    mig "$H"; eq "exit code" "0" "$?"
fi

# --------------------------------------------------------------------------
if ! pyhas httpx; then
    echo "== hook: SKIPPED (no httpx in $PYTHON) =="; SKIP=1
else
    echo "== hook: routing decisions =="
    H="${WORK}/hook"; mkdir -p "$H/portcullis"
    hook() { HERMES_HOME="$H" PYTHONPATH="$REPO_DIR" "$PYTHON" - "$@" <<'EOF'
import sys, portcullis_hook, httpx
method, url = sys.argv[1], sys.argv[2]
r = httpx.Request(method, url, json={})
portcullis_hook._rewrite(httpx, r)
print(r.url, r.headers.get("x-portcullis-upstream", "-"), r.headers.get("host"))
EOF
    }
    out="$(hook POST https://opencode.ai/zen/go/v1/chat/completions)"
    eq "inactive without marker" "https://opencode.ai/zen/go/v1/chat/completions - opencode.ai" "$out"
    touch "$H/portcullis/transparent"
    out="$(hook POST https://opencode.ai/zen/go/v1/chat/completions)"
    eq "chat completions routed" "http://127.0.0.1:8080/v1/chat/completions https://opencode.ai/zen/go/v1/chat/completions 127.0.0.1:8080" "$out"
    out="$(hook POST https://api.anthropic.com/v1/messages)"
    eq "anthropic messages routed" "http://127.0.0.1:8080/v1/messages https://api.anthropic.com/v1/messages 127.0.0.1:8080" "$out"
    out="$(hook GET https://opencode.ai/zen/go/v1/models)"
    eq "GET /models untouched" "https://opencode.ai/zen/go/v1/models - opencode.ai" "$out"
    out="$(hook POST https://api.anthropic.com/v1/messages/count_tokens)"
    eq "count_tokens untouched" "https://api.anthropic.com/v1/messages/count_tokens - api.anthropic.com" "$out"
    out="$(hook POST http://127.0.0.1:8080/v1/chat/completions)"
    eq "gateway itself untouched" "http://127.0.0.1:8080/v1/chat/completions - 127.0.0.1:8080" "$out"
    hook POST https://chatgpt.com/backend-api/codex/responses > /dev/null 2> "$H/warn"
    has "unsupported protocol warns" "NOT redacted" "$H/warn"
    out="$(PORTCULLIS_TRANSPARENT=0 hook POST https://opencode.ai/zen/go/v1/chat/completions)"
    eq "PORTCULLIS_TRANSPARENT=0 kill switch" "https://opencode.ai/zen/go/v1/chat/completions - opencode.ai" "$out"

    echo "== hook: gateway down -> 503 with a message, nothing sent =="
    out="$(HERMES_HOME="$H" PORTCULLIS_GATEWAY=http://127.0.0.1:1 PYTHONPATH="$REPO_DIR" "$PYTHON" - 2>/dev/null <<'PYEOF'
import asyncio, portcullis_hook, httpx
r = httpx.Client().post("https://api.provider.invalid/v1/chat/completions", json={"messages": []})
print(r.status_code, r.json()["error"]["code"], "NOT sent" in r.json()["error"]["message"])
async def a():
    async with httpx.AsyncClient() as c:
        r = await c.post("https://api.anthropic.invalid/v1/messages", json={"messages": []})
        print(r.status_code, r.json()["type"], r.json()["error"]["type"])
asyncio.run(a())
PYEOF
)"
    eq "openai shape (sync)" "503 portcullis_down True" "$(echo "$out" | sed -n 1p)"
    eq "anthropic shape (async)" "503 error api_error" "$(echo "$out" | sed -n 2p)"
fi

# --------------------------------------------------------------------------
if [ -z "${PORTCULLIS_BIN:-}" ] || ! pyhas openai || ! pyhas anthropic; then
    echo "== e2e: SKIPPED (set PORTCULLIS_BIN; needs openai+anthropic in $PYTHON) =="
else
    echo "== e2e: SDKs -> hook -> real Portcullis -> fake provider =="
    E="${WORK}/e2e"; mkdir -p "$E/home/portcullis"; : > "$E/up.log"
    cat > "$E/provider.py" <<'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        open(sys.argv[1], "a").write(json.dumps({"key": self.headers.get("authorization") or self.headers.get("x-api-key"),
            "session": self.headers.get("x-opencode-session"), "ctl": self.headers.get("x-portcullis-upstream"),
            "body": body}) + "\n")
        said = body["messages"][-1]["content"]
        if body.get("tool_choice") == "echo":
            # Echo what the provider saw back as tool-call arguments (JSON text).
            msg = {"role": "assistant", "content": None, "tool_calls": [{"id": "t1", "type": "function",
                   "function": {"name": "echo", "arguments": json.dumps({"echo": said})}}]}
            out = {"id": "c", "object": "chat.completion", "created": 0, "model": "g",
                   "choices": [{"index": 0, "finish_reason": "tool_calls", "message": msg}]}
        elif self.path.endswith("/v1/messages"):
            out = {"id": "m", "type": "message", "role": "assistant", "model": "c", "stop_reason": "end_turn",
                   "content": [{"type": "text", "text": "You said: " + said}], "usage": {"input_tokens": 1, "output_tokens": 1}}
        else:
            out = {"id": "c", "object": "chat.completion", "created": 0, "model": "g",
                   "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "You said: " + said}}]}
        b = json.dumps(out).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_port, flush=True); srv.serve_forever()
EOF
    "$PYTHON" -I "$E/provider.py" "$E/up.log" > "$E/port" & UP=$!
    BODY_CAP="$(grep -o 'PORTCULLIS_MAX_BODY_BYTES:-[0-9]*' "${REPO_DIR}/portcullis-run.sh" | cut -d- -f2)"
    PORTCULLIS_PASSTHROUGH=1 PORTCULLIS_MAX_BODY_BYTES="$BODY_CAP" PORTCULLIS_STORE="$E/store.json" \
        PORTCULLIS_ADMIN_TOKEN=e2e-admin \
        "$PORTCULLIS_BIN" serve --bind 127.0.0.1:18081 > "$E/pc.log" 2>&1 & PCP=$!
    for _ in $(seq 50); do [ -s "$E/port" ] && curl -s 127.0.0.1:18081/healthz >/dev/null && break; sleep 0.1; done
    PORT="$(cat "$E/port")"; touch "$E/home/portcullis/transparent"
    HERMES_HOME="$E/home" PORTCULLIS_GATEWAY=http://127.0.0.1:18081 PYTHONPATH="$REPO_DIR" "$PYTHON" - "$PORT" > "$E/client.out" 2>&1 <<'EOF'
import sys, portcullis_hook, openai, anthropic
port = sys.argv[1]
oc = openai.OpenAI(base_url=f"http://127.0.0.1:{port}/zen/go/v1", api_key="sk-real",
                   default_headers={"x-opencode-session": "s1"}, max_retries=0)
print(oc.chat.completions.create(model="g", messages=[{"role": "user", "content": "mail jane.doe@acme.io"}]).choices[0].message.content)
ac = anthropic.Anthropic(base_url=f"http://127.0.0.1:{port}", api_key="sk-ant", max_retries=0)
print(ac.messages.create(model="c", max_tokens=5, messages=[{"role": "user", "content": "I am jane.doe@acme.io"}]).content[0].text)
big = "log line " * 380000 + " end"   # ~3.4 MiB, over Portcullis' 2 MiB default cap
r = oc.chat.completions.create(model="g", messages=[{"role": "user", "content": big}])
print("big ok", len(r.choices[0].message.content))
EOF
    eq "client exit" "0" "$?"

    echo "== e2e: portcullis-ctl against the live gateway =="
    pctl() { env PATH="${BIN}:$PATH" HERMES_HOME="$E/home" PORTCULLIS_ADMIN_TOKEN=e2e-admin CTL_LOG="$E/ctl.log" \
        PORTCULLIS_GATEWAY=http://127.0.0.1:18081 bash "${REPO_DIR}/portcullis-ctl" "$@"; }
    pctl teach Ann --label PERSON --whole-word > "$E/ctl.out" 2>&1 && ok "ctl teach" || bad "ctl teach: $(cat "$E/ctl.out")"
    pctl teach "Project Loki" --label PROJECT > /dev/null 2>&1
    pctl test "Project Loki: mail jane@acme.io from 10.0.1.3" > "$E/ctl.out" 2>&1
    has "ctl test shows placeholders" "provider sees: <<PROJECT_1>>: mail <<EMAIL_1>> from <<IP_1>>" "$E/ctl.out"
    pctl allow 10.0.1.3 > /dev/null 2>&1
    pctl test "from 10.0.1.3" > "$E/ctl.out" 2>&1
    has "ctl allow takes effect" "provider sees: from 10.0.1.3" "$E/ctl.out"
    pctl terms > "$E/ctl.out" 2>&1
    has "ctl terms lists taught" "Ann  ->  <<PERSON_n>> [whole word]" "$E/ctl.out"
    has "ctl terms lists allowed" "10.0.1.3" "$E/ctl.out"
    pctl status > "$E/ctl.out" 2>&1
    has "ctl status: active" "Portcullis: ACTIVE" "$E/ctl.out"
    pctl stats > "$E/ctl.out" 2>&1
    has "ctl stats" "hidden since start" "$E/ctl.out"

    echo "== e2e: agent traffic (JSON tool results, tool args, secrets, errors) =="
    HERMES_HOME="$E/home" PORTCULLIS_GATEWAY=http://127.0.0.1:18081 PYTHONPATH="$REPO_DIR" "$PYTHON" - "$PORT" > "$E/agent.out" 2>&1 <<'PYEOF'
import json, sys, portcullis_hook, openai
oc = openai.OpenAI(base_url=f"http://127.0.0.1:{sys.argv[1]}/v1", api_key="k", max_retries=0)
# Like Hermes: the tool result is JSON text, so each newline is the two characters \n.
tool = json.dumps({"output": "owner:\nAnn\njane@acme.io", "exit_code": 0})
assert chr(92) + "nAnn" in tool
msgs = [{"role": "user", "content": "who owns it? key sk-proj-abc123DEF456ghi789JKL012mno345"},
        {"role": "assistant", "content": None, "tool_calls": [{"id": "c1", "type": "function",
         "function": {"name": "terminal", "arguments": json.dumps({"cmd": "cat OWNERS"})}}]},
        {"role": "tool", "tool_call_id": "c1", "content": tool}]
r = oc.chat.completions.create(model="g", messages=msgs, tool_choice="echo")
args = json.loads(r.choices[0].message.tool_calls[0].function.arguments)
print("roundtrip", args["echo"] == tool)
try:
    oc.chat.completions.create(model="g", messages=[{"role": "assistant", "content": None, "tool_calls": [
        {"id": "c2", "type": "function", "function": {"name": "project loki search", "arguments": "{}"}}]}])
    print("NOT BLOCKED")
except openai.APIStatusError as e:
    print("blocked", e.status_code, e.code, "nothing was sent" in str(e))
PYEOF
    has "tool result round-trips exactly, args valid JSON" "roundtrip True" "$E/agent.out"
    has "blocked request: JSON error with code" "blocked 502 residual_term True" "$E/agent.out"
    hasnt "whole-word term after a JSON newline escape never reached provider" "nAnn" "$E/up.log"
    hasnt "email after a JSON newline escape never reached provider" "jane@acme.io" "$E/up.log"
    hasnt "API key never reached provider" "sk-proj-abc123" "$E/up.log"
    has "openai reply rehydrated" "You said: mail jane.doe@acme.io" "$E/client.out"
    has "anthropic reply rehydrated" "You said: I am jane.doe@acme.io" "$E/client.out"
    has "~3 MiB prompt accepted (body cap raised)" "big ok" "$E/client.out"
    eq "provider got 4 calls (the blocked one never left)" "4" "$(wc -l < "$E/up.log")"
    hasnt "no raw email reached provider" "jane.doe@acme.io" "$E/up.log"
    has "client key forwarded" '"key": "Bearer sk-real"' "$E/up.log"
    has "client header forwarded" '"session": "s1"' "$E/up.log"
    hasnt "control header not leaked" '"ctl": "http' "$E/up.log"
    kill "$PCP"; sleep 0.3
    HERMES_HOME="$E/home" PORTCULLIS_GATEWAY=http://127.0.0.1:18081 PYTHONPATH="$REPO_DIR" "$PYTHON" - "$PORT" > "$E/down.out" 2>&1 <<'EOF'
import sys, portcullis_hook, openai
oc = openai.OpenAI(base_url=f"http://127.0.0.1:{sys.argv[1]}/v1", api_key="k", max_retries=0)
try:
    oc.chat.completions.create(model="g", messages=[{"role": "user", "content": "x"}]); print("LEAKED")
except openai.APIStatusError as e:
    print("failed closed", e.status_code, "NOT sent" in str(e))
EOF
    has "gateway down -> fails closed with a readable 503" "failed closed 503 True" "$E/down.out"
    eq "nothing sent around a dead gateway" "4" "$(wc -l < "$E/up.log")"
    kill "$UP" 2>/dev/null
fi

echo ""
echo "=========================================="
echo " Passed: $PASS   Failed: $FAIL   $([ $SKIP = 1 ] && echo '(some cases skipped)')"
echo "=========================================="
[ "$FAIL" -eq 0 ]

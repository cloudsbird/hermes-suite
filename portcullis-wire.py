#!/usr/bin/env python3
# =============================================================================
# portcullis-wire.py — point Hermes at the in-container Portcullis PII gateway
#
# Called by start.sh on every container start (idempotent). Runs with the
# hermes-agent venv interpreter, which ships ruamel.yaml (a core dependency),
# so config.yaml is edited round-trip and its comments survive.
#
# Enabled (PORTCULLIS_ENABLED != false):
#   1. Read model.provider / model.base_url / model.api_key from config.yaml.
#   2. Resolve the REAL upstream (URL + key) Portcullis should forward to.
#   3. Save the original model fields to <state>/original-model.json, then
#      rewrite config.yaml so Hermes talks to http://127.0.0.1:8080/v1.
#   4. Write <state>/env (shell `export` lines) for start.sh to source.
#   If the provider cannot be proxied (OAuth / native-protocol providers) or
#   no upstream resolves, config.yaml is left untouched and Portcullis is not
#   started — a fresh install with no provider configured keeps booting.
#
# Disabled (PORTCULLIS_ENABLED=false):
#   Restore the saved original model fields and delete the backup.
#
# Output: <state>/env always contains PORTCULLIS_AUTOSTART (true|false) and
# PORTCULLIS_STATUS (one-line human summary for the startup banner).
# =============================================================================
import json
import os
import shlex
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

from ruamel.yaml import YAML

PROXY_URL = "http://127.0.0.1:8080/v1"
PROXY_API_KEY = "portcullis-local"  # Portcullis ignores it; uses the upstream key
WIRED_FIELDS = ("provider", "base_url", "api_key", "api_mode")

# Providers that cannot sit behind an OpenAI-compatible proxy: OAuth flows,
# or a non-chat-completions wire protocol. Portcullis' /v1/messages route
# exists but Hermes' native Anthropic path is not wired in this version.
UNSUPPORTED = {
    "nous", "openai-codex", "copilot", "github-copilot", "copilot-acp",
    "anthropic", "bedrock", "azure-foundry", "gemini", "google",
}

# Default endpoint + key env vars for OpenAI-compatible providers, used when
# config.yaml names the provider but sets no base_url.
KNOWN = {
    "openrouter": ("https://openrouter.ai/api/v1", ["OPENROUTER_API_KEY", "OPENAI_API_KEY"]),
    "openai": ("https://api.openai.com/v1", ["OPENAI_API_KEY"]),
    "deepseek": ("https://api.deepseek.com/v1", ["DEEPSEEK_API_KEY"]),
    "groq": ("https://api.groq.com/openai/v1", ["GROQ_API_KEY"]),
    "together": ("https://api.together.xyz/v1", ["TOGETHER_API_KEY"]),
    "deepinfra": ("https://api.deepinfra.com/v1/openai", ["DEEPINFRA_API_KEY"]),
    "nvidia": ("https://integrate.api.nvidia.com/v1", ["NVIDIA_API_KEY"]),
    "xai": ("https://api.x.ai/v1", ["XAI_API_KEY"]),
    "zai": ("https://api.z.ai/api/paas/v4", ["GLM_API_KEY", "ZAI_API_KEY", "Z_AI_API_KEY"]),
    "custom": (None, ["OPENAI_API_KEY"]),
}


# Providers whose endpoint is commonly self-hosted and keyless.
LOCAL_PROVIDERS = {"custom", "lmstudio", "ollama", "vllm", "llamacpp"}


def log(msg):
    print(f"[portcullis] {msg}", flush=True)


def read_dotenv(path):
    """Minimal KEY=VALUE parser for ~/.hermes/.env (quotes stripped)."""
    out = {}
    try:
        text = path.read_text()
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        out[k.strip()] = v
    return out


def env_lookup(names, dotenv):
    for n in names:
        v = (os.environ.get(n) or dotenv.get(n) or "").strip()
        if v:
            return v
    return ""


def is_proxy_url(url):
    try:
        u = urlparse(str(url or ""))
    except ValueError:
        return False
    return u.hostname in ("127.0.0.1", "localhost") and u.port == 8080


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_config(yaml, path):
    if not path.exists():
        return None
    with path.open() as f:
        return yaml.load(f)


def save_config(yaml, path, cfg):
    import io
    buf = io.StringIO()
    yaml.dump(cfg, buf)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o640
    atomic_write(path, buf.getvalue(), mode)


def model_block(cfg):
    m = cfg.get("model")
    if isinstance(m, str):  # scalar shorthand: `model: some/model`
        from ruamel.yaml.comments import CommentedMap
        m = CommentedMap(default=m)
        cfg["model"] = m
    return m if isinstance(m, dict) else None


def resolve_upstream(orig, dotenv):
    """Return (url, key, reason). url is None when it cannot be proxied."""
    provider = str(orig.get("provider") or "auto").strip().lower()
    base_url = str(orig.get("base_url") or "").strip()
    api_key = str(orig.get("api_key") or "").strip()
    api_mode = str(orig.get("api_mode") or "").strip().lower()

    if provider in UNSUPPORTED:
        return None, None, f"provider '{provider}' cannot be proxied (OAuth or native protocol)"
    if api_mode and api_mode != "chat_completions":
        return None, None, f"api_mode '{api_mode}' is not chat_completions"

    url = os.environ.get("PORTCULLIS_UPSTREAM_URL", "").strip()
    known_url, key_envs = KNOWN.get(provider, (None, []))
    if provider == "auto":
        # Hermes' auto-detection prefers OpenRouter; mirror that.
        known_url, key_envs = KNOWN["openrouter"]
    url = url or base_url or known_url
    if not url:
        return None, None, f"no upstream URL for provider '{provider}' (set model.base_url or PORTCULLIS_UPSTREAM_URL)"

    key = (os.environ.get("PORTCULLIS_UPSTREAM_KEY", "").strip() or api_key
           or env_lookup(key_envs or ["OPENAI_API_KEY"], dotenv))
    # Self-hosted endpoints (Ollama, vLLM, llama.cpp, ...) often need no key.
    if not key and provider not in LOCAL_PROVIDERS \
            and urlparse(url).hostname not in ("127.0.0.1", "localhost", "host.docker.internal"):
        return None, None, f"no API key found for '{provider}' (set it in .env or PORTCULLIS_UPSTREAM_KEY)"
    return url, key, ""


def find_bypass_routes(cfg):
    """Config paths that send model traffic somewhere other than the main
    route. Hermes only uses these when the user configured them (with a
    non-auto main provider its built-in discovery chain is disabled), so they
    are reported, not rewritten."""
    out = []

    def own_route(block):
        if not isinstance(block, dict):
            return False
        prov = str(block.get("provider") or "").strip().lower()
        return bool(block.get("base_url")) or prov not in ("", "auto", "main")

    for key in ("fallback_model", "fallback_providers"):
        if cfg.get(key):
            out.append(key)
    aux = cfg.get("auxiliary")
    if isinstance(aux, dict):
        for task, block in aux.items():
            if own_route(block):
                out.append(f"auxiliary.{task}")
            if isinstance(block, dict) and block.get("fallback_chain"):
                out.append(f"auxiliary.{task}.fallback_chain")
    deleg = cfg.get("delegation")
    if isinstance(deleg, dict):
        if own_route(deleg):
            out.append("delegation")
        if deleg.get("fallback_providers"):
            out.append("delegation.fallback_providers")
    return out


def write_env(state_dir, values):
    lines = [f"export {k}={shlex.quote(str(v))}" for k, v in values.items()]
    atomic_write(state_dir / "env", "\n".join(lines) + "\n")


def main():
    home = Path(os.environ.get("HERMES_HOME", "/opt/data"))
    state_dir = Path(os.environ.get("PORTCULLIS_STATE_DIR", home / "portcullis"))
    config_path = home / "config.yaml"
    backup_path = state_dir / "original-model.json"
    enabled = os.environ.get("PORTCULLIS_ENABLED", "true").strip().lower() not in ("false", "0", "no", "off")

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    state_dir.mkdir(parents=True, exist_ok=True)

    def finish(autostart, status, extra=None):
        values = {"PORTCULLIS_AUTOSTART": "true" if autostart else "false", "PORTCULLIS_STATUS": status}
        values.update(extra or {})
        write_env(state_dir, values)
        log(status)
        return 0

    cfg = load_config(yaml, config_path)
    model = model_block(cfg) if isinstance(cfg, dict) else None
    backup = json.loads(backup_path.read_text()) if backup_path.exists() else None

    # --- Disabled: undo our rewrite if we made one -------------------------
    if not enabled:
        if backup is not None and model is not None and is_proxy_url(model.get("base_url")):
            for f in WIRED_FIELDS:
                if backup.get(f) is None:
                    model.pop(f, None)
                else:
                    model[f] = backup[f]
            save_config(yaml, config_path, cfg)
            log("restored original model settings in config.yaml")
        if backup_path.exists():
            backup_path.unlink()
        return finish(False, "disabled (PORTCULLIS_ENABLED=false)")

    if model is None:
        return finish(False, "NOT ACTIVE — config.yaml has no model section yet")

    # --- Work out the ORIGINAL (pre-Portcullis) model settings -------------
    if is_proxy_url(model.get("base_url")):
        if backup is None:
            return finish(False, "NOT ACTIVE — config.yaml points at Portcullis but the original "
                                 "settings backup is missing; set PORTCULLIS_UPSTREAM_URL/KEY or fix model.base_url")
        orig = backup
    else:
        # Fresh install, or the user changed the provider while wired: the
        # current values are the new originals.
        orig = {f: model.get(f) for f in WIRED_FIELDS}

    dotenv = read_dotenv(home / ".env")
    url, key, reason = resolve_upstream(orig, dotenv)
    if url is None:
        # Leave config untouched; if we had wired it earlier, put it back so
        # Hermes isn't pointed at a proxy that won't be running.
        if is_proxy_url(model.get("base_url")) and backup is not None:
            for f in WIRED_FIELDS:
                if backup.get(f) is None:
                    model.pop(f, None)
                else:
                    model[f] = backup[f]
            save_config(yaml, config_path, cfg)
            backup_path.unlink()
        return finish(False, f"NOT ACTIVE — {reason}")

    # --- Wire it ------------------------------------------------------------
    atomic_write(backup_path, json.dumps({k: (str(v) if v is not None else None)
                                          for k, v in orig.items()}, indent=2) + "\n")
    changed = False
    # api_mode is pinned: Portcullis speaks chat-completions, so Hermes must
    # never guess a different wire protocol for the proxy URL.
    for f, v in (("provider", "custom"), ("base_url", PROXY_URL), ("api_key", PROXY_API_KEY),
                 ("api_mode", "chat_completions")):
        if model.get(f) != v:
            model[f] = v
            changed = True
    if changed:
        save_config(yaml, config_path, cfg)
        log(f"config.yaml now routes model calls through {PROXY_URL}")

    bypass = find_bypass_routes(cfg)
    for b in bypass:
        log(f"WARNING: {b} has its own provider/endpoint and is NOT redacted by Portcullis")

    extra = {"PORTCULLIS_UPSTREAM_URL": url}
    if key:
        extra["PORTCULLIS_UPSTREAM_KEY"] = key
    host = urlparse(url).hostname or url
    status = f"active — redacting before {host}"
    if bypass:
        status += f" ({len(bypass)} route(s) bypass it, see log)"
    return finish(True, status, extra)


if __name__ == "__main__":
    sys.exit(main())

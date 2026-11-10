#!/usr/bin/env python3
# =============================================================================
# portcullis-wire.py — undo the old config.yaml rewiring (migration)
#
# Earlier hermes-suite releases pointed Hermes at Portcullis by rewriting
# model.provider/base_url/api_key/api_mode in config.yaml and saving the
# originals to $HERMES_HOME/portcullis/original-model.json. Portcullis now runs
# in transparent mode (an httpx hook routes calls; config.yaml is never
# touched), so on every start this restores those originals if the rewrite is
# still in place, then deletes the backup. Idempotent; a no-op on fresh
# installs. Runs with the hermes-agent venv interpreter (ruamel.yaml, so
# comments in config.yaml survive).
# =============================================================================
import io
import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

from ruamel.yaml import YAML

WIRED_FIELDS = ("provider", "base_url", "api_key", "api_mode")


def log(msg):
    print(f"[portcullis] {msg}", flush=True)


def is_proxy_url(url):
    try:
        u = urlparse(str(url or ""))
        return u.hostname in ("127.0.0.1", "localhost") and u.port == 8080
    except ValueError:
        return False


def atomic_write(path, data, mode):
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


def main():
    home = Path(os.environ.get("HERMES_HOME", "/opt/data"))
    config_path = home / "config.yaml"
    backup_path = home / "portcullis" / "original-model.json"
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    cfg = None
    if config_path.exists():
        with config_path.open() as f:
            cfg = yaml.load(f)
    model = cfg.get("model") if isinstance(cfg, dict) else None

    if not backup_path.exists():
        if isinstance(model, dict) and is_proxy_url(model.get("base_url")):
            # Pointed at the gateway by hand (no backup to restore from). In
            # transparent mode Portcullis has no default upstream, so every call
            # would fail with HTTP 400.
            log("WARNING: config.yaml model.base_url points at Portcullis "
                f"({model.get('base_url')}) and there is no backup to restore. "
                "Set model.provider / base_url / api_key back to your real provider "
                "(e.g. `hermes model`) — Portcullis now routes transparently and "
                "every call through this config will fail with HTTP 400.")
            return 3
        return 0

    backup = json.loads(backup_path.read_text())

    if isinstance(model, dict) and is_proxy_url(model.get("base_url")):
        for field in WIRED_FIELDS:
            if backup.get(field) is None:
                model.pop(field, None)
            else:
                model[field] = backup[field]
        buf = io.StringIO()
        yaml.dump(cfg, buf)
        atomic_write(config_path, buf.getvalue(), config_path.stat().st_mode & 0o777)
        log("restored your original model settings in config.yaml "
            "(Portcullis now routes transparently; config.yaml is no longer modified)")
    backup_path.unlink()
    return 0


if __name__ == "__main__":
    sys.exit(main())

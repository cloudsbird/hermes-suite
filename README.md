# Hermes Suite — All-in-One Container Image

Single Docker/Podman image combining three Hermes services, plus a built-in
PII-redacting gateway in front of the LLM provider:

| Service | Port | Description |
|---------|------|-------------|
| hermes-gateway | 8642 | Agent gateway (CLI, Telegram, cron, tools) |
| hermes-dashboard | 9119 | Monitoring/analytics dashboard (built-in) |
| hermes-webui | 8787 | Browser-based chat interface |
| portcullis | 127.0.0.1:8080 (internal) | [PII gateway](#pii-redaction-portcullis) — redacts prompts before they leave the container |

Pre-built multi-arch images available on [GHCR](https://github.com/cloudsbird/hermes-suite/pkgs/container/hermes-suite).

> **🎉 Now with automatic runtime detection.** One image works on both Podman and Docker CE out of the box — no separate builds or flags needed. The container detects its runtime at startup and adjusts automatically. [Learn more](#changing-component-versions).

🏗️ Official container images are maintained by Ascensionoid ([ascensionoid.com](https://ascensionoid.com)).

## Why This Exists

Podman v3.4.4 cannot share the same UID/GID between multiple containers easily.
The standard multi-container setup (hermes-agent + hermes-webui + hermes-dashboard)
requires each container to run as the same user to share the `~/.hermes` volume.
Podman v3.4.4 has limitations with `userns_mode: keep-id` across multiple containers.

This image solves that by running all three services in **one container** via supervisord.

## Architecture

```
+-------------------------------------------------+
|             hermes-suite container              |
|                                                 |
|  +-- supervisord (PID 1) --------------------+  |
|  |                                           |  |
|  |  [hermes-gateway]   port 8642             |  |
|  |    hermes gateway run                     |  |
|  |                                           |  |
|  |  [hermes-dashboard] port 9119             |  |
|  |    hermes dashboard --host 0.0.0.0        |  |
|  |                                           |  |
|  |  [hermes-webui]     port 8787             |  |
|  |    python server.py                       |  |
|  |                                           |  |
|  |  [portcullis]  127.0.0.1:8080 (internal)  |  |
|  |    redacts every model call  ------------------> LLM provider
|  |                                           |  |
|  +-------------------------------------------+  |
|                                                 |
|  /opt/data  <-- mounted from ~/.hermes          |
+-------------------------------------------------+
```

## Prerequisites

- Podman v3.4.4+ or Docker
- podman-compose (or docker-compose)
- ~10GB disk space for the image
- Network access during build (for git clone and pip install)
- Works on both amd64 (x86_64) and arm64 (ARMv8) — tested on Jetson Orin NX

## Version Management

To ensure stability on edge devices (Jetson, ARM boards), it is highly recommended
to use **pinned versions** rather than building from the `main` branch HEAD.

### Using Pre-Built Images (Recommended)

If you prefer not to build manually, use our pre-verified image tags from
[GitHub Container Registry](https://github.com/cloudsbird/hermes-suite/pkgs/container/hermes-suite):

```bash
podman pull ghcr.io/cloudsbird/hermes-suite:0.23.1-0.52.544-r2
```

### Manual Build with Specific Versions

If you need a specific combination, pass the versions as build arguments:

```bash
podman build \
  --build-arg AGENT_VERSION=v0.23.1 \
  --build-arg HERMES_WEBUI_VERSION=v0.52.544 \
  -t hermes-suite:0.23.1-0.52.544 .
```

Or use the build helper (reads from `versions.env`):

```bash
# Podman or Docker (auto-detected at container startup)
./build.sh

# Build with Docker explicitly
./build.sh --docker

# Docker without logs (optional)
./build.sh --docker-nolog

# Override defaults:
# ./build.sh --agent v0.23.1 --webui v0.52.544
```

> **Docker compatibility:** Docker CE is auto-detected at container startup via /proc/1/cgroup.
> The universal image works on both Podman and Docker out of the box.
> Use `--docker-nolog` only if you prefer no log output.
> Set CONTAINER_RUNTIME in versions.env to control which runtime helper scripts use.

### Version Compatibility Table

Every release is an explicitly tested pair of Agent + WebUI on both amd64 and arm64.

| Suite Tag | Agent Version | WebUI Version | Tested |
|-----------|---------------|---------------|--------|
| `0.23.1-0.52.544-r2` | v0.23.1 | v0.52.544 | amd64 + arm64 |

> **Full version history:** https://github.com/sunnysktsang/hermes-suite/releases

### Version Tag Format

Suite tags follow the pattern `{agent_date}-{webui_semver}`:
- **Agent**: date-based version from `nousresearch/hermes-agent` (e.g. `v0.23.1`)
- **WebUI**: semantic version from `nesquena/hermes-webui` (e.g. `v0.52.544`)

The pinned pair for each release is declared in `versions.env`.

## Quick Start

### 1. Clone this repo

```bash
git clone https://github.com/sunnysktsang/hermes-suite.git
cd hermes-suite
```

### 2. Build the image

```bash
chmod +x *.sh
./build.sh
```

Or manually with pinned versions:

```bash
podman build \
  --build-arg AGENT_VERSION=v0.23.1 \
  --build-arg HERMES_WEBUI_VERSION=v0.52.544 \
  -t ghcr.io/cloudsbird/hermes-suite:0.23.1-0.52.544 .
```

### 3. Start the container

```bash
./up.sh
```

Or manually:

```bash
podman-compose up -d
```

### 4. Configure

Edit `~/.hermes/.env` to add your API keys, and `~/.hermes/config.yaml` for model settings.
These files are shared from the host via the volume mount. On first run, defaults are
created automatically from the hermes-agent examples.

### 5. Access

- Gateway:   http://localhost:8642
- WebUI:     http://localhost:8787
- Dashboard: http://localhost:9119 (login: admin/admin by default — see [Dashboard Authentication](#dashboard-authentication))

### Dashboard Authentication

Since hermes-agent v2026.7.1, the dashboard requires authentication to access
on a non-loopback bind. Hermes Suite provides this via the `DASHBOARD_CREDENTIAL`
setting in `versions.env`:

```env
# Default - works immediately, no setup needed:
DASHBOARD_CREDENTIAL=admin:admin

# Auto-generate a random password (printed by up.sh on first start):
DASHBOARD_CREDENTIAL=auto

# Use your own credentials:
DASHBOARD_CREDENTIAL=myuser:mypassword
```

The credential is displayed in the `up.sh` output when the container starts:

```
Hermes Suite is running:
  Gateway:    http://localhost:8642
  WebUI:      http://localhost:8787
  Dashboard:  http://localhost:9119

  Dashboard Login ID: admin
  Dashboard Password: admin
```

When set to `auto`, a random password is generated once and persisted to
`.dashboard_credential` (in the repo directory) so it survives container restarts.

### WebUI Authentication

The WebUI (port 8787) is a separate project (hermes-webui) with its own,
unrelated auth mechanism — setting `DASHBOARD_CREDENTIAL` has no effect on
it. It's controlled by `HERMES_WEBUI_PASSWORD`, which hermes-webui itself
describes as **required if you expose it beyond `127.0.0.1`** — unset means
no login on the WebUI at all, so this matters even for a plain `./up.sh`
setup on a machine reachable from your LAN, not just Dokploy.

Uncomment and set it in `versions.env`:

```env
HERMES_WEBUI_PASSWORD=some-strong-password
```

Unlike `DASHBOARD_CREDENTIAL`, there's no `admin:admin` default and no
`auto` option — leave it unset only if 8787 is truly staying on localhost.

## Configuration

All configuration is stored in `~/.hermes/` on the host (mounted as `/opt/data` inside
the container; override the host path with `HERMES_DATA`, see [Deploying with
Dokploy](#deploying-with-dokploy) for the named-volume alternative). On first start,
the entrypoint script copies default `.env` and `config.yaml` from the hermes-agent
examples if they don't already exist.

```
~/.hermes/
  .env            — API keys (OPENAI_API_KEY, TELEGRAM_TOKEN, etc.)
  config.yaml     — Model, toolsets, agent settings
  SOUL.md         — Agent personality
  skills/         — Custom skills
  memories/       — Persistent memory
  webui/          — WebUI state (sessions, workspace)
  portcullis/     — PII gateway state (taught terms, admin token, on/off marker)
```

## PII redaction (Portcullis)

The image includes [Portcullis](https://github.com/cloudsbird/Portcullis), a
local PII gateway. It is **on by default** and **transparent**: Hermes keeps
its own provider configuration (URL, key, headers) and does not know
Portcullis is there. Before a prompt leaves the container, private values such
as emails, phone numbers, keys and terms you taught are replaced with
placeholders like `<<EMAIL_1>>`. The real values are put back into the reply,
so the provider sees the task but never the identities.

**How it works.** A small hook (`portcullis_hook.py`) is loaded into the Hermes
and WebUI Python environments. Just before an LLM request is sent
(`POST …/chat/completions` or `POST …/v1/messages`, to any provider), it
re-points the request at Portcullis on `127.0.0.1:8080` and puts the original
URL in an `x-portcullis-upstream` header. Portcullis (passthrough mode)
redacts the prompt and forwards it to that URL **with Hermes' own key and
headers**, then rehydrates the reply. So:

- every provider works with no extra setup, including ones that need custom
  headers (e.g. opencode-go's `x-opencode-session`);
- side tasks, fallbacks and delegated subagents are covered too, even when
  they use a different provider;
- `config.yaml` is never modified. On first start, an older release's
  rewrite of `model.*` is put back automatically.

The startup banner shows `Portcullis: … active — every LLM call is redacted`.

**Turning it off.** Set `PORTCULLIS_ENABLED=false` in `versions.env` (for
`./up.sh`) or in the compose environment, then restart. For a quick test without
a restart, `touch`/`rm` the file `~/.hermes/portcullis/transparent` (the hook
checks it on every request).

**Teaching it your private terms** (client names, projects, colleagues). Any
term you teach is redacted on every later request:

```bash
podman exec hermes-suite sh -c 'curl -s -X POST 127.0.0.1:8080/teach \
  -H "Authorization: Bearer $(cat /opt/data/portcullis/admin_token)" \
  -H "content-type: application/json" -d "{\"term\":\"Project Loki\",\"label\":\"ORG\"}"'

# list taught terms / terms it spotted but you have not taught yet
podman exec hermes-suite sh -c 'curl -s 127.0.0.1:8080/terms \
  -H "Authorization: Bearer $(cat /opt/data/portcullis/admin_token)"'
podman exec hermes-suite sh -c 'curl -s 127.0.0.1:8080/suggestions \
  -H "Authorization: Bearer $(cat /opt/data/portcullis/admin_token)"'
```

The admin token is generated into `~/.hermes/portcullis/admin_token` on
first start; set `PORTCULLIS_ADMIN_TOKEN` to choose your own. Taught terms
live in `~/.hermes/portcullis/store.json`. That file is a map of everything
you consider private, so treat it as a secret.

**Optional ML detector.** By default only Portcullis' deterministic layers run:
taught terms plus regex for emails, phones, keys and so on, using about 13 MB of
RAM. The binary is built with ONNX support. To add the GLiNER2 detector (about
1.2 GB on disk and about 1.6 GB of RAM), export the model as described in the
[Portcullis docs](https://github.com/cloudsbird/Portcullis#the-detector-model),
put it under `~/.hermes/portcullis/model/`, and set
`PORTCULLIS_MODEL_DIR=/opt/data/portcullis/model` in the compose environment.
If the detector fails on a request, Portcullis still sends it with dictionary
and regex coverage (and rescans that text next turn). Set
`PORTCULLIS_DETECTOR_FAIL_CLOSED=1` to block such requests with a 503 instead.

**Limitations**

- Protocols Portcullis cannot redact are sent directly, **unredacted**, with
  a one-time `WARNING: … NOT redacted` in the log: the OpenAI Responses API
  (used by `openai-codex`), native Gemini, and Bedrock (which does not use
  httpx). Chat-completions and Anthropic Messages providers are covered.
- Only Python processes in the Hermes/WebUI venvs are hooked. A tool that calls
  an LLM from another runtime (Node, curl) goes direct.
- If Portcullis is down while the hook is active, model calls fail rather than
  bypass it. That is fail closed, by design. supervisord restarts it.
- Port 8080 is never published: Portcullis only listens on loopback. Do not add
  a port mapping for it.

## Stopping

```bash
./down.sh
```

## Viewing Logs

```bash
./logs.sh
```

All service logs stream to stdout/stderr (visible via `podman logs`). Supervisord
also writes to `/var/log/supervisor/` inside the container:

```bash
podman exec hermes-suite supervisorctl status
```

## Customization

### Changing component versions

Edit `versions.env` to change the pinned versions and runtime settings:

```env
AGENT_VERSION=v0.23.1
WEBUI_VERSION=v0.52.544

# Runtime selector: auto (default), podman, docker, docker-nolog
CONTAINER_RUNTIME=auto

# Use sudo for commands (rootful mode): true, false
USE_SUDO=false

# Dashboard login: "username:password", "auto", or "admin:admin" (default)
DASHBOARD_CREDENTIAL=admin:admin

# Include WhatsApp bridge: true, false (default: false)
ENABLE_WHATSAPP_BRIDGE=false

# Keep local Chromium browser tooling: true (default), false
# false produces an image without local Chromium, tagged `-slim`, for
# low-resource edge devices (use a cloud browser backend instead)
ENABLE_BROWSER=true
```

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| `CONTAINER_RUNTIME` | `auto`, `podman`, `docker`, `docker-nolog` | `auto` | Which runtime helper scripts use. `auto` detects at script time. |
| `USE_SUDO` | `true`, `false` | `false` | Run docker/podman commands with sudo (rootful mode) |
| `DASHBOARD_CREDENTIAL` | `admin:admin`, `auto`, `user:pass` | `admin:admin` | Dashboard login credential |
| `ENABLE_WHATSAPP_BRIDGE` | `true`, `false` | `false` | Include WhatsApp bridge in the built image |
| `ENABLE_BROWSER` | `true`, `false` | `true` | Keep local Chromium. `false` builds a `-slim` image without the base image's pinned Chromium, for low-resource edge devices. Since v0.23.1 Chromium ships in the base image's layers, so `-slim` no longer reduces pull size. |

Then rebuild:

```bash
./build.sh
```

Or override at build time:

```bash
./build.sh --agent v2026.4.16 --webui v0.50.244
```

### WhatsApp Bridge

The WhatsApp bridge is **not included** in the image by default. This is intentional:

- The bridge uses [Baileys](https://github.com/WhiskeySockets/Baileys) to emulate a WhatsApp Web session
- Without proper configuration, **anyone who messages your number gets full agent access** (terminal, filesystem, browser)
- See [upstream issue #15108](https://github.com/NousResearch/hermes-agent/issues/15108) for details

To include the WhatsApp bridge at build time:

```bash
# Option 1: CLI flag
./build.sh --whatsapp

# Option 2: Set in versions.env
ENABLE_WHATSAPP_BRIDGE=true
./build.sh
```

> **Warning:** If you enable the WhatsApp bridge, you **must** configure `WHATSAPP_ALLOWED_USERS`
> in `~/.hermes/.env` before starting the gateway. Without this setting, the bridge denies all
> incoming messages by default.

### Browser tooling and the -slim image

Set `ENABLE_BROWSER=false` (or run `./build.sh --no-browser`) to build an image without local browser tooling. The build removes the base image's pinned Chromium and tags the result with a `-slim` suffix (before v0.23.1 this saved ~1.1GB on arm64; since v0.23.1 Chromium ships in the base image's own layers, so removing it no longer reduces pull or disk size — `-slim` now only guarantees no local browser is present). This is intended for low-resource edge devices, which can use a cloud browser backend instead of local Chromium. The default (`true`) keeps the base image's Chromium.

```bash
# Option 1: CLI flag
./build.sh --no-browser

# Option 2: Set in versions.env
ENABLE_BROWSER=false
./build.sh
```

The effective setting is persisted: when the CLI flag deviates from what
`versions.env` records, `build.sh` writes the effective value back so that
`up.sh`/`down.sh` always derive the matching tag. A default build leaves the
file untouched (`--browser` flips a recorded `false` back to `true`).

What to expect from a `-slim` runtime:

- The `browser_*` toolset reports "not available" instead of attempting to
  launch Chromium — requests fail cleanly with a JSON error, no crash, and
  the other services are unaffected.
- The exact error hint varies by runtime. Under Docker the message points to
  the bundled image. Under Podman the agent's lazy-install logic may attempt
  a one-time ~170 MB Chromium download on first browser use (x86-64 only;
  disable via `security.allow_lazy_installs`).
- On ARM64 no official Chromium build exists, so local browser tooling is
  unavailable in either image — `-slim` costs nothing there.

### Changing the workspace path

Set `HERMES_WORKSPACE` before running `./up.sh`, or export it in your shell/`.env`:

```bash
HERMES_WORKSPACE=~/my-project ./up.sh
```

`~/workspace` is the default. Leaving `HERMES_WORKSPACE` unset entirely (e.g. under
Dokploy) falls back to a named Docker volume instead of a host path.

## Migration from Multi-Container Setup

If you are currently running the multi-container setup (hermes-agent + hermes-webui):

1. Stop the existing containers.

2. Build and start hermes-suite:
   ```bash
   cd hermes-suite
   ./build.sh
   ./up.sh
   ```

3. Your existing `~/.hermes/` data is reused automatically — no migration needed.

## Deploying with Dokploy

Use `docker-compose.dokploy.yaml` instead of the default compose file — it's tuned
for a remote VPS deploy instead of local Podman/Docker use:

- Pulls the pre-built image from GHCR instead of building on the server
  (building needs ~10GB disk and network access, and produces a 4GB+ image —
  too heavy to build on every redeploy).
- Stores persistent data (`/opt/data`, `/workspace`) in named Docker volumes
  instead of host bind mounts, since Dokploy's cloned repo directory isn't a
  reliable place to keep data across redeploys.
- Has no fixed container name or IP, so it won't collide with other apps on
  the same host.

### Setup

1. In Dokploy, create a new **Compose** application from this repository.
2. Set **Compose Path** to `docker-compose.dokploy.yaml`.
3. In the app's **Environment** tab, set at minimum:
   ```env
   DASHBOARD_CREDENTIAL=youruser:yourpassword
   HERMES_WEBUI_PASSWORD=some-strong-password
   ```
   The compose file refuses to start without both. `DASHBOARD_CREDENTIAL`
   gates the Dashboard (9119) via hermes-agent's own auth. `HERMES_WEBUI_PASSWORD`
   gates the WebUI (8787) via hermes-webui's own cookie-session login page —
   it's a separate mechanism with no default; without it the WebUI has no
   login at all, upstream (see [Dashboard Authentication](#dashboard-authentication)
   and [hermes-webui's docs](https://github.com/nesquena/hermes-webui/blob/master/.env.docker.example)
   for each one's details).
4. Optional overrides (same Environment tab):
   ```env
   # Pin a different image tag (see the Version Compatibility Table above),
   # or add -slim for the browser-less variant.
   HERMES_SUITE_IMAGE_TAG=0.23.1-0.52.544-r2

   # Avoid host port collisions with other apps on the same VPS.
   GATEWAY_PORT=8642
   WEBUI_PORT=8787
   DASHBOARD_PORT=9119
   ```
5. Deploy. Both services are now safe to reach directly on their host
   ports — the passwords above are enforced by the apps themselves, not by
   a proxy in front of them. To put them on your own HTTPS domain instead
   of raw host ports, add a Dokploy **Domain** for this app (Container Port
   `8787` for WebUI, `9119` for Dashboard) — that's additive, not required
   for the login to work.

### Notes

- First boot still needs to create `~/.hermes`-equivalent config inside the
  `hermes_data` volume (API keys, `config.yaml`, etc.). Use Dokploy's
  terminal for this app (or `docker exec -it <container> bash`, container
  name shown in Dokploy's UI since it isn't fixed in this compose file) to
  edit `/opt/data/.env` and `/opt/data/config.yaml`.
- Data in `hermes_data` and `hermes_workspace` persists across redeploys as
  long as you don't delete the volumes.

## Troubleshooting

### Upgrading from a version that used `agent_net`

Older versions required a pre-created external network (`agent_net`, static IP).
This is no longer needed — the container no longer joins a custom network. If you
had it created, it's now unused and safe to remove:

```bash
podman network rm agent_net   # or: docker network rm agent_net
```

### Permission errors on ~/.hermes

**Rootless Podman:**

The container runs as UID 10000, which maps to a host UID (e.g. 109999) per `/etc/subuid`.
Fix ownership on the host:

```bash
sudo chown -R 109999:109999 ~/.hermes
```

**Rootful Podman or Docker:**

Ownership is auto-corrected on startup. If issues persist:

```bash
sudo chown -R 10000:10000 ~/.hermes
```

### WebUI not loading

Check that the webui venv was built correctly:

```bash
podman exec hermes-suite /opt/hermes-webui/venv/bin/python -c "import yaml; print('OK')"
```

### Services fail with "EACCES making dispatchers" (Docker only)

This should not occur with the auto-detection feature (v2026.5.16-0.51.137+).
The container detects Docker at startup and adjusts the privilege model automatically.
Ensure you are using a recent image.

If it still occurs, ensure `tty: true` is NOT set in docker-compose.yaml.

### Dashboard returns connection error

The dashboard needs the gateway running first. Check supervisord status:

```bash
podman exec hermes-suite supervisorctl status
```

### Dashboard asks for a login

Since hermes-agent v2026.7.1, the dashboard requires authentication. The default
credential is `admin:admin` (configured in `versions.env`). To change it, see
[Dashboard Authentication](#dashboard-authentication).

### Build fails on git clone

Ensure the build host has network access. The hermes-webui repo is cloned at build
time. If your build environment has no internet, pre-clone the webui repo and adjust
the Dockerfile to `COPY` it instead of `git clone`.

### Build fails on `uv venv` or `pip not found`

The Dockerfile uses `uv` (pre-installed in the hermes-agent base image) to create
virtual environments and install packages. If you change the base image, ensure `uv`
is available at `/usr/local/bin/uv`.

## How It Works

The Dockerfile performs these steps:

1. **Base image** — Uses the official `nousresearch/hermes-agent` image which already
   contains Python 3.13, Node.js, npm, a pinned Chromium, the agent code, and the
   built-in dashboard.

2. **System packages** — Installs sudo, git, nano, network tools, and other utilities.

3. **Browser tools** — Keeps the base image's pinned Chromium for the browser toolset
   (or removes it for `-slim` builds).

4. **Supervisor** — Installs supervisord via pip into a dedicated venv at `/opt/supervisor`
   (not available in Debian Trixie apt repos).

5. **Hermes WebUI** — Clones from GitHub and installs into a separate venv at
   `/opt/hermes-webui/venv`, along with the agent's Python dependencies so the WebUI
   can import agent modules.

6. **Portcullis** — A Rust builder stage compiles the pinned
   [Portcullis](https://github.com/cloudsbird/Portcullis) commit
   (`PORTCULLIS_VERSION`) with `--features onnx`. Only the binary is copied into
   the image.

7. **Entrypoint** — `start.sh` handles UID/GID remapping (for rootless Podman),
   directory setup, config bootstrapping and Portcullis wiring before launching
   supervisord.

## Files

```
hermes-suite/
  Dockerfile           — Build definition (parameterized AGENT_VERSION + HERMES_WEBUI_VERSION)
  versions.env         — Pinned component versions for current release
  supervisord.conf     — Process manager config (4 services)
  start.sh             — Container entrypoint (UID setup + launch)
  portcullis_hook.py   — httpx hook that routes Hermes' LLM calls through Portcullis
  portcullis-run.sh    — supervisord launcher for Portcullis (passthrough mode)
  portcullis-hook-check.py — Proves the hook really loaded (build time + startup banner)
  portcullis-wire.py   — One-time migration: restores config.yaml rewired by older releases
  docker-compose.yaml  — Podman/Docker Compose configuration (local use)
  docker-compose.dokploy.yaml — Compose variant for Dokploy/remote VPS deploys
  build.sh             — Build helper script (reads versions.env)
  up.sh                — Start helper script
  down.sh              — Stop helper script
  logs.sh              — Log viewer helper script
  .dockerignore        — Build context exclusions
  .env.example         — Environment variable template
  README.md            — This file
```

## Tested On

| Platform | Arch | OS | Runtime | Status |
|----------|------|----|---------|--------|
| x86_64 (WSL2) | amd64 | Ubuntu 22.04 | Podman 3.4.4 | All 3 services running |
| x86_64 (WSL2) | amd64 | Ubuntu 22.04 | Docker CE 29.4.2 | All 3 services running |
| Jetson Orin NX 16GB | arm64 | Ubuntu 22.04 | Podman 3.4.4 | All 3 services running |

The base image `nousresearch/hermes-agent` provides multi-architecture manifests (amd64 + arm64).
Podman and Docker automatically pull the correct variant for your platform.
No changes to the Dockerfile are needed — it builds identically on both architectures.

## License

This project is licensed under the MIT License. The individual components are licensed separately:
- [hermes-agent](https://github.com/NousResearch/hermes-agent) — by Nous Research (MIT)
- [hermes-webui](https://github.com/nesquena/hermes-webui) — by nesquena (MIT)

Thanks to [nesquena](https://github.com/nesquena) for building hermes-webui and [referencing this project](https://github.com/nesquena/hermes-webui/blob/master/docs/docker.md) in the official Docker docs.

---

> If this project helps you, consider giving it a ⭐ on [GitHub](https://github.com/sunnysktsang/hermes-suite) — it helps others find it and keeps the project maintained.
<img src="https://hits.sh/github.com/sunnysktsang/hermes-suite.svg" width="0" height="0" style="display:none;">

"""Transparent Portcullis routing for every httpx/httpx2 client in this interpreter.

Loaded at interpreter start by ``portcullis_hook.pth`` (installed into the
hermes-agent and hermes-webui venvs). Hermes keeps its own provider config —
URL, key, headers — and never learns Portcullis exists: just before a request
is sent, an LLM call (``POST .../chat/completions`` or ``POST .../v1/messages``)
is re-pointed at the local Portcullis gateway, with the original URL in
``x-portcullis-upstream``. Portcullis (``PORTCULLIS_PASSTHROUGH=1``) redacts the
prompt, forwards it to that URL with Hermes' own credentials, and rehydrates
the reply.

Active only while ``$HERMES_HOME/portcullis/transparent`` exists (start.sh
creates it when Portcullis is enabled), so turning Portcullis off needs no
reinstall. Fails closed: if the gateway is down the call errors, it is never
sent around it.

Both ``httpx`` and ``httpx2`` are patched: openai<3 / anthropic<2 use httpx,
newer SDK majors moved to httpx2 (same client API).

Protocols Portcullis cannot redact (OpenAI Responses API, native Gemini) are
left alone with a one-time warning.
"""

import importlib.abc
import importlib.machinery
import logging
import os
import sys

GATEWAY = os.environ.get("PORTCULLIS_GATEWAY", "http://127.0.0.1:8080").rstrip("/")
UPSTREAM_HEADER = "x-portcullis-upstream"
_MARKER = os.path.join(os.environ.get("HERMES_HOME", "/opt/data"), "portcullis", "transparent")

HTTP_MODULES = ("httpx", "httpx2")

_log = logging.getLogger("portcullis_hook")
_warned = set()


def _active():
    # Checked per request (one stat) so enabling/disabling never needs a restart
    # of anything but Portcullis itself.
    if os.environ.get("PORTCULLIS_TRANSPARENT", "") == "0":
        return False
    try:
        os.stat(_MARKER)
        return True
    except FileNotFoundError:
        return False
    except OSError:
        # Can't tell (e.g. the state dir is not traversable for this user):
        # fail closed — route through the gateway rather than risk a bypass.
        return True


def _target_path(path):
    """Portcullis route for an LLM endpoint path, or None if not one."""
    if path.endswith("/chat/completions"):
        return "/v1/chat/completions"
    if path.endswith("/v1/messages"):
        return "/v1/messages"
    return None


def _warn_once(key, msg):
    if key not in _warned:
        _warned.add(key)
        _log.warning(msg)
        print(f"[portcullis] WARNING: {msg}", file=sys.stderr, flush=True)


def _rewrite(httpx, request):
    if request.method != "POST" or not _active():
        return
    url = request.url
    if request.headers.get(UPSTREAM_HEADER):
        return  # already routed (e.g. a retry of the same Request object)
    gateway = httpx.URL(GATEWAY)
    if url.host == gateway.host and url.port == gateway.port:
        return
    route = _target_path(url.path)
    if route is None:
        if url.path.endswith("/responses") or "generativelanguage.googleapis.com" in url.host:
            _warn_once(
                url.host + url.path.rsplit("/", 1)[-1],
                f"{url.host}{url.path} uses a protocol Portcullis cannot redact; sent directly, NOT redacted",
            )
        return
    request.headers[UPSTREAM_HEADER] = str(url)
    request.url = gateway.copy_with(path=route, query=None)
    request.headers["host"] = request.url.netloc.decode("ascii")


def _patch(httpx):
    if getattr(httpx, "_portcullis_patched", False):
        return
    sync_send = httpx.Client.send
    async_send = httpx.AsyncClient.send

    def send(self, request, *args, **kwargs):
        _rewrite(httpx, request)
        return sync_send(self, request, *args, **kwargs)

    async def asend(self, request, *args, **kwargs):
        _rewrite(httpx, request)
        return await async_send(self, request, *args, **kwargs)

    httpx.Client.send = send
    httpx.AsyncClient.send = asend
    httpx._portcullis_patched = True


class _Finder(importlib.abc.MetaPathFinder):
    """Patch an HTTP client module right after it is first imported, so
    interpreters that never use one pay nothing beyond loading this file."""

    def __init__(self, names):
        self.pending = set(names)

    def find_spec(self, name, path=None, target=None):
        if name not in self.pending:
            return None
        # A spec lookup is not an import (importlib.util.find_spec only asks), so
        # a module is only marked done once it has actually executed and been
        # patched. PathFinder hands out a fresh loader per call, so wrapping this
        # one never affects another lookup.
        spec = importlib.machinery.PathFinder.find_spec(name, path)
        if spec is None or spec.loader is None:
            return spec
        loader = spec.loader
        original_exec = loader.exec_module

        def exec_module(module):
            original_exec(module)
            try:
                _patch(module)
            except Exception as exc:  # never break the host program's import
                _warn_once("patch", f"could not install Portcullis routing: {exc}")
            self.pending.discard(name)
            if not self.pending and self in sys.meta_path:
                sys.meta_path.remove(self)

        loader.exec_module = exec_module
        return spec


def install():
    pending = []
    for name in HTTP_MODULES:
        if name in sys.modules:
            _patch(sys.modules[name])
        else:
            pending.append(name)
    if pending and not any(isinstance(f, _Finder) for f in sys.meta_path):
        sys.meta_path.insert(0, _Finder(pending))


install()

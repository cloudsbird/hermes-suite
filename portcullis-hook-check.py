#!/usr/bin/env python3
"""Exit 0 only if the .pth file already loaded portcullis_hook into THIS
interpreter and it patched every installed httpx flavour.

Deliberately never imports portcullis_hook itself: the point is to prove the
.pth fired. Used at image build time and by start.sh at boot, so the startup
banner never claims redaction is active when the hook is not loaded.
"""
import importlib
import importlib.util
import sys

if "portcullis_hook" not in sys.modules:
    sys.exit("portcullis_hook was not loaded by its .pth file")
mods = [n for n in ("httpx", "httpx2") if importlib.util.find_spec(n)]
if not mods:
    sys.exit("neither httpx nor httpx2 is installed")
unpatched = [n for n in mods if not getattr(importlib.import_module(n), "_portcullis_patched", False)]
if unpatched:
    sys.exit(f"not patched: {unpatched}")
print("portcullis hook active for: " + ", ".join(mods))

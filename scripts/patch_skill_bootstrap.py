#!/usr/bin/env python3
"""Reorder the graphify skill bootstrap so the local venv wins over uv.

Upstream SKILL.md tries `uv tool run --from graphifyy` first. On Termux uv
cannot build the Android grammar sdists (missing tree_sitter/parser.h), so a
session with uv installed but graphify off PATH falls into a slow build-fail
cascade instead of using the working ~/graphify-venv. This script rewrites
the detection block to: (1) standard Termux venv, (2) binary shebang,
(3) uv last. Idempotent: already-patched files are skipped.

Usage: patch_skill_bootstrap.py [SKILL.md ...]
Scans default roots when no files are given. Prints what it changed.
Exit 0 always (best-effort post-install step; never fail an install).
"""

import os
import sys

OLD_UV_FIRST = """# 1. uv tool installs \u2014 most reliable on modern Mac/Linux
if [ -z "$PYTHON" ] && command -v uv >/dev/null 2>&1; then
    _UV_PY=$(uv tool run --from graphifyy python -c "import sys; print(sys.executable)" 2>/dev/null)
    if [ -n "$_UV_PY" ]; then PYTHON="$_UV_PY"; fi
fi"""

NEW_VENV_FIRST = """# 1. Standard Termux venv (works even when graphify is not on PATH).
# uv tool installs go last: uv cannot build the Android grammar sdists, so
# preferring uv sends Termux sessions into a slow build-fail cascade.
if [ -z "$PYTHON" ] && [ -x "$HOME/graphify-venv/bin/python" ]; then
    "$HOME/graphify-venv/bin/python" -c "import graphify" 2>/dev/null && PYTHON="$HOME/graphify-venv/bin/python"
fi"""

OLD_UV_FALLBACK = """# 3. Fall back to python3
if [ -z "$PYTHON" ]; then PYTHON="python3"; fi"""

NEW_UV_LAST = """# 3. uv tool installs (desktop-reliable; Android-hostile, keep last)
if [ -z "$PYTHON" ] && command -v uv >/dev/null 2>&1; then
    _UV_PY=$(uv tool run --from graphifyy python -c "import sys; print(sys.executable)" 2>/dev/null)
    if [ -n "$_UV_PY" ]; then PYTHON="$_UV_PY"; fi
fi
# 4. Fall back to python3
if [ -z "$PYTHON" ]; then PYTHON="python3"; fi"""


def default_roots():
    home = os.path.expanduser("~")
    roots = [
        os.path.join(home, ".config", "opencode", "skills", "graphify"),
        os.path.join(home, ".opencode", "skills", "graphify"),
        os.path.join(home, ".gemini", "skills", "graphify"),
        os.path.join(home, ".gemini", "config", "skills", "graphify"),
    ]
    return roots


def patch_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except OSError as e:
        print(f"  skip {path}: {e}")
        return False
    if "Standard Termux venv (works even when graphify is not on PATH)" in src:
        print(f"  already patched: {path}")
        return False
    if OLD_UV_FIRST not in src or OLD_UV_FALLBACK not in src:
        print(f"  pattern not found (probably a new upstream layout): {path}")
        return False
    out = src.replace(OLD_UV_FIRST, NEW_VENV_FIRST).replace(OLD_UV_FALLBACK, NEW_UV_LAST)
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    print(f"  patched: {path}")
    return True


def main():
    files = list(sys.argv[1:])
    if not files:
        for root in default_roots():
            candidate = os.path.join(root, "SKILL.md")
            if os.path.isfile(candidate):
                files.append(candidate)
    if not files:
        print("no SKILL.md copies found; nothing to do")
        return 0
    changed = sum(1 for f in files if patch_file(f))
    print(f"done: {changed} file(s) patched, {len(files) - changed} untouched")
    return 0


if __name__ == "__main__":
    sys.exit(main())

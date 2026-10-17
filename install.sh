#!/bin/sh
# =============================================================================
# Graphify installer for Termux/Android (aarch64) — POSIX sh.
#
# Usage (from Termux):
#   curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-graphify/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --local /path/to/wheels   # local wheels
#   curl -fsSL .../install.sh | sh -s -- --tag <release-tag>       # pinned release
#
# What it does:
#   1. detects Termux + aarch64 (anything else aborts)
#   2. installs system deps: python, python-numpy, python-networkx (pkg)
#   3. downloads the android_arm64_v8a wheels from the GitHub release
#   4. creates a venv with --system-site-packages (native numpy/networkx)
#   5. installs the wheels + graphifyy 0.9.92 (--no-deps: all present here)
#   6. reorders local skill bootstraps (venv first) + smoke test
#
# Requirements: python3 (installed by the script itself via pkg), curl or gh.
# Compiles nothing on-device. Idempotent: re-running = updating.
# =============================================================================
set -eu

REPO="${REPO:-DARKBOYJYOTI/termux-graphify}"
GRAPHIFY_VERSION="${GRAPHIFY_VERSION:-0.9.92}"
VENV="${GRAPHIFY_VENV:-$HOME/graphify-venv}"
WHEEL_DIR="${GRAPHIFY_WHEEL_DIR:-$HOME/graphify-wheels}"
TAG=""                 # release tag; empty = releases/latest
LOCAL_DIR=""           # when set, nothing is downloaded from GitHub
SKIP_DEPS=0

# --- argument parsing (POSIX getopts) --------------------------------------
usage() {
    echo "usage: install.sh [--local DIR] [--tag TAG] [--skip-deps] [--install-dir DIR]"
    echo "     --local DIR       install wheels from a local directory (no GitHub)"
    echo "     --tag TAG         pinned release (default: latest)"
    echo "     --skip-deps       skip pkg install (assumes python/numpy/networkx)"
    echo "     --install-dir DIR alternate venv (default: \$HOME/graphify-venv)"
    echo "     env: REPO, GRAPHIFY_VERSION, GRAPHIFY_VENV, GRAPHIFY_WHEEL_DIR"
    exit 1
}
while [ $# -gt 0 ]; do
    case "$1" in
        --local) LOCAL_DIR="${2:-}"; [ -n "$LOCAL_DIR" ] || usage; shift 2 ;;
        --tag) TAG="${2:-}"; [ -n "$TAG" ] || usage; shift 2 ;;
        --skip-deps) SKIP_DEPS=1; shift ;;
        --install-dir) VENV="${2:-}"; [ -n "$VENV" ] || usage; shift 2 ;;
        -h|--help) usage ;;
        *) echo "ERROR: unknown argument: $1"; usage ;;
    esac
done

# --- platform guards --------------------------------------------------------
if [ -z "${TERMUX_VERSION:-}" ] && [ -z "${PREFIX:-}" ]; then
    echo "ERROR: this must run on Termux (Android). Aborting." >&2
    exit 1
fi
case "$(uname -m)" in
    aarch64|arm64|armv8*) : ;;
    *) echo "ERROR: only aarch64/arm64 is supported (found $(uname -m)). Aborting." >&2; exit 1 ;;
esac
PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "ERROR: no python3; run: pkg install python"; exit 1; }

echo "== [1/7] system deps =="
if [ "$SKIP_DEPS" = "0" ]; then
    # Native python-numpy/python-networkx: correct ABI for bionic aarch64
    # (PyPI numpy wheels do not install on Termux). Never pip install numpy.
    yes | pkg install -y python-numpy python-networkx || {
        echo "WARN: pkg install failed; continuing (verify python-numpy/python-networkx manually)" >&2
    }
else
    echo "  (--skip-deps: assuming python-numpy/python-networkx are installed)"
fi

echo "== [2/7] fetching wheels =="
mkdir -p "$WHEEL_DIR"
N_WHEELS=0
if [ -n "$LOCAL_DIR" ]; then
    echo "  using local wheels: $LOCAL_DIR"
    WHEEL_DIR="$LOCAL_DIR"
else
    if command -v gh >/dev/null 2>&1; then
        echo "  downloading via gh CLI (repo=$REPO tag=${TAG:-latest})"
        if [ -n "$TAG" ]; then
            gh release download --repo "$REPO" --pattern '*.whl' --dir "$WHEEL_DIR" "$TAG" \
                || GH_FALLBACK=1
        else
            gh release download --repo "$REPO" --pattern '*.whl' --dir "$WHEEL_DIR" \
                || GH_FALLBACK=1
        fi
        # gh may exist but fail (no auth, network, etc.) — fall back to the API
        if [ "$(ls "$WHEEL_DIR"/*.whl 2>/dev/null | wc -l)" = "0" ]; then
            echo "  gh failed or downloaded nothing; falling back to the API"
            GH_FALLBACK=1
        fi
    fi
    if [ "${GH_FALLBACK:-0}" = "1" ] || ! command -v gh >/dev/null 2>&1; then
        # fallback without gh: GitHub API + python3 (Termux always has python)
        if [ -n "$TAG" ]; then
            RELEASE_URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
        else
            RELEASE_URL="https://api.github.com/repos/$REPO/releases/latest"
        fi
        echo "  downloading via API (no gh): $RELEASE_URL"
        curl -fsSL "$RELEASE_URL" | python3 -c '
import json, sys, urllib.request
d = json.load(sys.stdin)
urls = [a["browser_download_url"] for a in d.get("assets", []) if a["name"].endswith(".whl")]
if not urls:
    print("ERROR: release has no wheels", file=sys.stderr); sys.exit(1)
print("\n".join(urls))
' > "$WHEEL_DIR/urls.txt" || { echo "ERROR: could not list release assets"; exit 1; }
        while IFS= read -r url; do
            [ -n "$url" ] || continue
            curl -fsSL --output-dir "$WHEEL_DIR" -O "$url" || {
                echo "ERROR: failed downloading $url"; exit 1; }
        done < "$WHEEL_DIR/urls.txt"
        rm -f "$WHEEL_DIR/urls.txt"
    fi
fi
N_WHEELS=$(ls "$WHEEL_DIR"/*.whl 2>/dev/null | wc -l)
[ "$N_WHEELS" -gt 0 ] || { echo "ERROR: no wheels in $WHEEL_DIR"; exit 1; }
echo "  wheels available: $N_WHEELS"

echo "== [3/7] creating venv (--system-site-packages: native numpy/networkx) =="
# Termux ensurepip may lack its bundled wheel, failing plain venv creation.
# Strategy: try a normal venv; if pip ends up missing, point at system pip;
# as a last resort, --target + a manual wrapper.
if [ ! -x "$VENV/bin/python" ]; then
    if ! python3 -m venv "$VENV" --system-site-packages 2>/dev/null; then
        echo "  plain venv failed (ensurepip); retrying with --without-pip"
        python3 -m venv "$VENV" --without-pip --system-site-packages
    fi
fi
VENV_PY="$VENV/bin/python"
if ! "$VENV_PY" -m pip --version >/dev/null 2>&1; then
    echo "  venv has no pip; installing system pip into the venv..."
    if ! python3 -m pip --python "$VENV_PY" install --upgrade pip >/dev/null 2>&1; then
        echo "  pip --python failed; entry points will be created manually"
        NO_PIP=1
    fi
fi

echo "== [4/7] installing wheels + graphifyy =="
# 1) local wheels (all --no-deps: everything needed is already here)
if "$VENV_PY" -m pip --version >/dev/null 2>&1; then
    "$VENV_PY" -m pip install --no-index --no-deps --find-links "$WHEEL_DIR" \
        "$WHEEL_DIR"/*.whl || { echo "ERROR: installing wheels"; exit 1; }
else
    # no pip in the venv: use system pip with --target (Python version derived,
    # never hardcoded — Termux python upgrades must not break this path)
    SP="$("$VENV_PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
    mkdir -p "$SP"
    for w in "$WHEEL_DIR"/*.whl; do
        python3 -m pip install --no-deps --no-index --target "$SP" "$w" || {
            echo "ERROR: installing $w"; exit 1; }
    done
fi
# 2) graphifyy: when the release carries the patched (+termux) wheel, install
#    from there (never PyPI). Otherwise fall back to PyPI with --no-deps:
#    native numpy/networkx from the system + our installed wheels (tree-sitter
#    0.26.0 deliberately outside graphify's <0.26 range to cover all grammars).
GFX_WHEEL="$(ls "$WHEEL_DIR"/graphifyy-*.whl 2>/dev/null | head -1 || true)"
if [ -n "$GFX_WHEEL" ]; then
    echo "  installing graphifyy from release wheel: $(basename "$GFX_WHEEL")"
    if "$VENV_PY" -m pip --version >/dev/null 2>&1; then
        "$VENV_PY" -m pip install --no-deps --no-index "$GFX_WHEEL" \
            || { echo "ERROR: installing graphifyy (wheel)"; exit 1; }
    else
        python3 -m pip install --no-deps --no-index --target "$SP" "$GFX_WHEEL" \
            || { echo "ERROR: installing graphifyy (wheel)"; exit 1; }
    fi
else
    if "$VENV_PY" -m pip --version >/dev/null 2>&1; then
        "$VENV_PY" -m pip install --no-deps "graphifyy==$GRAPHIFY_VERSION" \
            || { echo "ERROR: installing graphifyy"; exit 1; }
    else
        python3 -m pip install --no-deps --target "$SP" "graphifyy==$GRAPHIFY_VERSION" \
            || { echo "ERROR: installing graphifyy"; exit 1; }
    fi
fi

echo "== [5/7] launcher (entry point) =="
# with a normal pip the `graphify` entry point already exists; without pip
# (--target) create it manually
if [ ! -x "$VENV/bin/graphify" ]; then
    cat > "$VENV/bin/graphify" <<EOF
#!/bin/sh
exec "$VENV_PY" -m graphify "\$@"
EOF
    chmod +x "$VENV/bin/graphify"
    echo "  wrapper created: $VENV/bin/graphify"
fi

echo "== [6/7] skill bootstrap order (venv first; best-effort, never fatal) =="
# Upstream skill files prefer `uv tool run`, which cannot build Android
# grammar sdists — reorder local copies to venv-first so agent sessions never
# fall into a build-fail cascade. Same logic as scripts/patch_skill_bootstrap.py,
# inlined here because this installer runs standalone via curl.
python3 - <<'PY' 2>&1 || echo "  WARN: skill bootstrap patch skipped"
import os
OLD_UV_FIRST = "# 1. uv tool installs \u2014 most reliable on modern Mac/Linux\nif [ -z \"$PYTHON\" ] && command -v uv >/dev/null 2>&1; then\n    _UV_PY=$(uv tool run --from graphifyy python -c \"import sys; print(sys.executable)\" 2>/dev/null)\n    if [ -n \"$_UV_PY\" ]; then PYTHON=\"$_UV_PY\"; fi\nfi"
NEW_VENV_FIRST = "# 1. Standard Termux venv (works even when graphify is not on PATH).\n# uv tool installs go last: uv cannot build the Android grammar sdists, so\n# preferring uv sends Termux sessions into a slow build-fail cascade.\nif [ -z \"$PYTHON\" ] && [ -x \"$HOME/graphify-venv/bin/python\" ]; then\n    \"$HOME/graphify-venv/bin/python\" -c \"import graphify\" 2>/dev/null && PYTHON=\"$HOME/graphify-venv/bin/python\"\nfi"
OLD_FALLBACK = "# 3. Fall back to python3\nif [ -z \"$PYTHON\" ]; then PYTHON=\"python3\"; fi"
NEW_LAST = "# 3. uv tool installs (desktop-reliable; Android-hostile, keep last)\nif [ -z \"$PYTHON\" ] && command -v uv >/dev/null 2>&1; then\n    _UV_PY=$(uv tool run --from graphifyy python -c \"import sys; print(sys.executable)\" 2>/dev/null)\n    if [ -n \"$_UV_PY\" ]; then PYTHON=\"$_UV_PY\"; fi\nfi\n# 4. Fall back to python3\nif [ -z \"$PYTHON\" ]; then PYTHON=\"python3\"; fi"
SENTINEL = "Standard Termux venv (works even when graphify is not on PATH)"
roots = ["~/.config/opencode/skills/graphify", "~/.opencode/skills/graphify",
         "~/.gemini/skills/graphify", "~/.gemini/config/skills/graphify"]
done_n = 0
for r in roots:
    p = os.path.join(os.path.expanduser(r), "SKILL.md")
    if not os.path.isfile(p):
        continue
    try:
        src = open(p, encoding="utf-8").read()
    except OSError:
        continue
    if SENTINEL in src:
        continue
    if OLD_UV_FIRST not in src or OLD_FALLBACK not in src:
        print(f"  pattern not found (new upstream layout?): {p}")
        continue
    open(p, "w", encoding="utf-8").write(src.replace(OLD_UV_FIRST, NEW_VENV_FIRST).replace(OLD_FALLBACK, NEW_LAST))
    print(f"  patched: {p}")
    done_n += 1
print(f"  skill bootstrap: {done_n} file(s) patched")
PY

echo "== [7/7] smoke test =="
"$VENV/bin/graphify" --help >/dev/null 2>&1 \
    || { echo "ERROR: graphify does not start; see the message above"; exit 1; }
echo "  OK: graphify $GRAPHIFY_VERSION installed in $VENV"
echo
echo "Installed grammars:"
"$VENV_PY" - <<'PY'
import importlib, pkgutil
mods = sorted(m.name for m in pkgutil.iter_modules() if m.name.startswith("tree_sitter_"))
for m in mods:
    try:
        importlib.import_module(m)
        print(f"  OK   {m}")
    except Exception as e:
        print(f"  FAIL {m}: {e}")
PY
echo
echo "Done. Inside a project, use:"
echo "  $VENV/bin/graphify extract . --code-only --no-cluster   # index code (no LLM)"
echo "  $VENV/bin/graphify query \"how does X work\"              # ask the graph"
echo "  $VENV/bin/graphify install                             # register the skill"

# === Global symlink in ~/.local/bin (no venv activation needed) ===
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
WRAPPER="$LOCAL_BIN/graphify"
cat > "$WRAPPER" <<WRAPPER_EOF
#!/data/data/com.termux/files/usr/bin/sh
exec "$VENV_PY" -m graphify "\$@"
WRAPPER_EOF
chmod +x "$WRAPPER"
echo
echo "=== INSTALLED GLOBALLY ==="
echo "  $WRAPPER -> $VENV"
echo "  graphify should now be on your PATH:  command -v graphify"
echo "  If missing, add to your shell:"
echo "    export PATH=\"$LOCAL_BIN:\$PATH\""
echo "  (added automatically to ~/.bashrc when absent)"
echo
# Append to ~/.bashrc only when missing
if ! grep -q "\.local/bin" "$HOME/.bashrc" 2>/dev/null; then
    echo "export PATH=\"$LOCAL_BIN:\$PATH\"" >> "$HOME/.bashrc"
    echo "  [PATH added to ~/.bashrc]"
fi
echo "  Try: graphify --help"

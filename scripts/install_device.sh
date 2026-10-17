#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Installs Graphify (graphifyy) on Termux using the android wheels from the
# GitHub release. Compiles NOTHING on-device: downloads and installs only.
#
# Usage:
#   bash install_device.sh                 # latest GitHub release
#   bash install_device.sh --local DIR     # local wheels (test before release)
#   REPO=user/repo bash install_device.sh
#
# Requirements: python (3.14, native numpy/networkx via python-numpy),
#               gh CLI logged in (or curl + python).
# =============================================================================
set -euo pipefail

REPO="${REPO:-DARKBOYJYOTI/termux-graphify}"
VENV="${GRAPHIFY_VENV:-$HOME/graphify-venv}"
WHEEL_DIR="$HOME/graphify-wheels"
GRAPHIFY_VERSION="${GRAPHIFY_VERSION:-0.9.92}"
MODE="github"

if [ "${1:-}" = "--local" ]; then
  MODE="local"
  WHEEL_DIR="${2:?missing local wheels directory}"
fi

echo "== [1/5] fetching wheels =="
mkdir -p "$WHEEL_DIR"
if [ "$MODE" = "github" ]; then
  if command -v gh >/dev/null 2>&1; then
    gh release download --repo "$REPO" --pattern '*.whl' --dir "$WHEEL_DIR" \
      || { echo "gh release download failed (release published? try --local)"; exit 1; }
  else
    # fallback without gh: GitHub API + python (Termux always has python).
    # Pure-bash tag extraction: piping curl into `grep -m1` lets grep close
    # the pipe early and kills curl with SIGPIPE — never do that here.
    _rel_json="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" \
      || { echo "could not reach the release feed"; exit 1; }
    _tag="${_rel_json#*\"tag_name\": \"}"
    LATEST="${_tag%%\"*}"
    [ -n "$LATEST" ] || { echo "could not resolve the latest release of $REPO"; exit 1; }
    _assets_json="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$LATEST")" \
      || { echo "could not list release assets"; exit 1; }
    _urls="$(printf '%s' "$_assets_json" | python3 -c 'import json,sys; [print(a["browser_download_url"]) for a in json.load(sys.stdin).get("assets",[]) if a["name"].endswith(".whl")]')"
    [ -n "$_urls" ] || { echo "release has no wheels"; exit 1; }
    while IFS= read -r asset; do
      [ -n "$asset" ] || continue
      curl -fsSL --output-dir "$WHEEL_DIR" -O "$asset" < /dev/null || {
        echo "failed downloading $asset"; exit 1; }
    done <<EOF
$_urls
EOF
  fi
fi
N_WHEELS="$(ls "$WHEEL_DIR"/*.whl 2>/dev/null | wc -l)"
[ "$N_WHEELS" -gt 0 ] || { echo "no wheels in $WHEEL_DIR"; exit 1; }
echo "downloaded wheels: $N_WHEELS"

echo "== [2/5] creating venv (--system-site-packages: native numpy/networkx) =="
PYBIN="$(command -v python || command -v python3)" || { echo "no python found; pkg install python"; exit 1; }
if [ ! -d "$VENV" ]; then
  "$PYBIN" -m venv "$VENV" --system-site-packages
fi

echo "== [3/5] installing wheels + graphifyy =="
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install --no-deps --no-index --find-links "$WHEEL_DIR" "$WHEEL_DIR"/*.whl
# graphifyy: prefer the patched (+termux) wheel from the release when present;
# fall back to PyPI with --no-deps (system numpy/networkx + our installed
# wheels: tree-sitter 0.26.0 deliberately outside graphify's <0.26 range to
# cover all grammars).
GFX_WHEEL="$(ls "$WHEEL_DIR"/graphifyy-*.whl 2>/dev/null | head -1 || true)"
if [ -n "$GFX_WHEEL" ]; then
  echo "  installing graphifyy from release wheel: $(basename "$GFX_WHEEL")"
  "$VENV/bin/pip" install --no-deps --no-index "$GFX_WHEEL"
else
  "$VENV/bin/pip" install --no-deps "graphifyy==$GRAPHIFY_VERSION"
fi

echo "== [4/5] smoke test =="
"$VENV/bin/graphify" --version
echo
echo "Installed grammars:"
"$VENV/bin/python" - <<'PY'
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
echo "Done. Use: $VENV/bin/graphify build <path>"
echo "To register the skill elsewhere: $VENV/bin/graphify install"
echo
echo "== [5/5] skill bootstrap order (venv first; best-effort, never fatal) =="
# Upstream skill files prefer `uv tool run`, which cannot build Android
# grammar sdists — reorder to venv-first wherever local copies exist.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/patch_skill_bootstrap.py" 2>&1 || echo "WARN: skill bootstrap patch skipped"

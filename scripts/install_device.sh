#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Instala Graphify (graphifyy) en Termux usando los wheels android del release
# de GitHub. No compila NADA en el dispositivo: solo descarga e instala.
#
# Uso:
#   bash install_device.sh                 # ultimo release de GitHub
#   bash install_device.sh --local DIR     # wheels locales (para probar antes)
#   REPO=usuario/repo bash install_device.sh
#
# Requisitos: python (3.14, con numpy/networkx nativos via python-numpy),
#             gh CLI logueado (o curl + jq), git.
# =============================================================================
set -euo pipefail

REPO="${REPO:-DARKBOYJYOTI/termux-graphify}"
VENV="${GRAPHIFY_VENV:-$HOME/graphify-venv}"
WHEEL_DIR="$HOME/graphify-wheels"
GRAPHIFY_VERSION="${GRAPHIFY_VERSION:-0.9.92}"
MODE="github"

if [ "${1:-}" = "--local" ]; then
  MODE="local"
  WHEEL_DIR="${2:?falta el directorio de wheels locales}"
fi

echo "== [1/4] obtener wheels =="
mkdir -p "$WHEEL_DIR"
if [ "$MODE" = "github" ]; then
  if command -v gh >/dev/null 2>&1; then
    gh release download --repo "$REPO" --pattern '*.whl' --dir "$WHEEL_DIR" \
      || { echo "gh release download fallo (¿hay release publicado? prueba con --local)"; exit 1; }
  else
    # fallback: API de GitHub + jq (sin gh)
    LATEST="$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | python -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tag_name",""))')"
    [ -n "$LATEST" ] || { echo "no se pudo resolver el ultimo release de $REPO"; exit 1; }
    for asset in $(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | python -c 'import json,sys; [print(a["browser_download_url"]) for a in json.load(sys.stdin).get("assets",[]) if a["name"].endswith(".whl")]'); do
      curl -sLO --output-dir "$WHEEL_DIR" "$asset"
    done
  fi
fi
N_WHEELS="$(ls "$WHEEL_DIR"/*.whl 2>/dev/null | wc -l)"
[ "$N_WHEELS" -gt 0 ] || { echo "no hay wheels en $WHEEL_DIR"; exit 1; }
echo "wheels descargados: $N_WHEELS"

echo "== [2/4] crear venv (--system-site-packages: numpy/networkx nativos) =="
if [ ! -d "$VENV" ]; then
  python -m venv "$VENV" --system-site-packages
fi

echo "== [3/4] instalar wheels + graphifyy =="
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install --no-deps "$WHEEL_DIR"/*.whl
# graphifyy se instala con --no-deps: sus deps ya estan satisfechas por el
# sistema (numpy/networkx) y los wheels del release (tree-sitter 0.26.0 —
# deliberadamente fuera del rango <0.26 de graphify para soportar todas las
# grammars —, grammars shims, rapidfuzz).
"$VENV/bin/pip" install --no-deps "graphifyy==$GRAPHIFY_VERSION"

echo "== [4/4] smoke test =="
"$VENV/bin/graphify" --version
echo
echo "Grammars instaladas:"
"$VENV/bin/python" - <<'PY'
import importlib, pkgutil, re
mods = sorted(m.name for m in pkgutil.iter_modules() if m.name.startswith("tree_sitter_"))
for m in mods:
    try:
        importlib.import_module(m)
        print(f"  OK   {m}")
    except Exception as e:
        print(f"  FAIL {m}: {e}")
PY
echo
echo "Listo. Usa: $VENV/bin/graphify build <ruta>"
echo "Para registrar el skill en Hermes: $VENV/bin/graphify install"

#!/bin/sh
# =============================================================================
# Instalador de Graphify para Termux/Android (aarch64) — POSIX sh.
#
# Uso (desde Termux):
#   curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-graphify/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --local /ruta/a/wheels     # wheels locales
#   curl -fsSL .../install.sh | sh -s -- --tag ci-31982376550      # release especifico
#
# Qué hace:
#   1. detecta Termux + aarch64 (el resto se aborta)
#   2. instala deps del sistema: python, python-numpy, python-networkx (pkg)
#   3. descarga los wheels android_arm64_v8a del release de GitHub
#   4. crea un venv con --system-site-packages (numpy/networkx nativos)
#   5. instala los wheels + graphifyy 0.9.44 (--no-deps: ya estan todos aqui)
#   6. smoke test y mensaje de uso
#
# Requisitos: python3 (lo instala el propio script via pkg), curl o gh.
# NO compila nada en el dispositivo. Es idempotente: re-ejecutar = actualizar.
# =============================================================================
set -eu

REPO="${REPO:-DARKBOYJYOTI/termux-graphify}"
GRAPHIFY_VERSION="${GRAPHIFY_VERSION:-0.9.44}"
VENV="${GRAPHIFY_VENV:-$HOME/graphify-venv}"
WHEEL_DIR="${GRAPHIFY_WHEEL_DIR:-$HOME/graphify-wheels}"
TAG=""                 # release tag; vacio = releases/latest
LOCAL_DIR=""           # si se pasa, no se descarga nada de GitHub
SKIP_DEPS=0

# --- parseo de argumentos (POSIX getopts) ------------------------------------
usage() {
    echo "uso: install.sh [--local DIR] [--tag TAG] [--skip-deps] [--install-dir DIR]"
    echo "     --local DIR       instala wheels de un directorio local (no GitHub)"
    echo "     --tag TAG         release especifico (default: latest)"
    echo "     --skip-deps       no ejecuta pkg install (asume python/numpy/networkx)"
    echo "     --install-dir DIR venv alternativo (default: \$HOME/graphify-venv)"
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
        *) echo "ERROR: argumento desconocido: $1"; usage ;;
    esac
done

# --- guards de plataforma -----------------------------------------------------
if [ -z "${TERMUX_VERSION:-}" ] && [ -z "${PREFIX:-}" ]; then
    echo "ERROR: esto debe correr en Termux (Android). Abortando." >&2
    exit 1
fi
case "$(uname -m)" in
    aarch64|arm64|armv8*) : ;;
    *) echo "ERROR: solo aarch64/arm64 es compatible (tienes $(uname -m)). Abortando." >&2; exit 1 ;;
esac
PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "ERROR: no hay python3; ejecuta: pkg install python"; exit 1; }

echo "== [1/6] deps del sistema =="
if [ "$SKIP_DEPS" = "0" ]; then
    # python-numpy/python-networkx nativos: ABI correcto para bionic aarch64
    # (los wheels de PyPI de numpy no instalan en Termux). Nunca pip install numpy.
    yes | pkg install -y python-numpy python-networkx || {
        echo "WARN: pkg install fallo; continuando (verifica python-numpy/python-networkx a mano)" >&2
    }
else
    echo "  (--skip-deps: asumiendo python-numpy/python-networkx ya instalados)"
fi

echo "== [2/6] obtener wheels =="
mkdir -p "$WHEEL_DIR"
N_WHEELS=0
if [ -n "$LOCAL_DIR" ]; then
    echo "  usando wheels locales: $LOCAL_DIR"
    WHEEL_DIR="$LOCAL_DIR"
else
    if command -v gh >/dev/null 2>&1; then
        echo "  descargando via gh CLI (repo=$REPO tag=${TAG:-latest})"
        if [ -n "$TAG" ]; then
            gh release download --repo "$REPO" --pattern '*.whl' --dir "$WHEEL_DIR" "$TAG" \
                || GH_FALLBACK=1
        else
            gh release download --repo "$REPO" --pattern '*.whl' --dir "$WHEEL_DIR" \
                || GH_FALLBACK=1
        fi
        # gh puede existir pero fallar (sin auth, red, etc.) — caer a la API
        if [ "$(ls "$WHEEL_DIR"/*.whl 2>/dev/null | wc -l)" = "0" ]; then
            echo "  gh fallo o no descargo; usando fallback por API"
            GH_FALLBACK=1
        fi
    fi
    if [ "${GH_FALLBACK:-0}" = "1" ] || ! command -v gh >/dev/null 2>&1; then
        # fallback sin gh: API de GitHub + python3 (Termux siempre tiene python)
        if [ -n "$TAG" ]; then
            RELEASE_URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
        else
            RELEASE_URL="https://api.github.com/repos/$REPO/releases/latest"
        fi
        echo "  descargando via API (sin gh): $RELEASE_URL"
        curl -fsSL "$RELEASE_URL" | python3 -c '
import json, sys, urllib.request
d = json.load(sys.stdin)
urls = [a["browser_download_url"] for a in d.get("assets", []) if a["name"].endswith(".whl")]
if not urls:
    print("ERROR: release sin wheels", file=sys.stderr); sys.exit(1)
print("\n".join(urls))
' > "$WHEEL_DIR/urls.txt" || { echo "ERROR: no pude listar assets del release"; exit 1; }
        while IFS= read -r url; do
            [ -n "$url" ] || continue
            curl -fsSL --output-dir "$WHEEL_DIR" -O "$url" || {
                echo "ERROR: fallo descargando $url"; exit 1; }
        done < "$WHEEL_DIR/urls.txt"
        rm -f "$WHEEL_DIR/urls.txt"
    fi
fi
N_WHEELS=$(ls "$WHEEL_DIR"/*.whl 2>/dev/null | wc -l)
[ "$N_WHEELS" -gt 0 ] || { echo "ERROR: no hay wheels en $WHEEL_DIR"; exit 1; }
echo "  wheels disponibles: $N_WHEELS"

echo "== [3/6] crear venv (--system-site-packages: numpy/networkx nativos) =="
# ensurepip de Termux puede carecer del wheel bundled -> python -m venv falla.
# Estrategia: intentar venv normal; si no queda pip, usar el pip del sistema
# apuntado al venv; como ultimo recurso, --target + wrapper manual.
if [ ! -x "$VENV/bin/python" ]; then
    if ! python3 -m venv "$VENV" --system-site-packages 2>/dev/null; then
        echo "  venv normal fallo (ensurepip); usando --without-pip"
        python3 -m venv "$VENV" --without-pip --system-site-packages
    fi
fi
VENV_PY="$VENV/bin/python"
if ! "$VENV_PY" -m pip --version >/dev/null 2>&1; then
    echo "  venv sin pip; instalando pip del sistema en el venv..."
    if ! python3 -m pip --python "$VENV_PY" install --upgrade pip >/dev/null 2>&1; then
        echo "  pip --python fallo; los entry points se crearan a mano"
        NO_PIP=1
    fi
fi

echo "== [4/6] instalar wheels + graphifyy =="
# 1) wheels locales (todos sin deps: ya estan todos aqui)
if "$VENV_PY" -m pip --version >/dev/null 2>&1; then
    "$VENV_PY" -m pip install --no-index --no-deps --find-links "$WHEEL_DIR" \
        "$WHEEL_DIR"/*.whl || { echo "ERROR: instalando wheels"; exit 1; }
else
    # sin pip en el venv: usar el pip del sistema con --target
    SP="$VENV/lib/python3.14/site-packages"
    mkdir -p "$SP"
    for w in "$WHEEL_DIR"/*.whl; do
        python3 -m pip install --no-deps --no-index --target "$SP" "$w" || {
            echo "ERROR: instalando $w"; exit 1; }
    done
fi
# 2) graphifyy: si el release trae el wheel parcheado (+termux), se instala de
#    ahi (sin tocar PyPI). Si no, cae a PyPI con --no-deps: numpy/networkx
#    nativos del sistema + nuestros wheels ya instalados (tree-sitter 0.26.0
#    deliberadamente fuera del rango <0.26 de graphify para soportar todas las
#    grammars).
GFX_WHEEL="$(ls "$WHEEL_DIR"/graphifyy-*.whl 2>/dev/null | head -1 || true)"
if [ -n "$GFX_WHEEL" ]; then
    echo "  instalando graphifyy desde wheel del release: $(basename "$GFX_WHEEL")"
    if "$VENV_PY" -m pip --version >/dev/null 2>&1; then
        "$VENV_PY" -m pip install --no-deps --no-index "$GFX_WHEEL" \
            || { echo "ERROR: instalando graphifyy (wheel)"; exit 1; }
    else
        python3 -m pip install --no-deps --no-index --target "$SP" "$GFX_WHEEL" \
            || { echo "ERROR: instalando graphifyy (wheel)"; exit 1; }
    fi
else
    if "$VENV_PY" -m pip --version >/dev/null 2>&1; then
        "$VENV_PY" -m pip install --no-deps "graphifyy==$GRAPHIFY_VERSION" \
            || { echo "ERROR: instalando graphifyy"; exit 1; }
    else
        python3 -m pip install --no-deps --target "$SP" "graphifyy==$GRAPHIFY_VERSION" \
            || { echo "ERROR: instalando graphifyy"; exit 1; }
    fi
fi

echo "== [5/6] launcher (entry point) =="
# con pip normal el entry point `graphify` ya existe; sin pip (--target) lo creamos
if [ ! -x "$VENV/bin/graphify" ]; then
    cat > "$VENV/bin/graphify" <<EOF
#!/bin/sh
exec "$VENV_PY" -m graphify "\$@"
EOF
    chmod +x "$VENV/bin/graphify"
    echo "  wrapper creado: $VENV/bin/graphify"
fi

echo "== [6/6] smoke test =="
"$VENV/bin/graphify" --help >/dev/null 2>&1 \
    || { echo "ERROR: graphify no arranca; revisa el mensaje arriba"; exit 1; }
echo "  OK: graphify $GRAPHIFY_VERSION instalado en $VENV"
echo
echo "Grammars instaladas:"
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
echo "Listo. Uso (dentro del proyecto):"
echo "  $VENV/bin/graphify extract . --code-only --no-cluster   # indexar codigo (sin LLM)"
echo "  $VENV/bin/graphify query \"como funciona X\"             # consultar el grafo"
echo "  $VENV/bin/graphify install                             # registrar el skill en Hermes"

# === Symlink en ~/.local/bin (accesible globalmente sin activar venv) ===
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
WRAPPER="$LOCAL_BIN/graphify"
cat > "$WRAPPER" <<WRAPPER_EOF
#!/data/data/com.termux/files/usr/bin/sh
exec "$VENV/bin/python" -m graphify "\$@"
WRAPPER_EOF
chmod +x "$WRAPPER"
echo
echo "=== INSTALADO GLOBALMENTE ==="
echo "  $WRAPPER -> $VENV"
echo "  graphify ya esta en tu PATH:  command -v graphify"
echo "  Si no aparece, anade a tu shell:"
echo "    export PATH=\"$LOCAL_BIN:\$PATH\""
echo "  (se anadio automaticamente a ~/.bashrc si no existia)"
echo
# Agregar a ~/.bashrc si no esta ya
if ! grep -q "\.local/bin" "$HOME/.bashrc" 2>/dev/null; then
    echo "export PATH=\"$LOCAL_BIN:\$PATH\"" >> "$HOME/.bashrc"
    echo "  [PATH agregado a ~/.bashrc]"
fi
echo "  Prueba: graphify --help"

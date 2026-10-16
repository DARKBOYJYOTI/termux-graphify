#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Construye wheels para Termux/Android (bionic aarch64) de:
#   tree-sitter core + grammars + rapidfuzz  (ver grammar_manifest.txt)
#
# Corre DENTRO del contenedor termux/termux-docker:latest (uid 1000), con el
# checkout montado en /workspace. NO corre en el dispositivo.
#
# Estrategia para las grammars (los bindings abi3 de PyPI son fragiles en
# Android: no exportan el scanner con -fvisibility=hidden y sus sdists nuevos
# no traen tree_sitter/parser.h):
#   1. extraer el sdist de cada grammar
#   2. compilar parser.c (+ scanner.c) a un .so puro con clang
#   3. generar un wheel "shim" (tree_sitter_<lang>/) con __init__.py que
#      expone language() + language_<simbolo>() cargando el .so via ctypes
#      (la API exacta que graphify espera, incl. language_typescript/tsx)
#
# Salida:
#   /workspace/wheels/  -> wheels que pasaron el test de runtime
#   /workspace/failed/  -> wheels que fallaron (build o ABI), con reporte
# =============================================================================
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
SCRIPTS="$WORKSPACE/scripts"
WHEELS="$WORKSPACE/wheels"
FAILED="$WORKSPACE/failed"
MANIFEST="$SCRIPTS/grammar_manifest.txt"
mkdir -p "$WHEELS" "$FAILED"
LOG="$HOME/build.log"
BUILD_DIR="$HOME/build"
SDIST_DIR="$HOME/sdists"
mkdir -p "$BUILD_DIR" "$SDIST_DIR"

echo "== [1/6] pkg update + upgrade (python debe coincidir con el dispositivo) =="
for i in 1 2 3; do
  pkg update -y && break || { echo "retry pkg update ($i)"; sleep 5; }
done
pkg upgrade -y || echo "WARN: pkg upgrade fallo parcialmente, continuando"

echo "== [2/6] toolchain =="
pkg install -y clang make cmake ninja python-numpy binutils curl

echo "== [3/6] pip base =="
python -m pip install --upgrade pip setuptools wheel

echo "== [4/6] headers de grammars (de master del repo tree-sitter) =="
# Los sdists de grammars de la era 0.24-0.26 NO incluyen tree_sitter/parser.h
# (por eso falla su build desde source). Los headers se bajan de master del
# repo tree-sitter (lib/src/), que define TSFieldMapSlice y es backward
# compatible con parser.c generados desde 0.24.
TS_HEADERS="$HOME/ts-headers"
mkdir -p "$TS_HEADERS/tree_sitter"
for h in parser.h alloc.h array.h ts_assert.h; do
  if [ ! -f "$TS_HEADERS/tree_sitter/$h" ]; then
    curl -fsSL "https://raw.githubusercontent.com/tree-sitter/tree-sitter/master/lib/src/$h" \
      -o "$TS_HEADERS/tree_sitter/$h" || { echo "ERROR: no pude bajar headers $h"; exit 1; }
  fi
done

# api.h del core (lib/include/tree_sitter/api.h): lo necesita alloc.c del core
# (que vinculamos para resolver ts_current_* en grammars como php).
if [ ! -f "$TS_HEADERS/tree_sitter/api.h" ]; then
  curl -fsSL "https://raw.githubusercontent.com/tree-sitter/tree-sitter/master/lib/include/tree_sitter/api.h" \
    -o "$TS_HEADERS/tree_sitter/api.h" || { echo "ERROR: no pude bajar api.h"; exit 1; }
fi

# alloc.c del core: define ts_current_calloc/realloc/free/allocator. Algunas
# grammars (php) referencian esas funciones del runtime en su parser.c/.so;
# si quedan sin resolver, se vinculan aqui al recompilar (ver mas abajo).
TS_RUNTIME_ALLOC="$HOME/ts-runtime-alloc.c"
if [ ! -f "$TS_RUNTIME_ALLOC" ]; then
  curl -fsSL "https://raw.githubusercontent.com/tree-sitter/tree-sitter/master/lib/src/alloc.c" \
    -o "$TS_RUNTIME_ALLOC" || { echo "ERROR: no pude bajar alloc.c"; exit 1; }
  # alloc.c hace `#include "alloc.h"`, pero solo tenemos el header bajado en
  # $TS_HEADERS/tree_sitter/alloc.h (TS_PUBLIC se define ahi). Con -I$TS_HEADERS
  # `"alloc.h"` no se resuelve y TS_PUBLIC queda indefinido (php falla con
  # "unknown type name 'TS_PUBLIC'"). Reescribimos el include con el prefijo
  # tree_sitter/ para que el header se encuentre.
  sed -i 's|#include "alloc.h"|#include "tree_sitter/alloc.h"|' "$TS_RUNTIME_ALLOC"
fi

echo "== [5/6] build (core/rapidfuzz: pip wheel | grammars: .so + shim) =="
rm -rf "$BUILD_DIR"/* "$SDIST_DIR"/*
# los headers ya extraidos en [4/6] no se tocan (estan en $TS_HEADERS)

while IFS= read -r spec; do
  # saltar lineas vacias y comentarios
  if [ -z "$spec" ] || [ "${spec#\#}" != "$spec" ]; then
    continue
  fi
  pkg="${spec%%==*}"
  ver="${spec##*==}"
  mod="${pkg//-/_}"

  # --- core y rapidfuzz: wheels normales de pip (compilan bien) ---
  if [ "$pkg" = "tree-sitter" ] || [ "$pkg" = "rapidfuzz" ]; then
    echo "--- build: $spec (pip wheel) ---"
    if python -m pip wheel --no-deps --no-binary :all: "$spec" -w "$WHEELS" --progress-bar off >"$LOG" 2>&1; then
      echo "OK  build: $spec"
    else
      echo "FAIL build: $spec"
      echo "=== $spec ===" >> "$FAILED/build-failed.txt"
      tail -25 "$LOG" >> "$FAILED/build-failed.txt"
    fi
    continue
  fi

  # --- grammars: sdist -> .so -> wheel shim ---
  echo "--- build: $spec (shim .so) ---"
  rm -rf "$BUILD_DIR/$mod"
  mkdir -p "$BUILD_DIR/$mod"
  pip download --no-deps --no-binary :all: "$spec" -d "$SDIST_DIR" --progress-bar off >/dev/null 2>&1
  sdist="$(ls "$SDIST_DIR"/"$pkg"-"$ver".tar.gz 2>/dev/null || ls "$SDIST_DIR"/"$mod"-"$ver".tar.gz 2>/dev/null || true)"
  if [ -z "$sdist" ]; then
    echo "FAIL download: $spec"
    echo "=== $spec ===" >> "$FAILED/build-failed.txt"
    echo "no se pudo descargar el sdist" >> "$FAILED/build-failed.txt"
    continue
  fi

  # Preferimos el tarball del repo de GitHub: trae parser.c + headers +
  # scanner.c del MISMO commit. (Los sdists de PyPI estan incompletos: sin
  # tree_sitter/parser.h, con parser.c regenerado que usa tipos que el
  # header no define — TSFieldMapSlice — y sin common/scanner.h en
  # typescript.) La URL del repo se extrae del PKG-INFO del sdist.
  REPO_URL="$(tar xzf "$sdist" -O --wildcards "*egg-info/PKG-INFO" 2>/dev/null | grep -aoE "https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+" | head -1)"
  GOT_SRC=0
  if [ -n "$REPO_URL" ]; then
    for TAG in "v$ver" "$ver"; do
      if curl -fsSL "${REPO_URL%/}/archive/refs/tags/$TAG.tar.gz" -o "$SDIST_DIR/$mod-src.tar.gz" 2>/dev/null; then
        rm -rf "$BUILD_DIR/$mod"
        mkdir -p "$BUILD_DIR/$mod"
        tar xzf "$SDIST_DIR/$mod-src.tar.gz" -C "$BUILD_DIR/$mod" --strip-components=1
        # si el tarball no tiene parser.c (repo con estructura distinta),
        # descartarlo y usar el sdist
        if [ -n "$(find "$BUILD_DIR/$mod" -name parser.c | head -1)" ]; then
          GOT_SRC=1
        fi
        break
      fi
    done
  fi
  if [ "$GOT_SRC" = "0" ]; then
    echo "WARN: sin tarball util del repo ($REPO_URL tag v$ver/$ver); uso el sdist"
    rm -rf "$BUILD_DIR/$mod"
    mkdir -p "$BUILD_DIR/$mod"
    tar xzf "$sdist" -C "$BUILD_DIR/$mod" --strip-components=1
  fi

  # Excluir examples/: tree-sitter-c trae examples/parser.c (que incluye
  # "runtime/parser.h", un fichero de test antiguo) y rompe la compilacion
  # si se compila junto con src/parser.c.
  PARSERS="$(find "$BUILD_DIR/$mod" -name parser.c | grep -v '/examples/' | sort)"
  SCANNERS="$(find "$BUILD_DIR/$mod" -name scanner.c | grep -v '/examples/' | sort || true)"
  if [ -z "$PARSERS" ]; then
    echo "FAIL sin parser.c: $spec"
    echo "=== $spec ===" >> "$FAILED/build-failed.txt"
    echo "sin parser.c en el sdist" >> "$FAILED/build-failed.txt"
    continue
  fi

  # headers: SIEMPRE incluir -I$TS_HEADERS (los headers de master del repo
  # tree-sitter: parser.h/array.h que los scanner.c de las grammars incluyen
  # como tree_sitter/parser.h y tree_sitter/array.h — esto arregla typescript
  # y php). Si la grammar trae SU propio tree_sitter/parser.h se añade tambien
  # (misma familia que su parser.c), pero nunca reemplaza a TS_HEADERS.
  HDR_ARGS="-I$TS_HEADERS"
  local_hdr="$(find "$BUILD_DIR/$mod" -path "*tree_sitter/parser.h" | head -1)"
  if [ -n "$local_hdr" ]; then
    HDR_ARGS="$HDR_ARGS -I$(dirname "$local_hdr")"
  fi

  if clang -shared -fPIC -O3 -std=c11 $HDR_ARGS $PARSERS $SCANNERS \
      -o "$BUILD_DIR/$mod/libtree-sitter-$mod.so" >"$LOG" 2>&1; then
    # Si el .so referencía funciones del runtime tree-sitter que quedan sin
    # resolver (p.ej. php usa ts_current_calloc/realloc/free de alloc.c del
    # core), recompilamos vinculando alloc.c para resolverlas en el propio .so.
    UNRESOLVED="$(nm -u "$BUILD_DIR/$mod/libtree-sitter-$mod.so" 2>/dev/null | awk '{print $2}' | grep -E '^ts_current_(calloc|realloc|free)$' || true)"
    if [ -n "$UNRESOLVED" ]; then
      echo "  recompilo con alloc.c del core para resolver: $UNRESOLVED"
      if clang -shared -fPIC -O3 -std=c11 $HDR_ARGS $PARSERS $SCANNERS "$TS_RUNTIME_ALLOC" \
          -o "$BUILD_DIR/$mod/libtree-sitter-$mod.so" >"$LOG" 2>&1; then
        echo "OK  compile: $spec (con alloc.c)"
      else
        echo "FAIL compile: $spec"
        echo "=== $spec ===" >> "$FAILED/build-failed.txt"
        tail -15 "$LOG" >> "$FAILED/build-failed.txt"
        continue
      fi
    else
      echo "OK  compile: $spec"
    fi
  else
    echo "FAIL compile: $spec"
    echo "=== $spec ===" >> "$FAILED/build-failed.txt"
    tail -15 "$LOG" >> "$FAILED/build-failed.txt"
    continue
  fi

  SYMBOLS="$(nm -D --defined-only "$BUILD_DIR/$mod/libtree-sitter-$mod.so" 2>/dev/null | awk '{print $3}' | grep '^tree_sitter_' || true)"
  if [ -z "$SYMBOLS" ]; then
    echo "FAIL sin simbolos tree_sitter_: $spec"
    echo "=== $spec ===" >> "$FAILED/build-failed.txt"
    echo "el .so no exporta tree_sitter_*" >> "$FAILED/build-failed.txt"
    continue
  fi

  # estructura del paquete shim: $mod/{__init__.py, libtree-sitter-$mod.so}
  mkdir -p "$BUILD_DIR/$mod/$mod"
  mv "$BUILD_DIR/$mod/libtree-sitter-$mod.so" "$BUILD_DIR/$mod/$mod/"

  (cd "$BUILD_DIR/$mod" && python - "$mod" "$pkg" "$ver" "$SYMBOLS" <<'PY'
import os
import sys
mod, pkg, ver, symbols = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
sopath = "libtree-sitter-%s.so" % mod
# graphify SIEMPRE hace Language(mod.language()). En el binding tree-sitter
# 0.26, Language() acepta una PyCapsule "tree_sitter.Language" o un PyLong
# (el puntero TSLanguage* como entero). Por eso language() devuelve el INT
# de llamar tree_sitter_X() con restype=c_void_p — NO un objeto Language ni
# un POINTER de ctypes (eso da "an integer is required").
# Los simbolos "external_scanner_*" son helpers del scanner, no lenguajes:
# se excluyen. Por cada lenguaje principal se define language_<sufijo>() y
# language() apunta al primer lenguaje (typescript expone language_typescript
# y language_tsx; el resto solo language_x + language()).
principals = [s for s in symbols if "external" not in s]
main = principals[0] if principals else None
lines = [
    "import ctypes, os",
    "",
    "_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), %r)" % sopath,
    "",
    "def _lib():",
    "    return ctypes.CDLL(_LIB)",
    "",
    "def _ptr(name):",
    "    lib = _lib()",
    "    fn = getattr(lib, name)",
    "    fn.restype = ctypes.c_void_p",
    "    return fn()",
    "",
]
for s in principals:
    suffix = s[len("tree_sitter_"):]
    lines += [
        "def language_%s():" % suffix,
        "    return _ptr(%r)" % s,
        "",
    ]
if main:
    lines += [
        "def language():",
        "    return _ptr(%r)" % main,
        "",
    ]
open(os.path.join(mod, "__init__.py"), "w").write("\n".join(lines))
PY
) >"$LOG" 2>&1 || { echo "FAIL shim gen: $spec"; tail -10 "$LOG" >> "$FAILED/build-failed.txt"; continue; }

  cat > "$BUILD_DIR/$mod/setup.py" <<PY
from setuptools import setup
setup(name="$pkg", version="$ver", packages=["$mod"], package_data={"$mod": ["*.so"]})
PY

  if (cd "$BUILD_DIR/$mod" && python setup.py bdist_wheel -d "$WHEELS") >"$LOG" 2>&1; then
    echo "OK  wheel: $spec"
  else
    echo "FAIL wheel: $spec"
    echo "=== $spec ===" >> "$FAILED/build-failed.txt"
    tail -15 "$LOG" >> "$FAILED/build-failed.txt"
  fi
done < "$MANIFEST"

echo "== [6/6] test de runtime (import + Language + parse) =="
# solo si hay al menos un wheel del core
if ls "$WHEELS"/tree_sitter-*.whl >/dev/null 2>&1; then
  python -m venv "$HOME/testvenv" --system-site-packages
  # instalar TODOS los wheels generados (sin deps: ya estan todos aqui)
  "$HOME/testvenv/bin/pip" install --no-index --no-deps --find-links "$WHEELS" \
    "$WHEELS"/*.whl >"$HOME/pip-test-install.log" 2>&1 \
    || { echo "FALLO instalando wheels en venv de test"; tail -20 "$HOME/pip-test-install.log"; exit 1; }
  # test_grammars.py mueve los wheels que fallan a FAILED/
  "$HOME/testvenv/bin/python" "$SCRIPTS/test_grammars.py" "$WHEELS" "$FAILED" \
    || echo "WARN: test_grammars.py termino con codigo != 0 (ver failed/)"
else
  echo "ERROR: no se construyo el wheel del core tree-sitter"
  exit 1
fi

echo
echo "== RESUMEN =="
echo "Wheels OK:   $(ls "$WHEELS"/*.whl 2>/dev/null | wc -l)"
echo "Wheels FAIL: $(ls "$FAILED"/*.whl 2>/dev/null | wc -l)"
ls "$WHEELS" 2>/dev/null

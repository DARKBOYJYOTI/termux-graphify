#!/usr/bin/env python3
"""Resuelve la version exacta de cada grammar tree-sitter dentro del rango
que pide graphifyy 0.9.44, consultando la API JSON de PyPI."""
import json
import urllib.request

# (paquete, rango) — copiado de pyproject.toml de graphifyy 0.9.44
DEPS = [
    ("tree-sitter", ">=0.23.0,<0.26"),
    ("tree-sitter-python", ">=0.23,<0.26"),
    ("tree-sitter-javascript", ">=0.23,<0.26"),
    ("tree-sitter-typescript", ">=0.23,<0.25"),
    ("tree-sitter-go", ">=0.23,<0.26"),
    ("tree-sitter-rust", ">=0.23,<0.25"),
    ("tree-sitter-java", ">=0.23,<0.25"),
    ("tree-sitter-groovy", ">=0.1,<0.3"),
    ("tree-sitter-c", ">=0.23,<0.25"),
    ("tree-sitter-cpp", ">=0.23,<0.25"),
    ("tree-sitter-ruby", ">=0.23,<0.25"),
    ("tree-sitter-c-sharp", ">=0.23,<0.25"),
    ("tree-sitter-kotlin", ">=1.0,<2.0"),
    ("tree-sitter-scala", ">=0.23,<0.27"),
    ("tree-sitter-php", ">=0.23,<0.25"),
    ("tree-sitter-swift", ">=0.7,<0.9"),
    ("tree-sitter-lua", ">=0.2,<0.6"),
    ("tree-sitter-zig", ">=1.0,<2.0"),
    ("tree-sitter-powershell", ">=0.26,<0.28"),
    ("tree-sitter-elixir", ">=0.3,<0.5"),
    ("tree-sitter-objc", ">=3.0,<4.0"),
    ("tree-sitter-julia", ">=0.23,<0.25"),
    ("tree-sitter-verilog", ">=1.0,<2.0"),
    ("tree-sitter-fortran", ">=0.6,<0.8"),
    ("tree-sitter-bash", ">=0.23,<0.27"),
    ("tree-sitter-json", ">=0.23,<0.26"),
    # deps no-grammar que tambien se compilan
    ("rapidfuzz", ">=3.0"),
]


def parse_range(r):
    """Devuelve (min_ver, min_incl, max_ver, max_excl) con min/max None si no hay."""
    lo = hi = None
    lo_inc = hi_exc = False
    for part in r.split(","):
        p = part.strip()
        if p.startswith(">="):
            lo, lo_inc = p[2:], True
        elif p.startswith(">"):
            lo, lo_inc = p[1:], False
        elif p.startswith("<="):
            hi, hi_exc = p[2:], False
        elif p.startswith("<"):
            hi, hi_exc = p[1:], True
    return lo, lo_inc, hi, hi_exc


def ver_key(v):
    return [int(x) for x in v.split(".")]


def in_range(v, lo, lo_inc, hi, hi_exc):
    k = ver_key(v)
    if lo and (k < ver_key(lo) or (k == ver_key(lo) and not lo_inc)):
        return False
    if hi and (k > ver_key(hi) or (k == ver_key(hi) and not hi_exc)):
        return False
    return True


for pkg, rng in DEPS:
    try:
        with urllib.request.urlopen(f"https://pypi.org/pypi/{pkg}/json", timeout=20) as resp:
            data = json.load(resp)
        lo, lo_inc, hi, hi_exc = parse_range(rng)
        vers = [v for v in data["releases"] if in_range(v, lo, lo_inc, hi, hi_exc)]
        # descartar pre-releases
        vers = [v for v in vers if all(c.isdigit() or c == "." for c in v)]
        vers.sort(key=ver_key)
        chosen = None
        for v in reversed(vers):
            has_sdist = any(
                f["packagetype"] == "sdist" for f in data["releases"].get(v, [])
            )
            if has_sdist:
                chosen = v
                break
        chosen = chosen or "NINGUNA"
        has_sdist = chosen != "NINGUNA"
        print(f"{pkg}  {rng:16s} -> {chosen:10s} sdist={has_sdist}")
    except Exception as e:
        print(f"{pkg}  ERROR: {e}")

#!/usr/bin/env python3
"""Test de runtime para los wheels tree-sitter compilados para Termux.

Corre con el python del venv de prueba (que ya tiene todos los wheels
instalados). Para cada wheel en wheels_dir:
  - importa su modulo (tree_sitter_<lang> / tree_sitter / rapidfuzz)
  - construye Language() (ahi se detecta el ABI mismatch core/grammar)
  - parsea un snippet del lenguaje
Si falla, mueve el wheel a failed_dir. Los modulos que graphify no usa en su
config base (extras como dm/ocaml/pascal) se omiten del manifest igualmente.

Uso: test_grammars.py <wheels_dir> <failed_dir>
"""
import importlib
import os
import shutil
import sys

from tree_sitter import Language, Parser

SNIPPETS = {
    "tree_sitter_python": "def add(a, b):\n    return a + b\n",
    "tree_sitter_javascript": "const x = 1;\nfunction f() { return x; }\n",
    "tree_sitter_typescript": "interface Foo { bar: number }\nconst x: Foo = { bar: 1 };\n",
    "tree_sitter_go": "package main\nfunc main() {}\n",
    "tree_sitter_rust": "fn main() { let x = 1; }\n",
    "tree_sitter_java": "class Foo { int x = 1; }\n",
    "tree_sitter_groovy": "def x = 1\n",
    "tree_sitter_c": "int main() { return 0; }\n",
    "tree_sitter_cpp": "int main() { auto x = 1; return 0; }\n",
    "tree_sitter_ruby": "x = 1\n",
    "tree_sitter_c_sharp": "class Foo { int x = 1; }\n",
    "tree_sitter_kotlin": "fun main() { val x = 1 }\n",
    "tree_sitter_scala": "object Foo { val x = 1 }\n",
    "tree_sitter_php": "<?php $x = 1; ?>\n",
    "tree_sitter_swift": "let x = 1\n",
    "tree_sitter_lua": "local x = 1\n",
    "tree_sitter_zig": "pub fn main() void {}\n",
    "tree_sitter_powershell": "$x = 1\n",
    "tree_sitter_elixir": "x = 1\n",
    "tree_sitter_objc": "@interface Foo\n@end\n",
    "tree_sitter_julia": "x = 1\n",
    "tree_sitter_verilog": "module foo; endmodule\n",
    "tree_sitter_fortran": "program hello\nend program\n",
    "tree_sitter_bash": "#!/bin/bash\necho hi\n",
    "tree_sitter_json": '{"a": 1}',
}


def wheel_module(whl_name: str) -> str:
    """tree_sitter_python-0.25.0-cp314-...whl -> tree_sitter_python"""
    return whl_name.split("-")[0]


def test_module(modname: str) -> str:
    """Devuelve None si OK, o el mensaje de error."""
    mod = importlib.import_module(modname)
    if modname == "tree_sitter":
        return None  # el core es el que provee Language/Parser
    if modname == "rapidfuzz":
        assert mod.fuzz.ratio("abc", "abc") == 100.0
        assert mod.fuzz.ratio("abc", "abd") > 50.0
        return None
    lang = Language(mod.language())
    parser = Parser()
    parser.language = lang
    snippet = SNIPPETS.get(modname)
    if snippet is None:
        return "no hay snippet definido para este lenguaje"
    tree = parser.parse(snippet.encode())
    if tree.root_node is None:
        return "root_node es None"
    return None


def main() -> int:
    wheels_dir, failed_dir = sys.argv[1], sys.argv[2]
    n_ok = n_fail = 0
    for whl in sorted(os.listdir(wheels_dir)):
        if not whl.endswith(".whl"):
            continue
        modname = wheel_module(whl)
        try:
            err = test_module(modname)
        except Exception as e:  # noqa: BLE001 — reportamos y seguimos
            err = f"{type(e).__name__}: {e}"
        if err is None:
            n_ok += 1
            print(f"OK   {modname:22s} ({whl})")
        else:
            n_fail += 1
            print(f"FAIL {modname:22s} ({whl}) -> {err}")
            dest = os.path.join(failed_dir, whl)
            if os.path.exists(dest):
                os.remove(dest)
            shutil.move(os.path.join(wheels_dir, whl), dest)
            with open(os.path.join(failed_dir, "runtime-failed.txt"), "a") as f:
                f.write(f"{whl} -> {err}\n")
    print(f"\nResumen: {n_ok} OK, {n_fail} FAIL")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())

# AGENTS.md — termux-graphify contributor guide

> Read this file before doing anything in this repository.

## 1. Overview

`termux-graphify` builds and ships Android (`aarch64`) wheels for
[Graphify](https://github.com/Graphify-Labs/graphify) so it runs on Termux
with zero on-device compiling. Single branch (`main`). Upstream port lineage:
[Leonisaurov/graphify-termux](https://github.com/Leonisaurov/graphify-termux).

- PyPI has no Android wheels — everything here exists because of that.
- Device installs come only from this repo's releases (or explicit local
  wheels). Never point users at unofficial wheel sources.

## 2. Repository map

| Path | Role |
| --- | --- |
| `install.sh` | One-line device installer (release/tag/local wheels) |
| `scripts/install_device.sh` | Installer core: deps, venv, wheels, smoke test |
| `scripts/build_wheels.sh` | Wheel build (CI and local) |
| `scripts/resolve_versions.py` | Version resolution against graphify's ranges |
| `scripts/test_grammars.py` | Per-grammar runtime verification (import → Language → parse) |
| `scripts/grammar_manifest.txt` | Pinned grammar set |
| `.github/workflows/build-wheels.yml` | CI build in a real Termux container, native arm64 |

## 3. Build rules (do not "simplify" away)

- `tree-sitter` core stays at the pinned ABI (currently 0.26.0 / ABI 15):
  newer cores accept modern grammars that graphify's range would otherwise
  reject — this is intentional.
- Grammars build as **pure `.so`** (clang `parser.c` + `scanner.c`, master
  headers) packed into `py3-none-any` shim wheels exposing `language()` +
  `language_<symbol>()` — the exact API graphify expects, including
  `language_typescript()`/`language_tsx()`. PyPI abi3 bindings break on
  Android (missing `parser.h`, hidden visibility) — do not switch back.
- Grammar sources come from GitHub tarballs (PKG-INFO URL), not sdists:
  some sdists are incomplete (e.g. missing `common/scanner.h`).
- Every grammar must pass the runtime test (import → `Language()` for ABI
  mismatch → snippet parse). Failures go to `failed/` and never ship.

## 4. Release flow

- CI publishes the `.whl` set on `v*` tags (or manual + create_release).
- `install.sh` / `install_device.sh` resolve `releases/latest` by default,
  `--tag` pins, `--local` uses on-disk wheels with no network.
- Publish only when all grammars pass `test_grammars.py` on-device (or in
  the CI container). Never publish a partial set as latest.

## 5. Conventions

- Shell: `set -eu`, explicit command checks, actionable stderr on failure.
- Python: stdlib-first; keep scripts runnable with system python3.
- Versions resolve from graphify's supported ranges — never hand-pin a
  version outside them without recording why.
- Docs stay in English. Keep README (user surface) and this file
  (contributor surface) consistent.

## 6. Anti-patterns (do not do these)

- Do not commit built wheels or release tarballs (`*.whl`, `*.tar.gz`,
  `wheels/`, `failed/` are ignored).
- Do not commit tokens, keys, `.env` files, or device-specific absolute
  paths.
- Do not mix installation sources (PyPI graphify, F-Droid Termux, GitHub
  patch sets) in one flow — one source per install.
- Do not publish failing grammars; do not widen ABI ranges to silence the
  runtime test.

## 7. Testing

```bash
bash scripts/install_device.sh --local /path/to/wheels  # offline install test
python3 scripts/test_grammars.py                        # per-grammar runtime test
graphify --version                                      # smoke test after install
```

## 8. Troubleshooting map

| Symptom | Root cause | Fix |
| --- | --- | --- |
| `dlopen failed` on a grammar | Hidden visibility / missing header in abi3 binding | Rebuild as pure `.so` shim per section 3 |
| `Language()` ABI mismatch | Core/grammar ABI drift | Pin core per section 3; re-resolve versions |
| pip rejects wheel platform tag | Non-Android tag on Termux pip | Shims stay `py3-none-any`; content verified by runtime test |
| Install finds no release | No published tag yet | Use `--local`, or publish via CI first |

## 9. Credits and license

- Original: [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify)
  (Apache-2.0).
- Termux port lineage:
  [Leonisaurov/graphify-termux](https://github.com/Leonisaurov/graphify-termux).

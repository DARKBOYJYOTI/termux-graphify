# termux-graphify

[![Build wheels](https://github.com/DARKBOYJYOTI/termux-graphify/actions/workflows/build-wheels.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-graphify/actions/workflows/build-wheels.yml)
[![Termux: AArch64](https://img.shields.io/badge/Termux-AArch64-1f6feb?style=flat-square)](https://termux.dev)

[Graphify](https://github.com/Graphify-Labs/graphify) ported for **Termux on
Android (AArch64)** — turn any codebase into a queryable knowledge graph
(context compression for AI assistants) using local tree-sitter AST, no LLM
needed for the code part.

PyPI ships no Android wheels, so this repo builds them in CI (real Termux
container on native arm64) and installs them on-device with zero compiling.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-graphify/main/install.sh | sh
```

That installs system deps (`python`, `python-numpy`), downloads the Android
wheels from this repo's latest release, creates `~/graphify-venv`, installs
everything, and smoke-tests (`graphify --version` + grammar list). Options:

```bash
curl -fsSL .../install.sh | sh -s -- --local /path/to/wheels  # local wheels
curl -fsSL .../install.sh | sh -s -- --tag <release-tag>      # pinned release
```

Then point your agent at it — e.g. for OpenCode, `graphify query "..."`,
`graphify path "A" "B"`, `graphify explain "..."`. Full agent guide:
[AGENTS.md](./AGENTS.md).

## How it works

- `tree-sitter` core + `rapidfuzz` are compiled normally (`pip wheel`).
- Each grammar is compiled as a **pure `.so`** with clang and packed into a
  **wheel shim** exposing exactly the API graphify expects (verified by a
  runtime test per grammar — failures never reach a release).
- The device script installs wheels `--no-deps` into a venv with
  `--system-site-packages` (native numpy/networkx from Termux packages).

Details: [graphyfy-port.md](./graphyfy-port.md), [AGENTS.md](./AGENTS.md).

## Build wheels (CI)

`.github/workflows/build-wheels.yml` builds inside a real Termux container
on native arm64 and publishes the `.whl` set on `v*` tags (or manual runs).
Versions resolve against graphify's supported ranges
(`scripts/resolve_versions.py`).

## Repository layout

```text
install.sh                 # one-line device installer (release wheels, no compiling)
scripts/install_device.sh  # device installer core (release, tag, or local wheels)
scripts/build_wheels.sh    # CI/local wheel build
scripts/resolve_versions.py# version resolution against graphify's ranges
scripts/test_grammars.py   # per-grammar runtime verification
scripts/grammar_manifest.txt
graphify-pyproject.toml    # graphify build metadata
```

## Contributing

Single branch `main`. Test grammar changes with `scripts/test_grammars.py`
before pushing. Never commit built wheels (`*.whl` are ignored) or
credentials — see [SECURITY.md](./SECURITY.md).

## Credits

- [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify) — the original project.
- [Leonisaurov/graphify-termux](https://github.com/Leonisaurov/graphify-termux) — the Termux port this builds on.

## Security

See [SECURITY.md](./SECURITY.md).

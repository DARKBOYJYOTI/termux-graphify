# termux-graphify

[![Build wheels](https://github.com/DARKBOYJYOTI/termux-graphify/actions/workflows/build-wheels.yml/badge.svg?branch=main)](https://github.com/DARKBOYJYOTI/termux-graphify/actions/workflows/build-wheels.yml)
[![Termux: AArch64](https://img.shields.io/badge/Termux-AArch64-1f6feb?style=flat-square)](https://termux.dev)
[![Python 3.14](https://img.shields.io/badge/Python-3.14-3fb950?style=flat-square)](https://www.python.org)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-9e6a03?style=flat-square)](https://github.com/Graphify-Labs/graphify/blob/main/LICENSE)

Turn any codebase on your Android phone into a **queryable knowledge graph**
— god nodes, communities, call flows, cross-file relationships. Built for
[Graphify](https://github.com/Graphify-Labs/graphify) on **Termux (AArch64)**
with zero on-device compiling: prebuilt wheels, one-line install, ready for
Claude Code, OpenCode, Codex, Gemini CLI, and every AI coding assistant.

> PyPI ships no Android wheels — that gap is exactly what this repository
> closes. Local tree-sitter AST, no LLM needed for the code part.

## Install in one line

```bash
curl -fsSL https://raw.githubusercontent.com/DARKBOYJYOTI/termux-graphify/main/install.sh | sh
```

What happens: system deps (`python`, `python-numpy`) → latest release
wheels → isolated `~/graphify-venv` → smoke test (`graphify --version` +
grammar list). Options:

```bash
curl -fsSL .../install.sh | sh -s -- --local /path/to/wheels  # offline wheels
curl -fsSL .../install.sh | sh -s -- --tag <release-tag>      # pinned release
```

Then ask your codebase anything:

```bash
graphify query "what connects auth to the database?"
graphify path "login" "payment"
graphify explain "session manager"
```

## Why this exists

- **No compiler on your phone.** 25+ grammars and the core are compiled in
  CI inside a real Termux container on native arm64 — the device only
  installs.
- **It actually loads.** PyPI's abi3 grammar bindings break on Android
  (hidden symbols, missing headers). Ours are pure `.so` builds verified by
  a runtime test each — failures never ship.
- **Local-first.** Code parsing is 100% on-device tree-sitter. Semantic
  extraction can additionally route through free local CLIs (Hermes,
  OpenCode, Codex) with no API key via the Termux port patch.

## What's inside a release

- `tree-sitter` core + `rapidfuzz` (compiled normally)
- 25 grammar shims exposing exactly the API graphify expects
- `graphifyy+termux1` wheel (upstream + local-CLI backends patch)
- Every wheel runtime-tested (import → `Language()` ABI check → snippet parse)

## Repository layout

```text
install.sh                 # one-line device installer (release/tag/local)
scripts/install_device.sh  # installer core: deps, venv, wheels, smoke test
scripts/build_wheels.sh    # wheel build (CI and local reproduction)
scripts/resolve_versions.py# version resolution against graphify's ranges
scripts/test_grammars.py   # per-grammar runtime verification
scripts/grammar_manifest.txt
graphify-pyproject.toml    # upstream build metadata reference
```

## Build wheels yourself

`.github/workflows/build-wheels.yml` builds everything in CI (native arm64,
up to 4 h). Locally, the same script runs inside the Termux container —
see [AGENTS.md](./AGENTS.md).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `dlopen failed` on a grammar | Rebuild that grammar as pure `.so` — see [AGENTS.md](./AGENTS.md) |
| `Language()` ABI mismatch | Core/grammar drift — re-resolve versions, never widen ranges blindly |
| pip rejects a wheel tag | Shims must stay `py3-none-any`; content is proven by the runtime test |
| No release found | Publish via CI first, or install with `--local` wheels |

## Contributing

Single branch `main`. Test grammar changes with `scripts/test_grammars.py`
before pushing. Never commit built wheels, credentials, or device paths —
see [SECURITY.md](./SECURITY.md).

## Credits

- [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify) — the original project (Apache-2.0).
- [Leonisaurov/graphify-termux](https://github.com/Leonisaurov/graphify-termux) — the Termux port this builds on.

## Security

See [SECURITY.md](./SECURITY.md).

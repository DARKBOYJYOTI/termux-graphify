# AGENTS.md — termux-graphify contributor guide

> Read this file before doing anything in this repository. It is the single
> source of truth for how wheels are built, tested, released, and installed.

## 1. Overview

`termux-graphify` builds and ships Android (`aarch64`) wheels for
[Graphify](https://github.com/Graphify-Labs/graphify) so it runs on Termux
with zero on-device compiling. Single branch (`main`). Upstream port lineage:
[Leonisaurov/graphify-termux](https://github.com/Leonisaurov/graphify-termux).

- PyPI has no Android wheels — everything here exists because of that.
- The `graphifyy+termuxN` wheel is upstream plus the local-CLI backends patch
  (`scripts/patches-termux-cli-backends.patch`: hermes/opencode/codex
  headless extraction with no API key). The patch is version-specific — every
  upstream bump must re-verify it applies (see section 4).
- Device installs come only from this repo's releases (or explicit local
  wheels). Never point users at unofficial wheel sources.

## 2. Repository map

| Path | Role |
| --- | --- |
| `install.sh` | One-line device installer (release/tag/local wheels) |
| `scripts/install_device.sh` | Installer core: deps, venv (`--system-site-packages`), wheels, smoke test |
| `scripts/build_wheels.sh` | Wheel build, steps 1–7 (CI and local reproduction) |
| `scripts/resolve_versions.py` | Exact grammar versions inside graphify's supported ranges (PyPI JSON API) |
| `scripts/test_grammars.py` | Per-grammar runtime verification (import → Language → parse); failures → `failed/` |
| `scripts/grammar_manifest.txt` | Pinned grammar set (`package==version` lines) |
| `scripts/patches-termux-cli-backends.*` | Local-CLI backends patch + build notes for the `+termuxN` wheel |
| `graphify-pyproject.toml` | Upstream build metadata reference (ranges source of truth) |
| `.github/workflows/build-wheels.yml` | CI build in a real Termux container, native arm64, up to 4 h |

## 3. Build rules (do not "simplify" away)

- `tree-sitter` core stays at the pinned ABI (currently 0.26.0 / ABI 15):
  newer cores accept modern grammars that graphify's nominal range would
  otherwise reject — this is intentional. Never "fix" the range warning by
  downgrading core.
- Grammars build as **pure `.so`** (clang `parser.c` + `scanner.c`, master
  headers from the tree-sitter repo) packed into `py3-none-any` shim wheels
  exposing `language()` + `language_<symbol>()` — the exact API graphify
  expects, including `language_typescript()`/`language_tsx()`. PyPI abi3
  bindings break on Android (missing `parser.h` in sdists, hidden
  visibility swallowing the scanner symbol → `dlopen failed`) — do not
  switch back.
- Grammar sources come from GitHub tarballs (PKG-INFO URL), not sdists:
  some sdists are incomplete (e.g. typescript missing `common/scanner.h`).
- The `+termuxN` wheel: download the exact sdist, apply the patch (must
  apply with zero rejects), stamp `version = "<ver>+termuxN"`, `pip wheel
  --no-deps --no-build-isolation`. Verify import + backend registration +
  `detect_backend()` before shipping.
- Every grammar must pass the runtime test. Failures go to `failed/` and
  never ship. Never widen ABI ranges or skip tests to silence a failure.

## 4. Upstream version bumps (porting checklist)

1. Fetch the new `requires_dist` (PyPI JSON) and diff the grammar ranges
   against `scripts/resolve_versions.py` `DEPS` — update pins that moved.
2. Download the new sdist; dry-run the CLI-backends patch. Any `FAILED`
   hunk: read the `.rej`, find the drifted function in the new source, and
   hand-adapt the hunk preserving behavior (tuple returns, priority order:
   paid/API first, CLI fallback last, `None` sentinel last). Regenerate a
   clean patch via `diff -u` against pristine source.
3. Build the `+termuxN` wheel locally; smoke-test: import, backend list,
   `detect_backend()`, `--version` (in an isolated dir — never the live
   venv; the CLI auto-refreshes the opencode plugin file on run).
4. Bump `GRAPHIFY_VERSION` defaults (`install.sh`, `install_device.sh`) and
   the doc comments; update this file's pinned versions below.
5. Dispatch CI, download the wheel set, test-install into a **fresh test
   venv** on-device (grammar test + real `extract` on a sample repo), then
   publish the release.

Currently pinned: graphifyy **0.9.92** (+termux1), tree-sitter core **0.26.0**,
rapidfuzz **3.14.5**, 25 grammars per `scripts/grammar_manifest.txt`.

## 5. Release flow

- CI (`build-wheels.yml`, manual dispatch or `v*` tag) builds in the Termux
  container and uploads `termux-wheels` (+ `termux-wheels-failed` always).
  With `create_release` (or a `v*` tag) it publishes the `.whl` set.
- `install.sh` / `install_device.sh` resolve `releases/latest` by default,
  `--tag` pins, `--local` uses on-disk wheels with no network.
- Publish only when section 7 passes fully. Never publish a partial set as
  latest; never push a second tag for one wheel set.

## 6. Conventions

- Shell: `set -eu`, explicit command checks, actionable stderr on failure.
  Spanish comments in inherited scripts are acceptable; new code in English.
- Python: stdlib-first; keep scripts runnable with system python3.
- Docs stay in English. Keep README (user surface) and this file
  (contributor surface) consistent when behavior changes.

## 7. Testing

```bash
bash scripts/install_device.sh --local /path/to/wheels  # offline install test
python3 scripts/test_grammars.py                        # per-grammar runtime test
graphify --version                                      # smoke test after install
```

On-device acceptance for every release (isolated test venv — never the live
`~/graphify-venv`):

1. Fresh venv + release wheels install cleanly (`--no-deps` chain resolves).
2. `test_grammars.py` passes for every shipped grammar.
3. A real `graphify extract` on a sample repo completes and `query` answers.
4. The `+termuxN` wheel reports its version and registers the CLI backends.

## 8. Troubleshooting map

| Symptom | Root cause | Fix |
| --- | --- | --- |
| `dlopen failed` on a grammar | Hidden visibility / missing header in abi3 binding | Rebuild as pure `.so` shim per section 3 |
| `Language()` ABI mismatch | Core/grammar ABI drift | Pin core per section 3; re-resolve versions |
| pip rejects wheel platform tag | Non-Android tag on Termux pip | Shims stay `py3-none-any`; content verified by runtime test |
| Install finds no release | No published tag yet | Use `--local`, or publish via CI first |
| Skill bootstrap tries building grammars from source | Upstream skill prefers `uv tool run`, and uv cannot build Android grammar sdists; triggers only when uv exists but `graphify` is not on PATH | Keep `~/.local/bin` on PATH (standard install does); the working venv is `~/graphify-venv` — verify with `<venv>/bin/python -c "import graphify"` |
| Patch hunk FAILED on bump | Upstream refactored the patched function | Hand-adapt per section 4; never force-apply |
| sdist missing headers | Incomplete sdist (e.g. no `common/scanner.h`) | Build from the GitHub tarball per section 3 |

## 9. Anti-patterns (do not do these)

- Do not commit built wheels or release tarballs (`*.whl`, `*.tar.gz`,
  `wheels/`, `failed/` are ignored).
- Do not commit tokens, keys, `.env` files, or device-specific absolute
  paths.
- Do not mix installation sources in one flow — one source per install.
- Do not publish failing grammars; do not widen ABI ranges to silence the
  runtime test.
- Do not test releases in the live venv — always an isolated test venv;
  the CLI rewrites the opencode plugin file on run.

## 10. Credits and license

- Original: [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify)
  (Apache-2.0).
- Termux port lineage:
  [Leonisaurov/graphify-termux](https://github.com/Leonisaurov/graphify-termux).

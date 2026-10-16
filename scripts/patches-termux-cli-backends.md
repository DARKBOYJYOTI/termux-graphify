# Parche termux: backends CLI (hermes/opencode/codex) para graphifyy 0.9.44

Añade 3 backends de extracción semántica que enrutan por el CLI local en modo
headless (patrón `claude-cli`), sin API key:

| Backend  | Comando CLI                      | Modelo gratis por defecto              |
|----------|----------------------------------|----------------------------------------|
| `hermes` | `hermes -z "<prompt>"`           | el configurado de Hermes (opencode-go/deepseek-v4-flash) |
| `opencode`| `opencode run --pure --format json --model <m> "<prompt>"` | `opencode-go/deepseek-v4-flash` |
| `codex`  | `codex exec --sandbox danger-full-access "<prompt>"` | default de codex (gpt-5.6-luna; codex-mini da 400 con cuenta ChatGPT) |

## Cómo se construye el wheel parcheado

```bash
pip download --no-deps --no-binary :all: "graphifyy==0.9.44" -d sdists/
tar xzf sdists/graphifyy-0.9.44.tar.gz
cd graphifyy-0.9.44
patch -p1 < ../patches-termux-cli-backends.patch   # o apply manualmente
sed -i 's/^version = "0.9.44"/version = "0.9.44+termux1"/' pyproject.toml
python -m pip wheel --no-deps --no-build-isolation -w dist/ .
# -> graphifyy-0.9.44+termux1-py3-none-any.whl  (publicar en el release)
```

El `install.sh` detecta `graphifyy-*.whl` en el release y lo instala con
`--no-index` (sin tocar PyPI); si no está, cae a `pip install graphifyy==0.9.44`.

## Archivos tocados

- `graphify/llm.py` — 3 backends en BACKENDS + `_call_hermes_cli`,
  `_call_opencode_cli`, `_call_codex_cli` + dispatch en `extract_files_direct`
  y `_call_llm` + `detect_backend` + `_format_backend_env_keys`
- `graphify/cli.py` — branches de validación `shutil.which` para los 3 CLIs
- `graphify/__main__.py` — help de `--backend`
- `README.md` — ejemplos de uso

## Notas

- Los 3 se ejecutan en SERIE (como claude-cli): `GRAPHIFY_CLI_PARALLEL=1` para
  paralelizar.
- `codex` requiere git repo; si el CWD no lo es, se usa un repo temporal
  desechable (el prompt lleva el contenido inline).
- Vision: no soportada por estos backends CLI (las imágenes degradan a nodos
  de texto de referencia) — igual que el resto del port, que es code-only.

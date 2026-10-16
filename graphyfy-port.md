# Adaptación de Graphify para Hermes en Termux

Investigación y restricciones para llevar la funcionalidad de Graphify (compresión de contexto via knowledge graph) a Hermes en un entorno Termux aarch64 con recursos limitados.

---

## 1. ¿Qué es Graphify y qué resuelve?

Graphify es un skill open-source (MIT/Apache-2.0, 107k stars) que:

- Indexa codebases con Tree-sitter (AST determinista, 19 lenguajes) + docs + PDFs + SQL schemas
- Construye un grafo de conocimiento (NetworkX + Leiden clustering)
- Permite consultas BFS desde un nodo seed para cargar solo el subgrafo relevante
- Bench: ~71× ahorro de tokens en corpus de ~92k palabras (~2k tokens vs ~123k naive)
- Para repos grandes (500+ archivos), el costo de build inicial se amortiza porque las queries después son baratas

**Valor principal:** no es la visualización, es la compresión de tokens de orientación. El modelo no relee todo el repo — consulta el grafo y carga solo lo necesario.

---

## 2. Dependencias de Graphify (graphifyy en PyPI)

### Layer 1 — Paquete base (probablemente OK en Termux)

| Dependencia | Tipo | Estado en Termux aarch64 |
|---|---|---|
| Python 3.10+ | runtime | Termux tiene 3.14.6 — OK |
| NetworkX | pure Python | OK (wheels disponibles) |
| numpy | numeric | OK (wheels para aarch64) |
| rapidfuzz | string matching | OK (wheels) |
| pyyaml, click, rich, etc. | CLI/utils | OK (pure Python o wheels) |

### Layer 2 — Tree-sitter language grammars (RIESGO ALTO)

Graphify instala ~19 grammars para parsear distintos lenguajes. El problema documentado en Termux:

- pip no encuentra wheels precompilados para `android_24_arm64_v8a`
- Caída a compilación desde source → falla por falta de headers de desarrollo

**Issue de referencia:** [`docling-project/docling-parse#241`](https://github.com/docling-project/docling-parse/issues/241) — compilación de `tree-sitter-typescript` en Termux aarch64 falla con:
```
tsx/src/parser.c:2929:14: error: unknown type name 'TSFieldMapSlice'
```
Termux tiene runtime tree-sitter pero **no el paquete -dev** que pip necesita para compilar bindings.

**Grammars sin wheel para aarch64 Android (compilación desde source, riesgo de fallo):**
- tree-sitter-typescript, tree-sitter-rust, tree-sitter-cpp, tree-sitter-java, tree-sitter-kotlin, tree-sitter-elixir, tree-sitter-go, tree-sitter-lua, tree-sitter-c-sharp, tree-sitter-groovy, tree-sitter-fortran, tree-sitter-dm, tree-sitter-bash, tree-sitter-json (algunos pueden tener wheel, verificar por versión)

**Grammars con wheel disponible para aarch64 (según PiWheels / PyPI):**
- tree-sitter (core)
- tree-sitter-python
- tree-sitter-javascript
- tree-sitter-c
- tree-sitter-go (verificar)
- tree-sitter-kotlin (verificar)
- tree-sitter-elixir (verificar)
- tree-sitter-lua (verificar)
- tree-sitter-c-sharp (verificar)

**estrategia de mitigación:** instalar solo las grammars que tienen wheel para aarch64 y saltar las que no. Si solo trabajas en Python/JS/JSON, no necesitas las otras.

### Layer 3 — Extracción semántica (requiere API key de LLM)

Graphify envía descripciones semánticas de documentos/diagramas a un modelo de LLM para enrichment de los nodos del grafo. Esto significa:
- Requiere una API key configurada del modelo que el usuario ya tiene
- No envía código crudo, solo descripciones semánticas
- En Termux sin API keys, esta capa está deshabilitada → se usa solo la parte AST estructural (determinista, sin modelo externo)

---

## 3. Costo computacional en Termux

| Fase | Costo | Comentario Termux |
|---|---|---|
| `graphify build ./repo` (primer build) | CPU intensivo, minutos en servidor | En dispositivo móvil aarch64 a 1-2 GHz: 5-10× más lento. Repo mediano (100-300 archivos): varios minutos. |
| Build incremental (cache) | Menos que build inicial | Aún así consume CPU significativo |
| `graphify query` (BFS subgraph) | Barato | Óptimo — el valor está aquí |
| `graphify serve` (UI web) | Moderado | Node.js + Vite — posible pero consume RAM |
| Extracción semántica (LLM calls) | Varía | Depende de la API key y modelo |

**Conclusión:** el cuello de botella es solo el build inicial. Si el repo se trabaja por días/semanas, el tiempo de build se amortiza. Para uso puntual en repo pequeño, no vale la pena.

---

## 4. Lo que tendríamos que adaptar/modificar para Termux

### A. Selección de grammars

- Instalar solo `graphifyy` + grammars con wheel para aarch64 (tree-sitter-python, tree-sitter-javascript, etc.)
- Omitir grammars que no tienen wheel → Graphify funcionará solo para los lenguajes soportados, pero la parte AST para esos lenguajes sí funciona

### B. Modo offline / sin LLM

- Usar solo la parte AST (deterministic) sin extracción semántica → el grafo es estructural puro (imports, llamadas, dependencias) sin descripciones semánticas de los nodos
- El query por BFS todavía funciona — solo pierdes el enrichment semántico

### C. Paralelización / workers

- `graphify` tiene `GRAPHIFY_MAX_WORKERS` — en Termux con pocos cores, limitar a 1-2 workers para no saturar la CPU

### D. Graphify como CLI externo vs integración nativa

- Opción 1: `pip install graphifyy` + `graphify build` + `graphify query` como comandos terminal() desde Hermes — funciona si las deps instalan
- Opción 2: envolver en un skill de Hermes que instruya al modelo para ejecutar el CLI y consumir el output

---

## 5. ¿Hermes tiene algo similar a Graphify hoy?

### Lo que existe

#### a) Memory Providers (8 proveedores externos)

- Honcho, OpenViking, Mem0, Hindsight, Holographic, RetainDB, ByteRover, Supermemory
- Para **memoria cross-session del agente** (conversaciones pasadas), NO para indexing de código
- Built-in: FTS5 SQLite para búsqueda full-text de sesiones

#### b) session_search (FTS5 SQLite)

- Busca en conversaciones pasadas con keyword matching
- No indexa código, no es RAG de codebase

#### c) GitNexus Explorer (skill opcional oficial)

- `hermes skills install official/research/gitnexus-explorer`
- Indexa código con GitNexus → UI web interactiva para explorar grafo de símbolos
- **No hace compresión de contexto** — es exploración visual para humanos
- Requiere Node.js + git + cloudflared
- Límite: repos con 5k+ archivos son lentos en UI; 30k+ probablemente crash

### Lo que está en discusión pero no implementado

#### Knowledgebase RAG System — Issue #844 (RFC, P3 Low, abierto)

Propone:
- `knowledgebase:` en `config.yaml` con directorios, auto_retrieve, embedding_model (local/ollama/openai)
- Embedding local con `fastembed` + `all-MiniLM-L6-v2` (22M params, 384 dims, CPU-friendly)
- Vector store: `sqlite-vec` + FTS5 (todo en un .sqlite, sin servidor externo)
- Chunking AST para código con Tree-sitter (¡mismo problema de compilación en Termux!)
- Chunking recursivo para docs: 400-512 tokens, 10-20% overlap
- Híbrido dense+sparse: cosine similarity + BM25
- Budget: 8-16k tokens de retrieval, 5-10 chunks relevantes
- Nuevos archivos planeados: `tools/knowledgebase_tool.py`, `agent/knowledgebase.py`, `agent/chunker.py`
- Index storage: `~/.hermes/knowledgebase/indexes/{dir-hash}.sqlite`

**Estado:** no implementado, solo issue + diseño. Depende de Tree-sitter para chunking de código (mismo problema de Termux).

---

## 6. Comparación resumida

| Sistema | ¿Existe? | ¿Indexa código? | ¿Compresión de tokens en-session? | ¿Depende de Tree-sitter? | ¿Termux-viable? |
|---|---|---|---|---|---|
| **Graphify** (externo) | Sí | Sí (AST) | Sí (~71×) | Sí (19 grammars) | Con reservas — grammars sin wheel fallan |
| **GitNexus Explorer** (Hermes skill) | Sí | Sí (GitNexus) | No | No (usa GitNexus CLI) | Sí (Node.js + git + cloudflared) |
| **Memory Providers** (Hermes) | Sí | No (conversaciones) | No | No | Sí |
| **session_search / FTS5** (Hermes) | Sí | No (mensajes) | No | No | Sí |
| **Knowledgebase RAG #844** (RFC) | No (solo issue) | Planeado | Planeado | Sí (para chunking código) | Igual que Graphify — same Tree-sitter issue |
| **Skill nativo Hermes (sin deps)** | Posible | Manual (grep/find/read) | Parcial (modelo decide qué leer) | No | Sí — usa solo herramientas existentes |

---

## 7. Recomendaciones para Termux con recursos limitados

### Si queremos probar Graphify como external CLI:

1. Instalar solo las grammars con wheel para aarch64
2. Usar solo AST (sin LLM enrichment) → modear `graphify build` sin extracción semántica
3. Aceptar que el build inicial es lento en dispositivo móvil — solo vale para repos que se trabajen por semanas
4. Consumir el grafo desde Hermes con `terminal("graphify query '...'")`

### Si queremos una solución nativa sin dependencias problemáticas:

Crear un skill de Hermes que aproxime la funcionalidad de Graphify usando solo las herramientas ya disponibles:
- `terminal()` para grep/find/ripgrep/ls para mapeo rápido del repo
- `read_file()` para leer solo archivos relevantes
- `search_files()` para búsqueda de símbolos
- Instrucciones en SKILL.md para que el modelo haga BFS manual: identificar puntos de entrada, seguir imports/referencias, leer solo lo necesario
- No da la compresión de 71×, pero evita todas las dependencias problemáticas

### Lo que SÍ es viable hoy sin adaptaciones:

- GitNexus Explorer para exploración visual interactiva (si se instala Node.js)
- Un skill que instruya al modelo para no leer todo el repo de golpe — ya es mejor que hacerlo sin guía

---

## 8.Referencias

- Graphify: https://graphify.net/ | https://github.com/Graphify-Labs/graphify
- Graphify CLI docs: https://graphify.net/graphify-cli-commands.html
- Graphify Claude Code integration: https://graphify.net/graphify-claude-code-integration.html
- Tree-sitter Termux issue: https://github.com/docling-project/docling-parse/issues/241
- Hermes Memory Providers: https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers
- Hermes Knowledgebase RAG RFC: https://github.com/NousResearch/hermes-agent/issues/844
- Hermes session_search + memory provider integration: https://github.com/NousResearch/hermes-agent/issues/29902
- GitNexus Explorer skill: https://hermes-agent.nousresearch.com/docs/user-guide/skills/optional/research/research-gitnexus-explorer
- PiWheels graphifyy deps: https://www.piwheels.org/project/graphifyy/

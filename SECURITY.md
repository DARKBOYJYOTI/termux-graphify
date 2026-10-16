# Security policy

## Reporting a vulnerability

- **Do not open a public issue** for anything that could be a live
  vulnerability (malicious wheels, supply-chain tampering, credential leaks).
- Use GitHub's **private vulnerability reporting**
  (`Security → Report a vulnerability`) so the report stays confidential
  until a fix is released.
- Include: affected tag/version, device and Android details, exact
  reproduction steps. Redact tokens and personal paths before sending.

## Secret-handling rules for contributors

1. **Never commit** tokens (`gho_*`, `ghp_*`, `github_pat_*`), API keys,
   private keys, or `.env` files.
2. Built artifacts stay out of git: `wheels/`, `*.whl`, `*.tar.gz`,
   `test-local/`, `verify/`, `__pycache__/` (all ignored). If you add a new
   generated path, add it to `.gitignore` in the same change.
3. Never paste tokens into commands, scripts, logs, or issues — use
   environment variables or `gh` auth.
4. CI workflows run with minimal `permissions`; do not add scheduled
   triggers that publish without human review.

## Supported versions

Only wheels from this repository's latest release are supported. Rebuilds
of older pins are done on request, not patched independently.

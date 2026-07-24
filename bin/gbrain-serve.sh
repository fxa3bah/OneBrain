#!/bin/bash
# OneBrain — gbrain HTTP MCP serve wrapper
# Loopback-only (127.0.0.1:3131), 100% offline embeddings (Ollama), single source of truth for the token.
set -euo pipefail

export PATH="/Users/faadi/.bun/bin:/opt/homebrew/bin:/Users/faadi/.nvm/versions/node/v24.13.0/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Load ONLY the gbrain admin token from the secrets master — NOT the whole .env,
# so OPENAI_API_KEY and friends never enter this process (keeps embeddings offline).
export GBRAIN_ADMIN_BOOTSTRAP_TOKEN="$(grep '^GBRAIN_ADMIN_BOOTSTRAP_TOKEN=' "$HOME/.secrets/.env" | cut -d= -f2- | tr -d '\n')"

# Belt-and-suspenders: guarantee no OpenAI fallback for embeddings/expansion.
unset OPENAI_API_KEY || true

cd /Users/faadi/Code/gbrain
exec bun run /Users/faadi/Code/gbrain/src/cli.ts serve --http --port 3131 --suppress-bootstrap-token

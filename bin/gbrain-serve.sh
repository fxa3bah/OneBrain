#!/bin/bash
# OneBrain — gbrain HTTP MCP serve wrapper.
# Loopback-only (127.0.0.1:$GBRAIN_PORT), 100% offline embeddings (Ollama),
# single source of truth for the admin token.
set -euo pipefail
source "$(dirname "$0")/onebrain-common.sh"

# Load ONLY the gbrain admin token from the secrets master — NOT the whole .env,
# so OPENAI_API_KEY and friends never enter this process (keeps embeddings offline).
export GBRAIN_ADMIN_BOOTSTRAP_TOKEN="$(read_secret GBRAIN_ADMIN_BOOTSTRAP_TOKEN)"

# Belt-and-suspenders: guarantee no OpenAI fallback for embeddings/expansion.
unset OPENAI_API_KEY || true

cd "$GBRAIN_REPO"
exec bun run "$GBRAIN_CLI" serve --http --port "$GBRAIN_PORT" --suppress-bootstrap-token

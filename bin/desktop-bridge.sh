#!/bin/bash
# OneBrain — Claude Desktop / Cowork bridge.
# Proxies a stdio MCP client (Claude Desktop) to the EXISTING gbrain HTTP server.
# No second gbrain process -> no PGLite single-writer contention. Token from the secrets master.
source "$(dirname "$0")/onebrain-common.sh"
export GBRAIN_DESKTOP_TOKEN="$(read_secret GBRAIN_DESKTOP_TOKEN)"
exec npx -y mcp-remote "http://127.0.0.1:${GBRAIN_PORT}/mcp" --header "Authorization: Bearer ${GBRAIN_DESKTOP_TOKEN}"

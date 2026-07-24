#!/bin/bash
# OneBrain — Claude Desktop/Cowork bridge.
# Proxies Claude Desktop (stdio) to the EXISTING gbrain HTTP server on 127.0.0.1:3131.
# No second gbrain process, so no PGLite single-writer contention. Token loaded from the secrets master.
export PATH="/Users/faadi/.bun/bin:/opt/homebrew/bin:/Users/faadi/.nvm/versions/node/v24.13.0/bin:/usr/bin:/bin"
export GBRAIN_DESKTOP_TOKEN="$(grep '^GBRAIN_DESKTOP_TOKEN=' "$HOME/.secrets/.env" | cut -d= -f2- | tr -d '\n')"

# Wait for the gbrain HTTP server (:3131) to be ready before handing off to mcp-remote.
# mcp-remote fails fast on ECONNREFUSED with no retry, so if Claude Desktop launches before
# the ai.gbrain.server LaunchAgent is up (boot/wake race), the connector dies permanently.
# Poll /health up to ~60s; this just pauses Desktop's connector instead of killing it.
for i in $(seq 1 60); do
  if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:3131/health" 2>/dev/null; then
    break
  fi
  sleep 1
done

exec npx -y mcp-remote "http://127.0.0.1:3131/mcp" --header "Authorization: Bearer ${GBRAIN_DESKTOP_TOKEN}"

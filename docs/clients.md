# Wiring your AI clients to OneBrain

OneBrain exposes **one** HTTP MCP endpoint: `http://127.0.0.1:3131/mcp`, bearer-token
authenticated with `GBRAIN_REMOTE_TOKEN`. Every client points at the same endpoint, so
they all share one memory. Add as many clients as you like.

> Replace `$GBRAIN_REMOTE_TOKEN` with the value from your `~/.secrets/.env`, or export it
> in your shell first: `export GBRAIN_REMOTE_TOKEN="$(grep '^GBRAIN_REMOTE_TOKEN=' ~/.secrets/.env | cut -d= -f2-)"`

## Claude Code (CLI)

```bash
claude mcp add -s user -t http gbrain http://127.0.0.1:3131/mcp \
  -H "Authorization: Bearer $GBRAIN_REMOTE_TOKEN"
```

## Codex CLI

```bash
codex mcp add gbrain --url http://127.0.0.1:3131/mcp \
  --bearer-token-env-var GBRAIN_REMOTE_TOKEN
```

GUI-launched Codex may not inherit your shell env. The `ai.gbrain.env` LaunchAgent
fixes this by registering the token into the GUI launchd session at login
(`launchctl setenv GBRAIN_REMOTE_TOKEN ...`). It's installed by default.

## Grok CLI

```bash
grok mcp add gbrain -t http http://127.0.0.1:3131/mcp \
  -H "Authorization: Bearer $GBRAIN_REMOTE_TOKEN"
```

## Any MCP gateway / bot (config file)

```yaml
mcp_servers:
  gbrain:
    url: http://127.0.0.1:3131/mcp
    headers:
      Authorization: "Bearer ${GBRAIN_REMOTE_TOKEN}"
```

## Claude Desktop / Cowork (stdio bridge)

Claude Desktop speaks stdio, not HTTP, so it goes through a tiny `mcp-remote` proxy
(`bin/desktop-bridge.sh`) to the **existing** server — no second gbrain process, no
PGLite write contention. In Desktop's MCP config:

```json
{
  "mcpServers": {
    "gbrain": {
      "command": "/bin/bash",
      "args": ["__HOME__/.gbrain/bin/desktop-bridge.sh"]
    }
  }
}
```

## Verify

```bash
curl -s -H "Authorization: Bearer $GBRAIN_REMOTE_TOKEN" http://127.0.0.1:3131/health
```

Then ask any wired agent to `search` or `recall` something you know is in your vault.
Edit that fact once in Obsidian and every agent sees the change after the next 5-minute sync.

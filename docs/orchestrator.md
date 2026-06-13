# Orchestration: putting an agent in charge

OneBrain's brain is **passive** — it answers queries, stores facts, and serves the same
memory to every client. That's deliberate: you can put *any* agent in the **orchestrator**
role on top of it without changing the brain at all.

An orchestrator is just a client given three extra things:

1. **A coordinating role** — a system prompt that says "you plan and dispatch work."
2. **A schedule** — cron / launchd / a chat trigger, so it acts without you typing.
3. **The ability to invoke worker agents** (Claude Code, Codex, Grok) and/or spawn subagents.

How it reaches the brain is identical to any other client: `http://127.0.0.1:3131/mcp`
plus the bearer token.

```
                 ┌─────────────────────────────────────────────┐
                 │               ORCHESTRATOR                   │
                 │   OpenClaw   ·or·   Hermes (Nous Research)   │
                 │   gateway + cron + multi-agent routing       │
                 └───────────────┬─────────────┬───────────────┘
            reads context /       │             │   dispatches tasks /
            writes results        ▼             ▼   spawns subagents
                          ┌──────────────┐   Claude Code · Codex · Grok
                          │   OneBrain   │   (worker agents, also brain clients)
                          │  (gbrain MCP)│
                          └──────────────┘
                 results get written back to the vault →
                 brain re-indexes on the next 5-min sync
```

Both supported orchestrators are real, MCP-native runtimes with built-in scheduling and
sub-agent fan-out — exactly the two properties an orchestrator needs.

---

## Option A — OpenClaw

[OpenClaw](https://docs.openclaw.ai/) is a gateway + agent runtime with multi-agent routing
(isolated sessions per agent) and multi-channel messaging. MCP config hot-applies (no restart).

Add OneBrain as a remote HTTP MCP server in your OpenClaw config:

```json5
{
  mcp: {
    servers: {
      gbrain: {
        url: "http://127.0.0.1:3131/mcp",
        transport: "streamable-http",   // OpenClaw normalizes type:"http" to this
        timeout: 20,
        connectTimeout: 5,
        headers: {
          Authorization: "Bearer ${GBRAIN_REMOTE_TOKEN}",  // env substitution supported
        },
      },
    },
  },
}
```

Export the token in OpenClaw's environment (`GBRAIN_REMOTE_TOKEN`, from `~/.secrets/.env`),
give the orchestrator agent its coordinating prompt, and register your worker agents as the
agents/tools it may route to. OpenClaw then reads context from the brain, plans, dispatches,
and writes outcomes back to the vault.

> Docs: <https://docs.openclaw.ai/gateway/configuration-reference> (MCP server fields),
> <https://docs.openclaw.ai/concepts/multi-agent> (routing).

---

## Option B — Hermes (Nous Research)

[Hermes](https://hermes-agent.nousresearch.com/docs/) is an autonomous, self-improving agent
that connects to any MCP server, has **built-in cron with delivery to any platform**, and can
**spawn isolated subagents for parallel workstreams** — a natural always-on orchestrator.

Add OneBrain under `mcp_servers` in Hermes's config:

```yaml
mcp_servers:
  gbrain:
    url: "http://127.0.0.1:3131/mcp"
    headers:
      Authorization: "Bearer ${GBRAIN_REMOTE_TOKEN}"
    # optional: narrow what the agent sees
    tools:
      resources: false
      prompts: false
```

Reload without restarting:

```
/reload-mcp
```

Then drive it with Hermes's built-in cron, e.g.:

```yaml
cron:
  - name: "Morning brief"
    schedule: "0 7 * * *"
    prompt: "Query the brain for today's open items, draft the brief, save it to the vault."
```

> Docs: <https://hermes-agent.nousresearch.com/docs/guides/use-mcp-with-hermes> (MCP),
> <https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp>.

---

## The golden rule of orchestration here

**Workers write durable results back into the Obsidian vault, never only into chat.**
The vault is the source of truth; the next sync re-indexes it; every agent — including the
orchestrator on its next run — then sees the new facts. That closed loop
(brain → plan → workers → vault → brain) is what turns a pile of agents into one system
with one memory.

## You don't have to dedicate a runtime
Any worker agent (e.g. Claude Code) can take the orchestrator role for a single session by
being handed the coordinating prompt and allowed to call the others. OpenClaw or Hermes just
make it **persistent and scheduled** instead of on-demand.

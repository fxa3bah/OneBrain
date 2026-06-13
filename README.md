# OneBrain

**One Obsidian vault → one local brain → every AI agent sharing the same memory. 100% on-device, $0 API.**

OneBrain is a thin, reproducible **setup layer** that puts all of your AI agents
(Claude Code, Codex, Grok, a self-hosted gateway/bot, Claude Desktop/Cowork) on a
*single shared memory* served from your own machine over MCP. Edit a fact once in
Obsidian and all of them see it.

It is not a new database or model. The actual brain is **[gbrain](https://github.com/garrytan/gbrain)**.

---

## Credit: gbrain by Garry Tan

> The entire intelligence layer here — the index, the knowledge graph, the synthesis,
> and the ~80 MCP tools — is **[gbrain](https://github.com/garrytan/gbrain)**, the
> open-source local-brain project by **[Garry Tan](https://github.com/garrytan)**.
> OneBrain is just the operational wrapping around it: launchd services, a
> PGLite-safe sync loop, offline embeddings, secret hygiene, sandboxed enrichment,
> multi-agent wiring, and the install scripts.
>
> **All credit for the hard part goes to Garry Tan and the gbrain project.** If you find
> OneBrain useful, go star [github.com/garrytan/gbrain](https://github.com/garrytan/gbrain).

OneBrain pins a specific gbrain version for reproducibility (see [Prerequisites](#prerequisites)).
gbrain is licensed under its own terms; this repo's MIT license covers only the wrapper
scripts, LaunchAgents, installer, and docs in *this* repository.

---

## The problem

Run several AI agents day to day and each one keeps its *own* memory. The same facts
about your world — people, companies, projects, preferences — live in 4+ places, drift
apart, and there's no single place to ask. Classic agent amnesia, times four.

## The shape

```
            Obsidian vault  (Markdown — the only durable store)
                  │   auto-sync every 5 min (PGLite-safe: serve bounces around writes)
                  ▼
   gbrain  (PGLite index + nomic-embed via Ollama + knowledge graph + synthesis)
                  │   one HTTP MCP server · 127.0.0.1 · bearer-token auth
                  ▼
   Claude Code · Codex · Grok · your gateway/bot · Claude Desktop
                  └────────── all query the SAME brain ──────────┘
```

- **Source of truth:** your Obsidian vault. Plain Markdown. Agents read it and write
  durable facts back into it.
- **Brain layer:** [gbrain](https://github.com/garrytan/gbrain) — indexes the vault into
  PGLite (embedded Postgres), builds a typed knowledge graph, exposes ~80 tools over MCP.
- **Embeddings:** `nomic-embed-text` in **Ollama**. Zero external API, nothing leaves the
  machine, $0 per query.
- **Clients:** every agent wired to the one HTTP MCP endpoint, each in its own config.

A rendered architecture diagram is in [`docs/architecture.html`](docs/architecture.html).

## What's in this repo

```
bin/                    wrapper scripts (serve, sync, enrichment, env, desktop bridge)
launchagents/           macOS LaunchAgents (auto-start, survive reboot)
docs/clients.md         how to wire Claude / Codex / Grok / a gateway / Claude Desktop
docs/troubleshooting.md every lesson that bit during the build
docs/architecture.html  the architecture infographic
install.sh              one-command install (idempotent)
uninstall.sh            clean removal (leaves your vault + secrets + DB intact)
.env.example            secrets template — copy to ~/.secrets/.env
```

Nothing here contains a secret. The scripts read tokens from `~/.secrets/.env` at runtime.

## Prerequisites

| Need | Why | Install |
|------|-----|---------|
| macOS | LaunchAgents / launchd | — |
| [Bun](https://bun.sh) | runs gbrain | `curl -fsSL https://bun.sh/install \| bash` |
| [Ollama](https://ollama.com) + embed model | offline embeddings | `ollama pull nomic-embed-text` |
| [gbrain](https://github.com/garrytan/gbrain) | the brain | clone to `~/Code/gbrain`, pin a version (below) |
| [Obsidian](https://obsidian.md) + a vault under `git` | source of truth | move the vault off iCloud; `git init` inside it |
| (optional) [Obsidian Sync](https://obsidian.md/sync) | multi-device | connect the *relocated* vault to your existing remote |

Pin gbrain for reproducibility, e.g.:

```bash
git clone https://github.com/garrytan/gbrain ~/Code/gbrain
cd ~/Code/gbrain && git checkout <the-commit-you-tested> && bun install
```

> This setup was built and tested against gbrain **v0.42.42.0**. Treat the pin as a gate:
> re-test the sync/serve/enrichment loop before upgrading.

## Install

```bash
# 1. secrets
cp .env.example ~/.secrets/.env && chmod 600 ~/.secrets/.env
$EDITOR ~/.secrets/.env          # set tokens + OBSIDIAN_VAULT_PATH + GBRAIN_REPO

# 2. one-time index of your vault (serve must be stopped; PGLite single-writer)
cd ~/Code/gbrain && env -u OPENAI_API_KEY bun run src/cli.ts sync --repo "$OBSIDIAN_VAULT_PATH"

# 3. install services (add --enrichment for the nightly sandboxed self-tidy)
./install.sh
```

Verify:

```bash
launchctl print gui/$(id -u)/ai.gbrain.server | grep state
curl -s -H "Authorization: Bearer $GBRAIN_REMOTE_TOKEN" http://127.0.0.1:3131/health
```

Then wire your agents — [`docs/clients.md`](docs/clients.md).

## What you get

- **Shared memory** across every agent, queryable in natural language.
- **100% offline** — embeddings and storage never leave the machine; no per-query cost.
- **Survives reboot** — LaunchAgents auto-start; works before you even sign in to apps.
- **Safe by construction** — secrets evicted from the vault, loopback + bearer auth,
  PGLite-safe sync, and a sandboxed enrichment daemon with a kill-switch + watchdog.
- **Reversible** — your vault is plain Markdown under git; the gbrain DB is a rebuildable index.

## Multi-machine

Run the same install on a second Mac. Keep the vault in sync with Obsidian Sync (each
machine runs its *own* gbrain index over the same Markdown, so page counts converge rather
than match instantly). Run the heavier `--enrichment` agent on **one** machine only.

## Security notes

- Tokens live only in `~/.secrets/.env` (chmod 600) and are read at runtime. Never commit them.
- The MCP server binds to `127.0.0.1` and still requires a bearer token.
- Keep secrets *out* of the indexed vault — anything indexed is visible to every wired agent.
- See [`docs/troubleshooting.md`](docs/troubleshooting.md) for the full list of footguns.

## License

MIT (this repo's wrapper code/docs) — see [LICENSE](LICENSE).
The brain itself, **[gbrain](https://github.com/garrytan/gbrain) by Garry Tan**, is a
separate project under its own license. Please credit it.

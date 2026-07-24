# How I built this

I run several AI agents day to day — Claude Code, Codex, Grok, and a self-hosted
gateway/bot. Each kept its *own* memory. The same facts about my world (people, companies,
projects, preferences) lived in four-plus places, drifted apart, and there was no single
place to ask. Agent amnesia, times four.

OneBrain is the fix: **one source of truth + one brain layer + many clients.**

## The decisions that mattered

- **One durable store, and it's plain Markdown.** The Obsidian vault is the only thing that
  has to survive. Everything else (the index, the embeddings, the graph) is rebuildable from
  it. That constraint kept the whole system reversible.
- **The brain is [gbrain](https://github.com/garrytan/gbrain) by Garry Tan.** I did not build
  an index or a knowledge graph — gbrain already does that, well, locally, over MCP. OneBrain
  is just the operational wrapping around it. All credit for the hard part goes to Garry Tan.
- **100% offline.** Embeddings run on local Ollama (`nomic-embed-text`). The wrappers actively
  `unset OPENAI_API_KEY` so nothing silently falls back to a paid cloud API. $0 per query,
  nothing leaves the machine.
- **One endpoint, every agent.** A single loopback HTTP MCP server with bearer auth. Each
  agent points at it in its own config. Ask any one — same answer, same memory.
- **Passive brain, pluggable orchestrator.** Because the brain just answers, any agent can be
  put *in charge* of it on a schedule (see [`orchestrator.md`](orchestrator.md) — OpenClaw or
  YourVault/Nous). The orchestrator plans and dispatches; workers write results back to the vault;
  the brain re-indexes. Closed loop.

## The things that bit me

The full list is in [`troubleshooting.md`](troubleshooting.md), but the big ones:
PGLite is single-writer (so sync/enrichment bounce the server around writes); secrets in a
vault note get served to every agent (evict them first); an autonomous enrichment daemon needs
a kill-switch and a watchdog; and Obsidian Sync only propagates while the app is open, which
surprises you the first time you move a vault off iCloud.

## Result

One vault, one brain, every agent on the same memory — offline, reboot-proof, and
git-reversible. Edit a fact once in Obsidian and all of them see it.

---

*Discussion / write-up:* this started as a Reddit post about the architecture.
<!-- Reddit thread: add link here -->

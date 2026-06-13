# Troubleshooting & hard-won lessons

These are the things that actually bit during the build. If you replicate OneBrain,
you will probably hit some of them too.

## 1. PGLite is single-writer
A running `gbrain serve` holds the database lock. A background sync or the nightly
enrichment job will just block (or corrupt, if forced) while serve is up.

**Fix (built in):** the sync and enrichment wrappers *stop serve → write → restart serve*,
and the sync only bounces serve when the vault's git HEAD actually changed (most ticks
are no-ops). CLI `gbrain stats`/`query` will also time out while serve holds the lock —
stop serve first, or go through the MCP endpoint.

## 2. Secrets in the vault get served to every agent
If you keep API keys in a vault note, the moment you index that vault and serve it over
MCP you've handed those keys to every connected agent.

**Fix:** evict secrets to `~/.secrets/.env` (chmod 600) and exclude the note from the index
*before* indexing anything. Nothing sensitive should be in the indexed vault.

## 3. Config-mirror notes leak across agents
Notes that mirror one agent's live operating instructions will (a) drift and (b) let
agent A read agent B's rules through the shared brain.

**Fix:** exclude those notes from the shared index (gbrain respects `git` tracking — untrack
them and `.gitignore` them). Everything else is shared.

## 4. Autonomous enrichment needs a leash
A nightly self-maintenance daemon that can restart itself can storm.

**Fix (built in):** enrichment runs sandboxed — a kill-switch file
(`~/.gbrain/ENRICHMENT_DISABLED`) plus a watchdog that self-disables if it starts
more than 3 times in 10 minutes. It only ever calls `launchctl` on its *own* label,
never on any other service.

## 5. Embeddings are not chat models
Don't embed with your big local generation model. A dedicated embedding model
(`nomic-embed-text`, ~274 MB) is faster and better for retrieval. OneBrain actively
`unset OPENAI_API_KEY` in every wrapper so nothing silently falls back to a paid API.

## 6. Sync that needs an app open is not headless sync
OneBrain keeps the vault in sync across machines/devices with **Obsidian Sync**, which
only propagates while the Obsidian app is running. If you move your vault off iCloud
(recommended, to avoid iCloud-vs-Obsidian-Sync conflicts) and then close Obsidian on the
machine that writes notes, nothing propagates even though files are landing on disk.

**Fix:** keep Obsidian running on the writer machine (add it as a login item). When
connecting a relocated vault to Sync, choose **Connect to the existing remote vault** —
do not "create new," or you end up with two clouds that never meet. Note that recent
Obsidian stores the remote pairing in its internal store, not a flat `.obsidian/sync.json`.

## 7. GUI-launched CLIs don't inherit your shell env
A CLI agent started from a GUI app won't have the token you exported in `~/.zshenv`.

**Fix (built in):** the `ai.gbrain.env` LaunchAgent registers the bearer token into the
GUI launchd session at login via `launchctl setenv`.

## 8. Per-machine indexes converge, they don't mirror instantly
On a multi-machine setup each machine runs its own gbrain index over the same synced
vault. Page counts converge over time rather than matching the same second. The **vault**
(Markdown) is the source of truth; the gbrain DB is a rebuildable index — if it ever drifts,
re-sync from the vault.

## Useful commands

```bash
# Is serve healthy?
launchctl print gui/$(id -u)/ai.gbrain.server | grep state
curl -s -H "Authorization: Bearer $GBRAIN_REMOTE_TOKEN" http://127.0.0.1:3131/health

# Force a sync now
~/.gbrain/bin/gbrain-sync.sh

# Re-enable enrichment after the watchdog tripped
rm ~/.gbrain/ENRICHMENT_DISABLED

# Tail logs
tail -f ~/.gbrain/logs/server.err.log ~/.gbrain/logs/sync.out.log
```

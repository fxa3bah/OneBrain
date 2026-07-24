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

## A rogue `com.gbrain.autopilot` LaunchAgent (found 2026-07-24)

Symptom: `apply-migrations` fails with "Timed out waiting for PGLite data-dir lock",
naming a process running `gbrain autopilot --repo <some old vault path>`.

Cause: `gbrain autopilot --install` writes its own LaunchAgent, `com.gbrain.autopilot`,
which is NOT part of OneBrain (OneBrain uses the `ai.gbrain.*` prefix). On this machine it
survived the 2026-06-12 vault move off iCloud and was still pointed at the old
`~/Library/Mobile Documents/iCloud~md~obsidian/.../Hermes` path, which no longer exists.
With `KeepAlive=true` and `ThrottleInterval=60` it crash-looped every 60 seconds, taking
the PGLite write lock on each attempt and logging `[cycle.purge] done` against a vault it
could not see.

Why it matters: it blocked migrations, and an autopilot purge cycle pointed at a missing
vault is a data-loss shape. Verify page counts after finding one.

Fix:
```bash
launchctl bootout gui/$(id -u)/com.gbrain.autopilot
mv ~/Library/LaunchAgents/com.gbrain.autopilot.plist ~/.gbrain/disabled-launchagents/
rm -rf ~/.gbrain/brain.pglite/.gbrain-lock   # only after confirming the holder PID is dead
```

Check for it with `launchctl list | grep gbrain` and treat any `com.gbrain.*` label as
foreign to OneBrain.

## `apply-migrations` needs a `gbrain` binary on PATH

Its smoke and host-work phases shell out to `gbrain`. If you deliberately keep no such
binary, migrations apply but are recorded as PARTIAL or FAILED, and `doctor` then reports
`[FAIL] minions_migration: MINIONS HALF-INSTALLED`. Give it a temporary shim:

```bash
SHIM=$(mktemp -d)
printf '#!/bin/bash\nexec bun run ~/Code/gbrain/src/cli.ts "$@"\n' > "$SHIM/gbrain"
chmod +x "$SHIM/gbrain"
PATH="$SHIM:$PATH" bun run ~/Code/gbrain/src/cli.ts apply-migrations --yes
rm -rf "$SHIM"
```

Re-run until it prints "All migrations up to date", then confirm `doctor` shows no FAIL.

## The documented full-rebuild procedure is UNSAFE (verified the hard way, 2026-07-24)

`OneBrain.md` and older notes recommend this to rebuild the index from the vault:

```bash
rm -rf ~/.gbrain/brain.pglite
gbrain init --pglite --embedding-model ollama:nomic-embed-text
gbrain import ~/Obsidian/Hermes
```

Run on a healthy brain (v0.42.65.0, 428 pages, brain_score 84, orphan_pages 19,
link_coverage 1.0) it produced a WORSE brain and a total outage:

| Metric | Before | After rebuild |
|---|---|---|
| brain_score | 84 | **45** |
| orphan_pages | 19 | **282** |
| link_coverage | 1.0 | **0** |
| every agent's MCP auth | 200 | **401** |

Two independent failures:

1. **It wipes the auth token table.** API tokens live in the database, not in config.
   A fresh `init` leaves zero tokens, so every wired agent (Claude, Codex, Grok, Warp,
   Hermes, Cursor, Qoder) gets `invalid_token` / 401 at once. The
   `GBRAIN_ADMIN_BOOTSTRAP_TOKEN` from `~/.secrets/.env` does NOT authenticate either.
   Recovery is `gbrain auth create <name>` and then writing the new value over
   `GBRAIN_REMOTE_TOKEN` in `~/.secrets/.env`, which is the single place every agent
   resolves it from.

2. **Links do not come back.** After `import`, `extract all`, `extract --stale`,
   `extract all --catch-up` and a full `sync --repo` pass, link extraction reported
   `0 links` every time and `link_coverage` stayed at 0. Pages import as "unchanged"
   so nothing reprocesses. No flag in `extract` forces re-linking.

**Do not run a full rebuild to "refresh" a healthy brain.** The incremental path
(`sync --repo` plus `extract --stale`, which the 5-minute loop already does) keeps
link coverage intact. Reserve the rebuild for genuine corruption, and only with:

- a `cp -R` copy of `brain.pglite` taken with serve stopped, and
- `link_coverage` checked immediately after; if it is 0, restore the copy.

Restoring the copy and reverting `~/.secrets/.env` returned the brain to 84 / 19 / 1.0
within a minute, which is the only reason this was a non-event.

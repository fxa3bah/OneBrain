#!/bin/bash
# OneBrain — vault -> gbrain incremental sync (PGLite-safe).
# PGLite is single-writer: gbrain serve holds the lock, so we bounce serve around the sync.
# Only bounces serve when the vault HEAD actually changed (most ticks are no-ops).
set -uo pipefail

export PATH="/Users/faadi/.bun/bin:/opt/homebrew/bin:/Users/faadi/.nvm/versions/node/v24.13.0/bin:/usr/bin:/bin:/usr/sbin:/sbin"
VAULT="/Users/faadi/Obsidian/Hermes"
UID_N="$(id -u)"
SERVE_PLIST="/Users/faadi/Library/LaunchAgents/ai.gbrain.server.plist"
LOCKDIR="/Users/faadi/.gbrain/sync.lock.d"
LAST="/Users/faadi/.gbrain/last-synced-commit"
CLI="/Users/faadi/Code/gbrain/src/cli.ts"

# Single-instance lock (macOS has no flock; mkdir is atomic)
if ! mkdir "$LOCKDIR" 2>/dev/null; then echo "$(date -u +%FT%TZ) sync already running, skip"; exit 0; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

cd "$VAULT" || { echo "vault missing"; exit 1; }

# Commit any Obsidian edits so the git-based sync can see them.
if [ -n "$(git status --porcelain)" ]; then
  git add -A && git commit -q -m "auto-sync $(date -u +%FT%TZ)"
fi

HEAD="$(git rev-parse HEAD)"
PREV="$(cat "$LAST" 2>/dev/null || echo none)"

# Off-machine backup. The vault git dir lives on the same disk as the vault itself,
# so without this a single disk failure loses the brain and every agent's source of
# truth. Mirrors to the MacBook Air (own hardware — the vault holds medical/financial
# notes, so this must not go to a cloud git host).
# Deliberately non-fatal and connection-bounded: an Air that is asleep or off-network
# must never block, slow, or fail the brain sync. Retries on the next tick.
LASTPUSH="/Users/faadi/.gbrain/last-pushed-commit"
if [ "$HEAD" != "$(cat "$LASTPUSH" 2>/dev/null || echo none)" ]; then
  if GIT_SSH_COMMAND='ssh -o ConnectTimeout=5 -o BatchMode=yes' \
       git push --quiet air master:refs/heads/vault-live 2>/dev/null; then
    echo "$HEAD" > "$LASTPUSH"
    echo "$(date -u +%FT%TZ) off-machine backup pushed to air ($HEAD)"
  else
    echo "$(date -u +%FT%TZ) off-machine backup FAILED (air unreachable) — retry next tick"
  fi
fi

if [ "$HEAD" = "$PREV" ]; then echo "$(date -u +%FT%TZ) no changes ($HEAD), serve untouched"; exit 0; fi

echo "$(date -u +%FT%TZ) changes detected ($PREV -> $HEAD), bouncing serve for sync"
launchctl bootout "gui/$UID_N/ai.gbrain.server" 2>/dev/null
# wait briefly for the PGLite lock to release
for i in 1 2 3 4 5; do sleep 1; lsof -nP -iTCP:3131 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN || break; done

env -u OPENAI_API_KEY bun run "$CLI" sync --repo "$VAULT" --no-pull --skip-failed
rc=$?

# Extract typed edges for anything newly synced. Without this, sync indexes a note's
# CONTENT but not its LINKS, so a new note stays an orphan until the nightly 03:17
# enrichment runs — a window of up to 24h. That gap is exactly what produced the
# 2026-07-24 incident: 67 Bank SMS notes written at 04:13 showed as orphans at 04:40,
# spiking orphan_pages 30 -> 113, because extraction had not run since.
# Use `extract all`, NOT `extract --stale`. --stale looks at page staleness, which sync has
# already cleared, so it reports "No stale pages" and creates zero links for notes that were
# just added or newly linked — verified twice: the Bank SMS batch, and again on 2026-07-24
# when four new notes linked from their MOCs still showed zero backlinks after a --stale pass.
# `extract all` is idempotent and costs ~1.4s across 445 pages, so there is no reason to narrow it.
# Offline, zero LLM calls. serve is still down here, so the PGLite write lock is free.
env -u OPENAI_API_KEY bun run "$CLI" extract all 2>&1 | tail -2

# Always bring serve back, even if sync failed.
launchctl bootstrap "gui/$UID_N" "$SERVE_PLIST" 2>/dev/null

if [ $rc -eq 0 ]; then echo "$HEAD" > "$LAST"; echo "$(date -u +%FT%TZ) sync OK, serve restarted"; else echo "$(date -u +%FT%TZ) sync rc=$rc, serve restarted"; fi
exit $rc

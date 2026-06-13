#!/bin/bash
# OneBrain — vault -> gbrain incremental sync (PGLite-safe).
# PGLite is single-writer: `gbrain serve` holds the lock, so we bounce serve around the sync.
# Only bounces serve when the vault HEAD actually changed (most ticks are no-ops).
set -uo pipefail
source "$(dirname "$0")/onebrain-common.sh"

VAULT="$OBSIDIAN_VAULT_PATH"
LOCKDIR="$GBRAIN_HOME/sync.lock.d"
LAST="$GBRAIN_HOME/last-synced-commit"

# Single-instance lock (macOS has no flock; mkdir is atomic)
if ! mkdir "$LOCKDIR" 2>/dev/null; then echo "$(date -u +%FT%TZ) sync already running, skip"; exit 0; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

cd "$VAULT" || { echo "vault missing: $VAULT"; exit 1; }

# Commit any Obsidian edits so the git-based sync can see them.
if [ -n "$(git status --porcelain)" ]; then
  git add -A && git commit -q -m "auto-sync $(date -u +%FT%TZ)"
fi

HEAD="$(git rev-parse HEAD)"
PREV="$(cat "$LAST" 2>/dev/null || echo none)"
if [ "$HEAD" = "$PREV" ]; then echo "$(date -u +%FT%TZ) no changes ($HEAD), serve untouched"; exit 0; fi

echo "$(date -u +%FT%TZ) changes detected ($PREV -> $HEAD), bouncing serve for sync"
launchctl bootout "gui/$UID_N/ai.gbrain.server" 2>/dev/null
# wait briefly for the PGLite lock to release
for i in 1 2 3 4 5; do sleep 1; lsof -nP -iTCP:"$GBRAIN_PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN || break; done

env -u OPENAI_API_KEY bun run "$GBRAIN_CLI" sync --repo "$VAULT" --no-pull --skip-failed
rc=$?

# Always bring serve back, even if sync failed.
launchctl bootstrap "gui/$UID_N" "$SERVE_PLIST" 2>/dev/null

if [ $rc -eq 0 ]; then echo "$HEAD" > "$LAST"; echo "$(date -u +%FT%TZ) sync OK, serve restarted"; else echo "$(date -u +%FT%TZ) sync rc=$rc, serve restarted"; fi
exit $rc

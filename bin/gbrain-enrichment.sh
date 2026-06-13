#!/bin/bash
# OneBrain enrichment — SANDBOXED, self-disabling, PGLite-safe.
# Only ever touches $GBRAIN_HOME, the vault, and its OWN launchd label.
# Never calls launchctl on any other service (learned the hard way: a self-restart
# loop once took down a separate messaging gateway).
set -uo pipefail
source "$(dirname "$0")/onebrain-common.sh"

SENTINEL="$GBRAIN_HOME/ENRICHMENT_DISABLED"
STARTS="$GBRAIN_HOME/enrichment-starts.log"
TIERF="$GBRAIN_HOME/ENRICHMENT_TIER"
LOCK="$GBRAIN_HOME/enrichment.lock.d"

# --- KILL SWITCH ---
if [ -f "$SENTINEL" ]; then echo "$(date -u +%FT%TZ) enrichment DISABLED (sentinel present)"; exit 0; fi

# --- WATCHDOG: >3 starts in 10 min -> self-disable (structural fix for restart storms) ---
now="$(date +%s)"; echo "$now" >> "$STARTS"
recent="$(awk -v c=$((now-600)) '$1>=c' "$STARTS" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${recent:-0}" -gt 3 ]; then
  touch "$SENTINEL"
  echo "$(date -u +%FT%TZ) WATCHDOG TRIPPED ($recent starts/10min) -> self-disabled. Remove $SENTINEL to re-enable."
  exit 0
fi

# --- single-instance lock ---
if ! mkdir "$LOCK" 2>/dev/null; then echo "$(date -u +%FT%TZ) enrichment already running"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

TIER="$(cat "$TIERF" 2>/dev/null || echo 1)"
run(){ env -u OPENAI_API_KEY bun run "$GBRAIN_CLI" "$@"; }

echo "=== enrichment START tier=$TIER @ $(date -u +%FT%TZ) ==="
# Release the PGLite write lock held by serve
launchctl bootout "gui/$UID_N/ai.gbrain.server" 2>/dev/null
for i in 1 2 3 4 5; do sleep 1; lsof -nP -iTCP:"$GBRAIN_PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN || break; done

# TIER 1 — housekeeping, 100% offline (extract = typed edges, zero LLM calls)
run extract all   2>&1 | tail -3
run embed --stale 2>&1 | tail -2

# TIER 2 — preview the synthesis cycle (dry-run, no writes) once tier>=2
if [ "$TIER" -ge 2 ]; then run dream --dry-run 2>&1 | tail -6; fi

# TIER 3 — full synthesis cycle (REQUIRES a local Ollama chat model; writes to 60 Synthesis/)
if [ "$TIER" -ge 3 ]; then run dream 2>&1 | tail -10; fi

run doctor --fast 2>&1 | grep -iE "health|\[ok\]|\[warn\]|\[fail\]" | tail -4

# Always bring serve back
launchctl bootstrap "gui/$UID_N" "$SERVE_PLIST" 2>/dev/null
echo "=== enrichment DONE tier=$TIER @ $(date -u +%FT%TZ) ==="

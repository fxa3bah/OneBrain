#!/bin/bash
# OneBrain enrichment — SANDBOXED, self-disabling, PGLite-safe, isolated from the Hermes gateway.
# Only ever touches ~/.gbrain, the vault, and its OWN launchd label. Never calls launchctl on the gateway.
set -uo pipefail
export PATH="/Users/faadi/.bun/bin:/opt/homebrew/bin:/Users/faadi/.nvm/versions/node/v24.13.0/bin:/usr/bin:/bin:/usr/sbin:/sbin"

GBR="/Users/faadi/.gbrain"
CLI="/Users/faadi/Code/gbrain/src/cli.ts"
UID_N="$(id -u)"
SENTINEL="$GBR/ENRICHMENT_DISABLED"
STARTS="$GBR/enrichment-starts.log"
TIERF="$GBR/ENRICHMENT_TIER"
LOCK="$GBR/enrichment.lock.d"
SERVE_PLIST="/Users/faadi/Library/LaunchAgents/ai.gbrain.server.plist"

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
run(){ env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bun run "$CLI" "$@"; }

echo "=== enrichment START tier=$TIER @ $(date -u +%FT%TZ) ==="
# Release the PGLite write lock held by serve
launchctl bootout "gui/$UID_N/ai.gbrain.server" 2>/dev/null
for i in 1 2 3 4 5; do sleep 1; lsof -nP -iTCP:3131 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN || break; done

# TIER 1 — housekeeping, 100% offline (extract = typed edges, zero LLM calls)
run extract all   2>&1 | tail -3
run embed --stale 2>&1 | tail -2
# Contradiction probe. This was previously invoked bare and failed EVERY night
# with "Must pass exactly one of: --queries-file FILE, --query ..., --from-capture"
# — so contradiction detection had never once run. It needs a probe set:
# ~/.gbrain/eval-queries.txt holds questions about your actual world (which
# machine is primary, where secrets live, which model is allowed on the API...),
# i.e. exactly the facts that go stale and cause wrong answers.
QUERIES="$GBR/eval-queries.txt"
if [ -f "$QUERIES" ]; then
  run eval suspected-contradictions --queries-file "$QUERIES" --budget-usd 0 --yes 2>&1 | tail -6
else
  echo "WARN: $QUERIES missing — contradiction probe skipped (create it to re-enable)"
fi

# TIER 2 — preview the dream cycle (dry-run, no writes) once tier>=2
if [ "$TIER" -ge 2 ]; then run dream --dry-run 2>&1 | tail -6; fi

# TIER 3 — full dream cycle (REQUIRES a local Ollama chat_model; writes synthesis to 60 Synthesis/)
if [ "$TIER" -ge 3 ]; then run dream 2>&1 | tail -10; fi

run doctor --fast 2>&1 | grep -iE "health|\[ok\]|\[warn\]|\[fail\]" | tail -4

# Always bring serve back
launchctl bootstrap "gui/$UID_N" "$SERVE_PLIST" 2>/dev/null
echo "=== enrichment DONE tier=$TIER @ $(date -u +%FT%TZ) ==="

#!/bin/bash
# OneBrain installer.
# Copies wrapper scripts to ~/.gbrain/bin, installs LaunchAgents (with __HOME__ substituted),
# and loads them. Idempotent: safe to re-run. Does NOT touch your secrets or your vault.
#
# Prereqs (see README): bun, Ollama + `ollama pull nomic-embed-text`, a gbrain checkout,
# an Obsidian vault under git, and ~/.secrets/.env populated from .env.example.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
GBRAIN_HOME="$HOME/.gbrain"
BIN_DIR="$GBRAIN_HOME/bin"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
UID_N="$(id -u)"

echo "OneBrain installer"
echo "  repo:        $REPO_DIR"
echo "  scripts ->   $BIN_DIR"
echo "  agents  ->   $LAUNCH_DIR"
echo

# --- preflight ---
command -v bun  >/dev/null || { echo "ERROR: bun not found. Install from https://bun.sh"; exit 1; }
command -v ollama >/dev/null || echo "WARN: ollama not found — needed for offline embeddings (https://ollama.com)"
[ -f "$HOME/.secrets/.env" ] || echo "WARN: ~/.secrets/.env missing — copy .env.example there and fill it in BEFORE the agents will work."

# --- scripts ---
mkdir -p "$BIN_DIR" "$GBRAIN_HOME/logs"
cp "$REPO_DIR"/bin/*.sh "$BIN_DIR"/
chmod +x "$BIN_DIR"/*.sh
echo "[ok] wrapper scripts installed"

# Run setup first unless the caller opts out. It verifies every value rather than
# collecting it — a config that exists and a config that works are different states,
# and shipping people the second one is the whole point.
if [[ "${SKIP_SETUP:-0}" != "1" ]]; then
  "$REPO_DIR/scripts/onebrain-setup.sh" || {
    echo "[!!] setup incomplete — fix the items above, then re-run ./install.sh"
    echo "     (bypass with SKIP_SETUP=1 ./install.sh)"
    exit 1
  }
fi

# Default enrichment tier = 1 (offline housekeeping only). Bump to 2/3 yourself later.
[ -f "$GBRAIN_HOME/ENRICHMENT_TIER" ] || echo "1" > "$GBRAIN_HOME/ENRICHMENT_TIER"

# --- LaunchAgents (substitute __HOME__; launchd can't expand env vars) ---
mkdir -p "$LAUNCH_DIR"
# ai.gbrain.doctor is the knowledge-health sentinel. It is NOT optional: it is the
# only thing that notices when the brain silently degrades, and every real fault in
# this stack has been silent. It is read-only and cheap (one MCP call per day).
AGENTS=(ai.gbrain.server ai.gbrain.sync ai.gbrain.env ai.gbrain.doctor ai.gbrain.lessons)
# enrichment is optional/heavier — install it only with --enrichment
if [[ "${1:-}" == "--enrichment" ]]; then AGENTS+=(ai.gbrain.enrichment); fi

# Probe set for the nightly contradiction check. Ships with a generic starter; edit it
# to ask about facts that actually go stale in YOUR world.
[ -f "$GBRAIN_HOME/eval-queries.txt" ] || cp "$REPO_DIR/config/eval-queries.txt" "$GBRAIN_HOME/eval-queries.txt" 2>/dev/null || true

for a in "${AGENTS[@]}"; do
  sed "s#__HOME__#$HOME#g" "$REPO_DIR/launchagents/$a.plist" > "$LAUNCH_DIR/$a.plist"
  launchctl bootout "gui/$UID_N/$a" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_N" "$LAUNCH_DIR/$a.plist"
  echo "[ok] loaded $a"
done

echo
echo "Done. Verify with:"
echo "  launchctl print gui/$UID_N/ai.gbrain.server | grep state"
echo "  curl -s -H \"Authorization: Bearer \$GBRAIN_REMOTE_TOKEN\" http://127.0.0.1:3131/health"
echo
echo "Then wire your AI clients — see docs/clients.md."

#!/bin/bash
# OneBrain uninstaller — stops & removes the LaunchAgents and wrapper scripts.
# Does NOT delete your vault, your gbrain checkout, your secrets, or the gbrain DB.
set -uo pipefail
UID_N="$(id -u)"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

for a in ai.gbrain.server ai.gbrain.sync ai.gbrain.enrichment ai.gbrain.env; do
  launchctl bootout "gui/$UID_N/$a" 2>/dev/null && echo "[ok] stopped $a" || echo "[--] $a not loaded"
  rm -f "$LAUNCH_DIR/$a.plist"
done

rm -f "$HOME/.gbrain/bin/"gbrain-*.sh "$HOME/.gbrain/bin/onebrain-common.sh" "$HOME/.gbrain/bin/desktop-bridge.sh"
echo "[ok] wrapper scripts removed"
echo "Left intact: your vault, gbrain checkout, ~/.secrets/.env, and ~/.gbrain DB/logs."

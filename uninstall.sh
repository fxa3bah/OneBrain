#!/bin/bash
# OneBrain uninstaller — stops & removes the LaunchAgents and wrapper scripts.
# Does NOT delete your vault, your gbrain checkout, your secrets, or the gbrain DB.
#
# The agent list below MUST stay in sync with install.sh. A half-uninstall is worse
# than none: agents left loaded keep firing on a schedule, writing to a vault the
# user believes they have disconnected. If you add an agent to install.sh, add it
# here in the same commit.
set -uo pipefail
UID_N="$(id -u)"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

# Every agent install.sh can create, including the optional one.
AGENTS=(
  ai.gbrain.server
  ai.gbrain.sync
  ai.gbrain.env
  ai.gbrain.doctor        # knowledge-health sentinel
  ai.gbrain.lessons       # nightly lesson capture
  ai.gbrain.enrichment    # optional (--enrichment)
)

for a in "${AGENTS[@]}"; do
  launchctl bootout "gui/$UID_N/$a" 2>/dev/null && echo "[ok] stopped $a" || echo "[--] $a not loaded"
  rm -f "$LAUNCH_DIR/$a.plist"
done

# Wrapper scripts. Note onebrain-notify.sh does NOT match the gbrain-* glob and
# has to be named explicitly — an earlier version of this file orphaned it.
rm -f "$HOME/.gbrain/bin/"gbrain-*.sh \
      "$HOME/.gbrain/bin/onebrain-common.sh" \
      "$HOME/.gbrain/bin/onebrain-notify.sh" \
      "$HOME/.gbrain/bin/desktop-bridge.sh"
echo "[ok] wrapper scripts removed"

# Verify nothing survived. Silence is not proof, so check.
REMAINING="$(launchctl list 2>/dev/null | grep -c 'ai\.gbrain\.' || true)"
if [ "${REMAINING:-0}" -gt 0 ]; then
  echo "[!!] $REMAINING gbrain agent(s) STILL LOADED — inspect with: launchctl list | grep gbrain"
else
  echo "[ok] no gbrain agents remain loaded"
fi

cat <<'EOF'

Left intact (delete by hand if you want them gone):
  ~/Obsidian/<your vault>     your notes — the actual source of truth
  ~/Code/gbrain               the gbrain checkout
  ~/.gbrain/                  brain DB, logs, heartbeats, eval-queries.txt
  ~/.secrets/.env             gbrain tokens
  ~/.onebrain/notify.env      NOTIFIER CONFIG — contains a Telegram bot token if
                              you set one up. Remove it if you are done with OneBrain.
EOF

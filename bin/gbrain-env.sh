#!/bin/bash
# OneBrain — register the client bearer token into the GUI launchd session at login,
# so CLI agents launched from the GUI (e.g. Codex, a desktop app) inherit it even
# when they don't start from an interactive shell that sourced ~/.zshenv.
source "$(dirname "$0")/onebrain-common.sh"
TOK="$(read_secret GBRAIN_REMOTE_TOKEN)"
[ -n "$TOK" ] && /bin/launchctl setenv GBRAIN_REMOTE_TOKEN "$TOK"

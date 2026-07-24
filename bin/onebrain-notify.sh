#!/usr/bin/env bash
# OneBrain — generic notifier. One place that knows how to reach a human.
#
# gbrain has no notification layer: no notify module in src/core, and every
# Telegram reference in its source is the conversation PARSER (reading Telegram
# transcripts as input), not sending. Its one Telegram-adjacent integration,
# restart-sweep, is OpenClaw-specific. So alerting is the wrapper's job, and
# before this file every alerting script rolled its own curl.
#
# Usage:  onebrain-notify.sh "<message>" [subject]
#
# Channels, all optional and independent. Configure the ones you want; the rest
# no-op silently. Exits 0 always — a notifier must never break its caller.
#
#   Telegram : ~/.onebrain/notify.env  ->  TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=...
#              (falls back to a Claude Code telegram channel .env if present)
#   macOS    : automatic on Darwin
#   Log      : always, ~/.gbrain/logs/notify.log
#
# Deliberately NOT here: email, Slack, webhooks, retries, queues. Add a channel
# only when something actually needs it.
set -uo pipefail

MSG="${1:-}"
SUBJECT="${2:-OneBrain}"
[ -n "$MSG" ] || exit 0

TS="$(date -u +%FT%TZ)"
LOG="$HOME/.gbrain/logs/notify.log"
mkdir -p "$(dirname "$LOG")"
echo "$TS [$SUBJECT] $MSG" >> "$LOG"

# --- config ---
CONF="$HOME/.onebrain/notify.env"
TG_TOKEN=""; TG_CHAT=""
if [ -f "$CONF" ]; then
  TG_TOKEN="$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '\r\n"'"'"'')"
  TG_CHAT="$(grep -m1 '^TELEGRAM_CHAT_ID='  "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '\r\n"'"'"'')"
fi
# Fallback: reuse an existing Claude Code telegram channel token if configured.
if [ -z "$TG_TOKEN" ] && [ -f "$HOME/.claude/channels/telegram/.env" ]; then
  TG_TOKEN="$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$HOME/.claude/channels/telegram/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r\n"'"'"'')"
fi

# --- Telegram ---
if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  if curl -sS -m 10 -o /dev/null \
       --data-urlencode "chat_id=$TG_CHAT" \
       --data-urlencode "text=🧠 $SUBJECT: $MSG" \
       "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" 2>/dev/null; then
    echo "$TS   -> telegram ok" >> "$LOG"
  else
    echo "$TS   -> telegram FAILED" >> "$LOG"
  fi
elif [ -n "$TG_TOKEN" ]; then
  echo "$TS   -> telegram skipped: TELEGRAM_CHAT_ID not set in $CONF" >> "$LOG"
fi

# --- macOS notification ---
# Pass the text through argv, NOT string interpolation. Interpolating into
# `osascript -e "... \"$MSG\" ..."` lets any double quote in the message break out
# of the AppleScript string literal and inject script — verified: a message
# containing `" with title "X" default answer "` produces a syntax error, and a
# crafted one would execute. Alert text originates from gbrain output, so it is
# not attacker-controlled today, but argv costs nothing and closes the class.
if [ "$(uname)" = "Darwin" ]; then
  /usr/bin/osascript - "$MSG" "$SUBJECT" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  display notification (item 1 of argv) with title (item 2 of argv)
end run
APPLESCRIPT
fi

exit 0

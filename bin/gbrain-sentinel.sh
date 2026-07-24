#!/bin/bash
# OneBrain — gbrain knowledge-health sentinel.
# Read-only. Queries the ALREADY-RUNNING ai.gbrain.server over its HTTP MCP
# endpoint with a static legacy bearer token (GBRAIN_REMOTE_TOKEN) instead of
# opening a second local PGLite connection — PGLite is single-writer, so the
# local `gbrain doctor` CLI path conflicts with serve's held lock. The raw
# bearer + stateless tools/call pattern here mirrors src/core/connect-probe.ts
# in the gbrain repo (smoke-tests `gbrain connect`) and needs no session
# handshake. Never bounces ai.gbrain.server; never calls a gbrain write op.
set -uo pipefail

export PATH="/Users/faadi/.bun/bin:/opt/homebrew/bin:/Users/faadi/.nvm/versions/node/v24.13.0/bin:/usr/bin:/bin:/usr/sbin:/sbin"

MCP_URL="http://127.0.0.1:3131/mcp"
BASELINE="$HOME/.gbrain/health-baseline.json"
LOG="$HOME/.gbrain/logs/sentinel.log"
SYNC_LOG="$HOME/.gbrain/logs/sync.out.log"
VAULT_NOTE="$HOME/Obsidian/Hermes/System/Brain Health Log.md"

TS="$(date -u +%FT%TZ)"
log() { echo "$TS $*" >> "$LOG"; }

TOKEN="$(grep '^GBRAIN_REMOTE_TOKEN=' "$HOME/.secrets/.env" 2>/dev/null | cut -d= -f2- | tr -d '\n')"
if [ -z "$TOKEN" ]; then
  log "CRITICAL: GBRAIN_REMOTE_TOKEN not found in ~/.secrets/.env — cannot run health check"
  exit 1
fi

# mcp_call <tool> <json-args> — stateless JSON-RPC tools/call over the
# Streamable HTTP transport, bearer-auth'd, no prior initialize/session
# needed (verified against this server: single POST returns the result).
# Echoes the *unwrapped* tool-result JSON object on stdout, or nothing on
# any failure (network, auth, JSON-RPC error, or malformed SSE envelope).
mcp_call() {
  local tool="$1" args="$2" raw
  raw="$(curl -sS -m 15 -X POST "$MCP_URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}" 2>/dev/null)"
  [ -z "$raw" ] && return 1
  local data
  data="$(printf '%s\n' "$raw" | grep '^data: ' | sed 's/^data: //')"
  [ -z "$data" ] && return 1
  printf '%s' "$data" | jq -e '.result.content[0].text' -r 2>/dev/null | jq -e '.' 2>/dev/null
}

HEALTH="$(mcp_call get_health '{}')"
if [ -z "$HEALTH" ] || [ "$HEALTH" = "null" ]; then
  log "CRITICAL: gbrain server unreachable or get_health failed at $MCP_URL — is ai.gbrain.server up?"
  exit 1
fi

BRAIN_SCORE="$(echo "$HEALTH" | jq -r '.brain_score')"
ORPHAN_PAGES="$(echo "$HEALTH" | jq -r '.orphan_pages')"
EMBED_COVERAGE="$(echo "$HEALTH" | jq -r '.embed_coverage')"
DEAD_LINKS="$(echo "$HEALTH" | jq -r '.dead_links')"
PAGE_COUNT="$(echo "$HEALTH" | jq -r '.page_count')"

# --- sync-freshness check: last completed cycle in sync.out.log (either
# "no changes ... serve untouched" or "sync OK, serve restarted" — both are
# a clean cycle; "sync rc=N, serve restarted" is a failed cycle). ---
SYNC_STALE=0
SYNC_DETAIL="no sync log found at $SYNC_LOG"
if [ -f "$SYNC_LOG" ]; then
  LAST_CYCLE_LINE="$(grep -E 'no changes \(|sync OK|sync rc=' "$SYNC_LOG" | tail -1)"
  if [ -z "$LAST_CYCLE_LINE" ]; then
    SYNC_STALE=1
    SYNC_DETAIL="sync log exists but has no completed-cycle line at all"
  else
    LAST_TS="$(echo "$LAST_CYCLE_LINE" | awk '{print $1}')"
    LAST_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS" +%s 2>/dev/null)"
    NOW_EPOCH="$(date -u +%s)"
    if [ -z "$LAST_EPOCH" ]; then
      SYNC_STALE=1
      SYNC_DETAIL="could not parse timestamp from last cycle line: $LAST_CYCLE_LINE"
    else
      AGE_MIN=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
      if [ "$AGE_MIN" -gt 120 ]; then
        SYNC_STALE=1
        SYNC_DETAIL="last completed sync cycle was ${AGE_MIN}min ago: $LAST_CYCLE_LINE"
      elif echo "$LAST_CYCLE_LINE" | grep -q 'sync rc='; then
        SYNC_STALE=1
        SYNC_DETAIL="most recent sync cycle failed (${AGE_MIN}min ago): $LAST_CYCLE_LINE"
      else
        SYNC_DETAIL="last completed sync cycle ${AGE_MIN}min ago: OK"
      fi
    fi
  fi
fi

# --- baseline compare (rolling day-over-day; seed on first run) ---
if [ ! -f "$BASELINE" ]; then
  jq -n --arg date "$TS" --argjson brain_score "$BRAIN_SCORE" --argjson orphan_pages "$ORPHAN_PAGES" \
    --argjson embed_coverage "$EMBED_COVERAGE" --argjson dead_links "$DEAD_LINKS" --argjson page_count "$PAGE_COUNT" \
    '{date:$date, brain_score:$brain_score, orphan_pages:$orphan_pages, embed_coverage:$embed_coverage, dead_links:$dead_links, page_count:$page_count}' \
    > "$BASELINE"
  log "INFO: seeded baseline (brain_score=$BRAIN_SCORE orphan_pages=$ORPHAN_PAGES embed_coverage=$EMBED_COVERAGE dead_links=$DEAD_LINKS page_count=$PAGE_COUNT). $SYNC_DETAIL"
  exit 0
fi

BASE_SCORE="$(jq -r '.brain_score' "$BASELINE")"
BASE_ORPHANS="$(jq -r '.orphan_pages' "$BASELINE")"

ALERTS=()
SCORE_DROP=$(( BASE_SCORE - BRAIN_SCORE ))
if [ "$SCORE_DROP" -ge 3 ]; then
  ALERTS+=("brain_score dropped ${SCORE_DROP} (baseline=$BASE_SCORE -> now=$BRAIN_SCORE)")
fi
ORPHAN_RISE=$(( ORPHAN_PAGES - BASE_ORPHANS ))
if [ "$ORPHAN_RISE" -ge 10 ]; then
  ALERTS+=("orphan_pages rose by ${ORPHAN_RISE} (baseline=$BASE_ORPHANS -> now=$ORPHAN_PAGES)")
fi
if [ "$(echo "$EMBED_COVERAGE < 1.0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
  ALERTS+=("embed_coverage below 1.0 (now=$EMBED_COVERAGE)")
fi
if [ "$DEAD_LINKS" -gt 0 ]; then
  ALERTS+=("dead_links present (now=$DEAD_LINKS)")
fi
if [ "$SYNC_STALE" -eq 1 ]; then
  ALERTS+=("sync freshness: $SYNC_DETAIL")
fi

ALERT_FILE="$HOME/.gbrain/ALERT.json"

if [ "${#ALERTS[@]}" -gt 0 ]; then
  JOINED="$(printf '%s; ' "${ALERTS[@]}")"
  ALERT_MSG="gbrain sentinel ALERT: ${JOINED%; }"
  log "ALERT: $ALERT_MSG"
  echo "$ALERT_MSG"

  # Persist the alert so it survives until the metric actually recovers. The
  # SessionStart hook surfaces this into every Claude session, so an unread
  # logfile is no longer the only record.
  jq -n --arg ts "$TS" --arg msg "$ALERT_MSG" --argjson alerts "$(printf '%s\n' "${ALERTS[@]}" | jq -R . | jq -s .)" \
    '{first_seen:$ts, last_seen:$ts, message:$msg, alerts:$alerts}' > "$ALERT_FILE.new"
  if [ -f "$ALERT_FILE" ]; then
    jq -s '.[1] + {first_seen: .[0].first_seen}' "$ALERT_FILE" "$ALERT_FILE.new" > "$ALERT_FILE.tmp" && mv "$ALERT_FILE.tmp" "$ALERT_FILE"
    rm -f "$ALERT_FILE.new"
  else
    mv "$ALERT_FILE.new" "$ALERT_FILE"
  fi

  # Push notification — best effort, never fatal.
  TG_ENV="$HOME/.claude/channels/telegram/.env"
  if [ -f "$TG_ENV" ]; then
    TG_TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' "$TG_ENV" 2>/dev/null | cut -d= -f2- | tr -d '\n\"'"'"'')"
    TG_CHAT="27899391"
    if [ -n "$TG_TOKEN" ]; then
      curl -sS -m 10 -o /dev/null \
        --data-urlencode "chat_id=$TG_CHAT" \
        --data-urlencode "text=🧠 $ALERT_MSG" \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" 2>/dev/null \
        && log "  notified via Telegram" || log "  Telegram notify failed (non-fatal)"
    fi
  fi
  /usr/bin/osascript -e "display notification \"${JOINED%; }\" with title \"gbrain sentinel\"" 2>/dev/null || true

  # Baseline is NOT overwritten with the regressed numbers. It becomes a
  # best-known-good high-water mark, so a regression keeps alerting until it is
  # genuinely fixed rather than quietly becoming the new normal (which is what
  # happened on 2026-07-24: orphans 30 -> 113 alerted once, then never again).
  # To accept a new normal deliberately: rm ~/.gbrain/health-baseline.json
  jq -n --arg date "$TS" \
    --argjson brain_score "$(( BRAIN_SCORE > BASE_SCORE ? BRAIN_SCORE : BASE_SCORE ))" \
    --argjson orphan_pages "$(( ORPHAN_PAGES < BASE_ORPHANS ? ORPHAN_PAGES : BASE_ORPHANS ))" \
    --argjson embed_coverage "$EMBED_COVERAGE" --argjson dead_links "$DEAD_LINKS" --argjson page_count "$PAGE_COUNT" \
    '{date:$date, brain_score:$brain_score, orphan_pages:$orphan_pages, embed_coverage:$embed_coverage, dead_links:$dead_links, page_count:$page_count, note:"high-water mark; held during an active alert"}' \
    > "$BASELINE"
  log "  baseline HELD at best-known-good (brain_score>=$BASE_SCORE orphan_pages<=$BASE_ORPHANS) — will not absorb this regression"
else
  log "INFO: clean (brain_score=$BRAIN_SCORE orphan_pages=$ORPHAN_PAGES embed_coverage=$EMBED_COVERAGE dead_links=$DEAD_LINKS page_count=$PAGE_COUNT). $SYNC_DETAIL"
  if [ -f "$ALERT_FILE" ]; then
    log "  RESOLVED: clearing active alert (was: $(jq -r '.message' "$ALERT_FILE" 2>/dev/null))"
    rm -f "$ALERT_FILE"
  fi
  # Only a clean run advances the baseline.
  jq -n --arg date "$TS" --argjson brain_score "$BRAIN_SCORE" --argjson orphan_pages "$ORPHAN_PAGES" \
    --argjson embed_coverage "$EMBED_COVERAGE" --argjson dead_links "$DEAD_LINKS" --argjson page_count "$PAGE_COUNT" \
    '{date:$date, brain_score:$brain_score, orphan_pages:$orphan_pages, embed_coverage:$embed_coverage, dead_links:$dead_links, page_count:$page_count}' \
    > "$BASELINE"
fi

# --- weekly vault log, Sundays only ---
if [ "$(date -u +%u)" = "7" ]; then
  TODAY="$(date -u +%F)"
  EMBED_PCT="$(printf '%.0f' "$(echo "$EMBED_COVERAGE * 100" | bc -l 2>/dev/null || echo 0)")%"
  STATUS="OK"
  [ "${#ALERTS[@]}" -gt 0 ] && STATUS="ALERT"
  ROW="| $TODAY | $BRAIN_SCORE | $ORPHAN_PAGES | $EMBED_PCT | $DEAD_LINKS | $STATUS |"
  if [ ! -f "$VAULT_NOTE" ]; then
    mkdir -p "$(dirname "$VAULT_NOTE")"
    {
      echo "---"
      echo "type: health-log"
      echo "domain: ai"
      echo "created: $TODAY"
      echo "updated: $TODAY"
      echo "---"
      echo ""
      echo "# System/Brain Health Log"
      echo ""
      echo "Weekly gbrain knowledge-health snapshot, appended by \`ai.gbrain.doctor\` (\`gbrain-sentinel.sh\`) every Sunday. Daily checks run silently against a rolling baseline (\`~/.gbrain/health-baseline.json\`) and only surface here on the weekly cadence; see [[Second Brain Constitution]] § Knowledge-health check."
      echo ""
      echo "## Log"
      echo ""
      echo "| Date | Brain Score | Orphan Pages | Embed Coverage | Dead Links | Status |"
      echo "|------|-------------|--------------|-----------------|------------|--------|"
      echo "$ROW"
    } > "$VAULT_NOTE"
    log "INFO: created weekly vault log at $VAULT_NOTE"
  else
    sed -i '' "s/^updated: .*/updated: $TODAY/" "$VAULT_NOTE"
    echo "$ROW" >> "$VAULT_NOTE"
    log "INFO: appended weekly vault log row: $ROW"
  fi
fi

exit 0

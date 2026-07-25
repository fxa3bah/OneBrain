#!/usr/bin/env bash
# OneBrain — nightly lesson extraction.
#
# Scans the last 24h of agent transcripts READ-ONLY, asks a local model to find
# claims the assistant made that were later contradicted, and appends what it
# finds to the shared vault note. Every agent reads that note at session start.
#
# The whole design constraint: this must be UNABLE to die silently. The prior
# system (continuous-learning-v2) captured nothing for three months because its
# hooks lived in an uninstalled plugin and nothing reported the silence.
#
# So the heartbeat is written on EVERY exit path, including nights that find
# nothing and runs that fail. `ai.gbrain.doctor` alerts when it is missing, stale,
# errored, or reports 0 sessions scanned while transcripts were changing — the
# signature of a job that exits clean while observing nothing.
#
# Read-only w.r.t. other agents' directories: it reads their transcripts (allowed)
# and never writes to them (forbidden by the agent-isolation rule).
set -uo pipefail

source "$(dirname "$0")/onebrain-common.sh"
GBR="$GBRAIN_HOME"
HEARTBEAT="$GBR/heartbeats/lessons.json"
LOG="$GBR/logs/lessons.log"
MODEL="gemma3:4b"
MAX_CHARS=24000          # bound the prompt; a 4B model degrades on long input
LOCK="$GBR/lessons.lock.d"

mkdir -p "$GBR/heartbeats" "$GBR/logs"
TS="$(date -u +%FT%TZ)"
log(){ echo "$TS $*" >> "$LOG"; }

SESSIONS=0; FOUND=0; STATUS="error"; DETAIL=""
NOTE=""

# Heartbeat on EVERY exit path. This is the load-bearing line of the whole file.
finish(){
  # Escape detail for JSON (quotes/backslashes/newlines) so a path never breaks the file.
  local detail_json
  detail_json="$(printf '%s' "$DETAIL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null || printf '%s' "$DETAIL" | tr -d '"\\')"
  printf '{"ts":"%s","status":"%s","sessions_scanned":%d,"lessons_found":%d,"detail":"%s"}\n' \
    "$TS" "$STATUS" "$SESSIONS" "$FOUND" "$detail_json" > "$HEARTBEAT"
  log "done status=$STATUS sessions=$SESSIONS lessons=$FOUND note=${NOTE:-?} ${DETAIL:+detail=$DETAIL}"
  rmdir "$LOCK" 2>/dev/null
  exit 0
}
trap finish EXIT

if ! mkdir "$LOCK" 2>/dev/null; then STATUS="ok"; DETAIL="already running"; exit 0; fi

# Resolve write target BEFORE any work. A wrong default that still exits "ok"
# is the failure class the sentinel exists to prevent — the job runs, the
# heartbeat is green, and lessons land in a root-level orphan (or nowhere).
_resolve_err="$GBR/logs/lessons-resolve.err"
if ! NOTE="$(resolve_lessons_note 2>"$_resolve_err")"; then
  STATUS="error"
  DETAIL="lessons note unresolved: $(tr '\n' ' ' <"$_resolve_err" 2>/dev/null | head -c 200)"
  rm -f "$_resolve_err"
  exit 0
fi
rm -f "$_resolve_err"
export NOTE

# --- 1. collect transcripts changed in the last 24h -------------------------
TRANSCRIPTS="$(find "$HOME/.claude/projects" "$HOME/.codex/sessions" "$HOME/.grok/sessions" \
  -name '*.jsonl' -mtime -1 2>/dev/null | head -40)"
SESSIONS="$(printf '%s' "$TRANSCRIPTS" | grep -c . || true)"

if [ "$SESSIONS" -eq 0 ]; then
  STATUS="ok"; DETAIL="no transcripts changed in 24h"; exit 0
fi

# --- 2. pull recent user/assistant text, newest first, bounded --------------
CORPUS="$(printf '%s\n' "$TRANSCRIPTS" | while read -r f; do
  [ -f "$f" ] || continue
  tail -c 200000 "$f" 2>/dev/null | python3 -c "
import json,sys
for line in sys.stdin:
    try: d=json.loads(line)
    except Exception: continue
    m=d.get('message') or {}
    role=m.get('role') or d.get('type')
    if role not in ('user','assistant'): continue
    c=m.get('content')
    if isinstance(c,list):
        c=' '.join(b.get('text','') for b in c if isinstance(b,dict) and b.get('type')=='text')
    if not isinstance(c,str) or len(c.strip())<40: continue
    print(f\"{role.upper()}: {c.strip()[:600]}\")
" 2>/dev/null
done | tail -c "$MAX_CHARS")"

if [ -z "$CORPUS" ]; then
  STATUS="ok"; DETAIL="transcripts had no usable text"; exit 0
fi

# --- 3. local extraction (no cloud, no cost) --------------------------------
if ! curl -s -o /dev/null -m 5 http://localhost:11434/api/tags; then
  STATUS="error"; DETAIL="ollama unreachable"; exit 0
fi

PROMPT="Below is a transcript between a user and an AI assistant.

Find ONLY cases where the assistant stated something as fact that was later shown to be
wrong — contradicted by the user, by a command's output, or by the assistant itself.

For each, output exactly one line:
CLAIM: <what was asserted> | TRUTH: <what was actually true> | CAUSE: <why it went wrong, few words>

Rules:
- Output NOTHING if there are no such cases. Silence is the correct answer most nights.
- Do not invent. Only report contradictions visible in the text.
- Maximum 5 lines.

TRANSCRIPT:
$CORPUS"

RESP="$(printf '%s' "$PROMPT" | python3 -c "
import json,sys,urllib.request
p=sys.stdin.read()
try:
    r=urllib.request.urlopen(urllib.request.Request(
        'http://localhost:11434/api/generate',
        data=json.dumps({'model':'$MODEL','prompt':p,'stream':False,
                         'options':{'num_predict':400,'temperature':0}}).encode(),
        headers={'Content-Type':'application/json'}), timeout=300)
    print(json.load(r).get('response','').strip())
except Exception as e:
    print('EXTRACTION_ERROR:'+str(e)[:120])
")"

case "$RESP" in
  EXTRACTION_ERROR:*) STATUS="error"; DETAIL="${RESP#EXTRACTION_ERROR:}"; exit 0 ;;
esac

# --- 4. append findings to the vault ----------------------------------------
LESSONS="$(printf '%s\n' "$RESP" | grep -E '^CLAIM:' | head -5 || true)"
FOUND="$(printf '%s' "$LESSONS" | grep -c . || true)"

if [ "$FOUND" -gt 0 ]; then
  if [ ! -f "$NOTE" ]; then
    # Do not create a second note in a surprise location. Fresh installs should
    # seed the PARA path deliberately; upgrades must never invent a root orphan.
    STATUS="error"
    DETAIL="lessons found but note missing at $NOTE — create it or repin ONEBRAIN_LESSONS_NOTE"
    exit 0
  fi
  if ! printf '%s\n' "$LESSONS" | python3 -c "
import sys,os,datetime,re
note=os.environ['NOTE']; date=datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%d')
lines=[]
for raw in sys.stdin:
    m=re.match(r'CLAIM:\s*(.*?)\s*\|\s*TRUTH:\s*(.*?)\s*\|\s*CAUSE:\s*(.*)', raw.strip())
    if m: lines.append(f'- \`{date} | {m.group(1)} | {m.group(2)} | {m.group(3)}\`')
if lines:
    with open(note,'a') as f: f.write('\n'.join(lines)+'\n')
"; then
    STATUS="error"; DETAIL="failed appending to $NOTE"; exit 0
  fi
  "$GBR/bin/onebrain-notify.sh" "$FOUND new lesson(s) captured from $SESSIONS session(s). See $NOTE" "OneBrain lessons" 2>/dev/null || true
  STATUS="ok"; DETAIL="appended to $NOTE"; exit 0
fi

STATUS="ok"; DETAIL="note=$NOTE"
exit 0

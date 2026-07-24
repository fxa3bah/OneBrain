#!/usr/bin/env bash
# OneBrain — agent discovery and gbrain wiring.
#
# Detects every AI agent CLI installed on this Mac, reports whether each one can
# actually reach the shared brain, and wires the ones that cannot.
#
# Why this exists: on 2026-07-24 an audit found OneBrain.md claiming
# "Claude · Codex · Grok · Hermes (all wired)" while Claude Code had zero MCP
# servers configured and no occurrence of "gbrain" anywhere in its config. Nine
# of twelve installed agents could not reach the brain their instruction files
# told them was the source of truth. Config claims drifted from reality because
# nothing checked. This script is the check.
#
# Usage:
#   onebrain-agents.sh            # report only (default, read-only)
#   onebrain-agents.sh --wire     # wire any unwired agent it knows how to wire
#   onebrain-agents.sh --json     # machine-readable status
#
# Safety: never writes without --wire; always backs up a config before editing;
# only ever touches the gbrain entry, never another server's config. Editing
# another agent's config is normally forbidden by the agent-isolation rule —
# OneBrain memory wiring is Fahd's explicit, and only, exclusion to that rule.
set -uo pipefail

URL="http://127.0.0.1:3131/mcp"
TOKEN_VAR="GBRAIN_REMOTE_TOKEN"
WIRE=0; JSON=0
for a in "$@"; do
  case "$a" in
    --wire) WIRE=1 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  esac
done

ts()   { date +%Y%m%d-%H%M%S; }
back() { [ -f "$1" ] && cp "$1" "$1.bak-gbrain-$(ts)"; }

ROWS=()   # name|installed|config|wired|action

record() { ROWS+=("$1|$2|$3|$4|$5"); }

have() { command -v "$1" >/dev/null 2>&1; }

# --- JSON mcpServers agents (Claude Code, Cursor, Qoder, QoderWork) ----------
wire_json_mcp() {
  local name="$1" file="$2" wired action="not wired"
  [ -f "$file" ] || { record "$name" yes "$file (missing)" no "config absent"; return; }
  wired="$(python3 - "$file" <<'PY'
import json,sys,re
try:
    raw=open(sys.argv[1]).read()
    raw=re.sub(r'^\s*//.*$','',raw,flags=re.M)          # tolerate jsonc
    d=json.loads(raw)
except Exception: print("err"); raise SystemExit
srv=d.get("mcpServers", d if all(isinstance(v,dict) for v in d.values()) else {})
print("yes" if any("gbrain"==k.lower() for k in srv) else "no")
PY
)"
  if [ "$wired" = "yes" ]; then record "$name" yes "$file" yes "already wired"; return; fi
  if [ "$WIRE" -eq 0 ]; then record "$name" yes "$file" no "would wire (--wire)"; return; fi
  back "$file"
  python3 - "$file" "$URL" "$TOKEN_VAR" <<'PY'
import json,sys,re,os
p,url,var=sys.argv[1],sys.argv[2],sys.argv[3]
raw=open(p).read(); raw2=re.sub(r'^\s*//.*$','',raw,flags=re.M)
d=json.loads(raw2)
top = "mcpServers" if "mcpServers" in d else None
entry={"type":"http","url":url,"headers":{"Authorization":"Bearer ${%s}"%var}}
if top: d[top]["gbrain"]=entry
else: d["gbrain"]=entry            # Warp-style flat map
tmp=p+".tmp"; json.dump(d,open(tmp,"w"),indent=2); os.replace(tmp,p)
PY
  [ $? -eq 0 ] && action="WIRED" || action="wire FAILED"
  record "$name" yes "$file" no "$action"
}

# --- TOML mcp_servers agents (Codex, Grok) ----------------------------------
wire_toml_mcp() {
  local name="$1" file="$2"
  [ -f "$file" ] || { record "$name" yes "$file (missing)" no "config absent"; return; }
  if grep -q '^\[mcp_servers\.gbrain\]' "$file" 2>/dev/null; then
    record "$name" yes "$file" yes "already wired"; return
  fi
  if [ "$WIRE" -eq 0 ]; then record "$name" yes "$file" no "would wire (--wire)"; return; fi
  back "$file"
  printf '\n[mcp_servers.gbrain]\nurl = "%s"\nbearer_token_env_var = "%s"\nenabled = true\n' "$URL" "$TOKEN_VAR" >> "$file"
  record "$name" yes "$file" no "WIRED"
}

# ---------------------------------------------------------------------------
detect() {
  have claude       && wire_json_mcp "claude-code" "$HOME/.claude.json"            || record "claude-code" no - - "not installed"
  have codex        && wire_toml_mcp "codex"       "$HOME/.codex/config.toml"      || record "codex" no - - "not installed"
  have grok         && wire_toml_mcp "grok"        "$HOME/.grok/config.toml"       || record "grok" no - - "not installed"
  have cursor-agent && wire_json_mcp "cursor"      "$HOME/.cursor/mcp.json"        || record "cursor" no - - "not installed"
  have qodercli     && wire_json_mcp "qoder"       "$HOME/.qoder/mcp.json"         || record "qoder" no - - "not installed"
  [ -f "$HOME/.qoderwork/mcp.json" ] && wire_json_mcp "qoderwork" "$HOME/.qoderwork/mcp.json"
  [ -f "$HOME/.warp/mcp.json" ]      && wire_json_mcp "warp"      "$HOME/.warp/mcp.json"

  # Agents whose wiring is deliberately NOT automated:
  #   hermes  — already wired in config.yaml; ~/.hermes is off-limits per isolation rule
  #   agy/gemini, opencode — no verified MCP schema on this machine; wiring blind risks
  #                          corrupting a working config, which is exactly the failure
  #                          the isolation rule was written after.
  have hermes   && record "hermes"   yes "~/.hermes/config.yaml" yes "wired (managed by Hermes, not touched)"
  have agy      && record "agy"      yes "~/.gemini/" no "MANUAL — MCP schema unverified"
  have opencode && record "opencode" yes "~/.config/opencode/opencode.jsonc" no "MANUAL — MCP schema unverified"
}

detect

if [ "$JSON" -eq 1 ]; then
  printf '['; first=1
  for r in "${ROWS[@]}"; do
    IFS='|' read -r n i c w a <<<"$r"
    [ $first -eq 0 ] && printf ','; first=0
    printf '{"agent":"%s","installed":"%s","config":"%s","wired":"%s","action":"%s"}' "$n" "$i" "$c" "$w" "$a"
  done
  printf ']\n'
else
  printf '\n%-12s %-10s %-9s %s\n' "AGENT" "INSTALLED" "WIRED" "ACTION"
  printf '%s\n' "------------------------------------------------------------------"
  for r in "${ROWS[@]}"; do
    IFS='|' read -r n i c w a <<<"$r"
    printf '%-12s %-10s %-9s %s\n' "$n" "$i" "$w" "$a"
  done
  echo
  [ "$WIRE" -eq 0 ] && echo "Report only. Re-run with --wire to apply. Backups are written next to each config."
fi

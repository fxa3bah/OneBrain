#!/usr/bin/env bash
# OneBrain — interactive setup. Asks for what it needs, then PROVES each answer works.
#
# Why this exists: the installer used to ask nothing. It created directories and
# loaded services, and left the user to hand-edit .env.example. People ended up with
# a working brain and silently no alerts — a config that exists but does not work.
# That is the same failure this project's watchdog was built to prevent, reproduced
# at the install layer.
#
# So every value is verified, not just collected:
#   vault      -> directory exists AND is a git repo (sync depends on git)
#   gbrain     -> src/cli.ts is actually there
#   Ollama     -> reachable AND the embedding model is pulled
#   tokens     -> generated for you; no reason to make a human invent random strings
#   Telegram   -> a real message is SENT and you must confirm you received it
#
# Idempotent: anything already configured is left alone. Safe to re-run.
# Non-interactive (CI, no TTY): reports what is missing and exits 1 without prompting.
set -uo pipefail

SECRETS="$HOME/.secrets/.env"
NOTIFY="$HOME/.onebrain/notify.env"
INTERACTIVE=1
[ -t 0 ] || INTERACTIVE=0
[ "${1:-}" = "--non-interactive" ] && INTERACTIVE=0

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$*"; }

mkdir -p "$(dirname "$SECRETS")" "$(dirname "$NOTIFY")"
touch "$SECRETS"; chmod 600 "$SECRETS"

get(){ grep "^$1=" "$SECRETS" 2>/dev/null | cut -d= -f2- | tr -d '\n"'"'"''; }
put(){ # put KEY VALUE — replace or append, preserving mode.
  # No-op when the value is already correct, so re-running never rewrites or
  # reorders the file. Idempotence has to be real, not approximate: this is a
  # 600-mode secrets file that other tools read, and churning it on every run
  # invites exactly the kind of silent drift this project keeps finding.
  local k="$1" v="$2" tmp
  [ "$(get "$k")" = "$v" ] && return 0
  tmp="$(mktemp)"
  grep -v "^$k=" "$SECRETS" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  cat "$tmp" > "$SECRETS"; rm -f "$tmp"; chmod 600 "$SECRETS"
}
ask(){ # ask PROMPT DEFAULT -> stdout
  local p="$1" d="${2:-}" a
  if [ "$INTERACTIVE" -eq 0 ]; then printf '%s' "$d"; return; fi
  if [ -n "$d" ]; then read -r -p "  $p [$d]: " a </dev/tty; printf '%s' "${a:-$d}"
  else read -r -p "  $p: " a </dev/tty; printf '%s' "$a"; fi
}

MISSING=0
need(){ bad "$1"; MISSING=1; }

echo; bold "OneBrain setup"
echo "  Every answer is verified before it is saved. Re-run any time."
echo

# ---------------------------------------------------------------- vault -----
bold "1/5  Obsidian vault — your source of truth"
VAULT="$(get OBSIDIAN_VAULT_PATH)"
while :; do
  [ -n "$VAULT" ] || VAULT="$(ask 'Absolute path to your vault' "$HOME/Obsidian/YourVault")"
  VAULT="${VAULT/#\~/$HOME}"
  if [ ! -d "$VAULT" ]; then
    bad "no directory at: $VAULT"
    [ "$INTERACTIVE" -eq 0 ] && { need "set OBSIDIAN_VAULT_PATH in $SECRETS"; break; }
    VAULT=""; continue
  fi
  if [ ! -e "$VAULT/.git" ]; then
    warn "not a git repo — the 5-min sync loop needs git to detect changes"
    if [ "$INTERACTIVE" -eq 1 ] && [ "$(ask 'run git init there now? (y/n)' y)" = "y" ]; then
      (cd "$VAULT" && git init -q && git add -A && git commit -qm "initial vault import") && ok "initialised"
    else
      need "vault must be a git repo"; break
    fi
  fi
  ok "vault: $VAULT ($(find "$VAULT" -name '*.md' -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ') notes)"
  put OBSIDIAN_VAULT_PATH "$VAULT"

  # Pin the shared lessons note. Prefer an existing Agent Lessons.md anywhere in
  # the vault over a vault-root default that would orphan the real note on upgrade.
  export OBSIDIAN_VAULT_PATH="$VAULT"
  # shellcheck source=../bin/onebrain-common.sh
  # Resolve using the repo copy (setup can run before install copies wrappers).
  _COMMON="$(cd "$(dirname "$0")/.." && pwd)/bin/onebrain-common.sh"
  if [ -f "$_COMMON" ]; then
    # shellcheck disable=SC1090
    source "$_COMMON"
    _lessons_err="$(mktemp)"
    if LESSONS_NOTE="$(pin_lessons_note 2>"$_lessons_err")"; then
      ok "lessons note: $LESSONS_NOTE"
    else
      bad "could not resolve Agent Lessons.md"
      [ -s "$_lessons_err" ] && sed 's/^/     /' "$_lessons_err"
      need "set ONEBRAIN_LESSONS_NOTE or create the PARA-path note under the vault"
    fi
    rm -f "$_lessons_err"
  fi
  break
done

# --------------------------------------------------------------- gbrain -----
echo; bold "2/5  gbrain checkout — the brain itself"
REPO="$(get GBRAIN_REPO)"
while :; do
  [ -n "$REPO" ] || REPO="$(ask 'Path to your gbrain clone' "$HOME/Code/gbrain")"
  REPO="${REPO/#\~/$HOME}"
  if [ ! -f "$REPO/src/cli.ts" ]; then
    bad "no src/cli.ts under: $REPO"
    echo "     git clone https://github.com/garrytan/gbrain $REPO && cd $REPO && bun install"
    [ "$INTERACTIVE" -eq 0 ] && { need "set GBRAIN_REPO in $SECRETS"; break; }
    REPO=""; continue
  fi
  ok "gbrain: $REPO"
  put GBRAIN_REPO "$REPO"; break
done

# --------------------------------------------------------------- tokens -----
echo; bold "3/5  Auth tokens — generated, not typed"
for k in GBRAIN_ADMIN_BOOTSTRAP_TOKEN GBRAIN_REMOTE_TOKEN; do
  if [ -n "$(get $k)" ]; then ok "$k already set"
  else put "$k" "gbrain_$(openssl rand -hex 32)"; ok "$k generated"; fi
done

# --------------------------------------------------------------- Ollama -----
echo; bold "4/5  Ollama — local embeddings, so nothing leaves this machine"
if ! curl -s -o /dev/null -m 5 http://localhost:11434/api/tags; then
  bad "Ollama not reachable on :11434 — install from https://ollama.com and start it"
  MISSING=1
elif ! curl -s -m 5 http://localhost:11434/api/tags | grep -q 'nomic-embed-text'; then
  bad "embedding model missing"
  if [ "$INTERACTIVE" -eq 1 ] && [ "$(ask 'pull nomic-embed-text now? (~274MB) (y/n)' y)" = "y" ]; then
    ollama pull nomic-embed-text && ok "pulled" || MISSING=1
  else MISSING=1; fi
else
  ok "Ollama up, nomic-embed-text present"
fi

# ------------------------------------------------------------- Telegram -----
echo; bold "5/5  Alerts (optional) — how OneBrain reaches you when the brain degrades"
if [ -f "$NOTIFY" ] && grep -q '^TELEGRAM_CHAT_ID=.\+' "$NOTIFY" 2>/dev/null; then
  ok "notifications already configured ($NOTIFY)"
elif [ "$INTERACTIVE" -eq 0 ]; then
  warn "skipped (non-interactive). Configure later: $NOTIFY"
elif [ "$(ask 'Set up Telegram alerts? (y/n)' y)" != "y" ]; then
  warn "skipped — macOS notifications and the log still work"
else
  cat <<'EOF'

  Two values, both from Telegram itself:
    1. BOT TOKEN — message @BotFather, send /newbot, follow the prompts.
                   It replies with a token like 123456789:AAE...
    2. CHAT ID   — message @userinfobot; it replies with your numeric ID.
                   For a group, forward one of its messages to @userinfobot
                   (group IDs are negative).

EOF
  TOK="$(ask 'Bot token')"; CID="$(ask 'Chat ID')"
  if [ -n "$TOK" ] && [ -n "$CID" ]; then
    printf '# OneBrain notifier. chmod 600. Never commit.\nTELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' \
      "$TOK" "$CID" > "$NOTIFY"
    chmod 600 "$NOTIFY"

    # PROVE it. A token that is present and a token that works are different states.
    echo; echo "  Sending a test message..."
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
      --data-urlencode "chat_id=$CID" \
      --data-urlencode "text=✅ OneBrain is connected. You will get alerts here when the brain degrades." \
      "https://api.telegram.org/bot${TOK}/sendMessage")"
    if [ "$CODE" != "200" ]; then
      bad "Telegram rejected it (HTTP $CODE) — check the token and chat ID, then re-run"
      MISSING=1
    elif [ "$(ask 'Did you receive it? (y/n)' y)" = "y" ]; then
      ok "alerts verified end to end"
    else
      bad "sent but not received — usually a wrong chat ID, or you have not messaged the bot first"
      warn "open your bot in Telegram, send it /start, then re-run this script"
      MISSING=1
    fi
  else
    warn "skipped — both values are required"
  fi
fi

echo
if [ "$MISSING" -ne 0 ]; then
  bold "Setup incomplete — fix the ✗ items above and re-run."
  exit 1
fi
bold "Setup complete."
echo "  Next:  ./install.sh          (add --enrichment for the nightly self-tidy)"
echo "  Then:  tools/onebrain-agents.sh --wire   (point your agents at the brain)"
exit 0

#!/usr/bin/env bash
# OneBrain — block personal data from reaching a public repo.
#
# This exists because it already happened: a maintainer's Telegram user ID and
# macOS username were committed and pushed. The pre-push scan that was run looked
# for token-SHAPED strings (sk-, ghp_, AKIA, bearer) and known personal strings.
# A bare 8-digit identifier matched none of them. Wrong shape, so it sailed through.
#
# The lesson generalises: scanning for "things that look like secrets" misses
# identifiers, usernames, and paths. So this checks for the CLASS of thing —
# anything machine-specific — rather than a list of known-bad values.
#
# Usage:
#   scripts/check-no-personal-data.sh          # scan tracked files
#   scripts/check-no-personal-data.sh --staged # scan staged changes (pre-commit)
#
# Install as a hook:
#   ln -sf ../../scripts/check-no-personal-data.sh .git/hooks/pre-commit
#
# Exits non-zero on a finding, so it blocks the commit.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 0

MODE="${1:-tracked}"
FAIL=0

if [ "$MODE" = "--staged" ]; then
  FILES="$(git diff --cached --name-only --diff-filter=ACM)"
  read_file(){ git show ":$1" 2>/dev/null; }
else
  FILES="$(git ls-files)"
  read_file(){ cat "$1" 2>/dev/null; }
fi

report(){ echo "  [$1] $2"; FAIL=1; }

for f in $FILES; do
  case "$f" in
    *.png|*.jpg|*.gif|*.pdf|scripts/check-no-personal-data.sh) continue ;;
  esac
  C="$(read_file "$f")"
  [ -n "$C" ] || continue

  # 1. Absolute home paths — leaks a username AND breaks every other machine.
  #    LaunchAgent plists must use the __HOME__ placeholder the installer substitutes.
  echo "$C" | grep -qE '/(Users|home)/[a-z][a-z0-9_-]{1,30}/' \
    && report "HOME PATH" "$f — use \$HOME (scripts) or __HOME__ (plists), never a literal path"

  # 2. Telegram identifiers. Chat IDs are bare integers, which is exactly why the
  #    original scan missed one. Bot tokens are <digits>:<35 chars>.
  echo "$C" | grep -qE '(chat_id|CHAT_ID|TG_CHAT)[[:space:]]*=[[:space:]]*"?-?[0-9]{6,}' \
    && report "TELEGRAM ID" "$f — hardcoded chat ID; read it from config at runtime"
  echo "$C" | grep -qE '[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}' \
    && report "TELEGRAM TOKEN" "$f — bot token"

  # 3. Credential shapes.
  echo "$C" | grep -qE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|gbrain_[0-9a-f]{40,})' \
    && report "CREDENTIAL" "$f"
  echo "$C" | grep -qE '(API_TOKEN|api_key|password|secret)[[:space:]]*=[[:space:]]*"?[A-Za-z0-9_-]{16,}' \
    && report "INLINE SECRET" "$f — read from ~/.secrets/.env at runtime"

  # 4. Private network detail.
  echo "$C" | grep -qE '\b(192\.168|10\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[01])\.)[0-9.]+' \
    && report "PRIVATE IP" "$f"

  # 5. Real email addresses (example.com and placeholders are fine).
  echo "$C" | grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    && ! echo "$C" | grep -qE '@(example|yourdomain|placeholder)\.' \
    && report "EMAIL" "$f — verify it is not a real personal address"
done

if [ "$FAIL" -ne 0 ]; then
  cat <<'EOF'

BLOCKED: machine-specific or personal data found above.

This repo is public. Every value must come from config at runtime:
  paths    -> $HOME in scripts, __HOME__ in plists (installer substitutes it)
  secrets  -> ~/.secrets/.env via read_secret in onebrain-common.sh
  Telegram -> ~/.onebrain/notify.env, never hardcoded

Override for a genuine false positive:  git commit --no-verify
EOF
  exit 1
fi

echo "clean: no personal or machine-specific data found"
exit 0

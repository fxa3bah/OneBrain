#!/bin/bash
# OneBrain — shared config sourced by every wrapper.
# All machine-specific values come from env / ~/.secrets/.env, never hardcoded.

# PATH: bun + homebrew + node + system. Adjust if your toolchain lives elsewhere.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SECRETS_ENV="${SECRETS_ENV:-$HOME/.secrets/.env}"

# Read a single KEY=value from the secrets file without sourcing the whole thing
# (so unrelated keys like OPENAI_API_KEY never enter the process).
read_secret() { grep "^$1=" "$SECRETS_ENV" 2>/dev/null | cut -d= -f2- | tr -d '\n' | tr -d '"' | tr -d "'"; }

# Core paths — override via env or ~/.secrets/.env
OBSIDIAN_VAULT_PATH="${OBSIDIAN_VAULT_PATH:-$(read_secret OBSIDIAN_VAULT_PATH)}"
OBSIDIAN_VAULT_PATH="${OBSIDIAN_VAULT_PATH:-$HOME/Obsidian/YourVault}"
GBRAIN_REPO="${GBRAIN_REPO:-$(read_secret GBRAIN_REPO)}"
GBRAIN_REPO="${GBRAIN_REPO:-$HOME/Code/gbrain}"
# Optional pin for the shared lessons note. Prefer this over discovery when set.
ONEBRAIN_LESSONS_NOTE="${ONEBRAIN_LESSONS_NOTE:-$(read_secret ONEBRAIN_LESSONS_NOTE)}"

GBRAIN_HOME="${GBRAIN_HOME:-$HOME/.gbrain}"
GBRAIN_CLI="$GBRAIN_REPO/src/cli.ts"
GBRAIN_PORT="${GBRAIN_PORT:-3131}"
UID_N="$(id -u)"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
SERVE_PLIST="$LAUNCH_DIR/ai.gbrain.server.plist"

# PARA default for the shared Agent Lessons note (vault-relative).
# Never default to vault-root "Agent Lessons.md" — that path orphans the real
# note on any vault that already keeps it under 30 Areas/ (or elsewhere).
ONEBRAIN_LESSONS_PARA_REL="30 Areas/AI & Systems/Agent Lessons.md"

# Resolve the shared Agent Lessons note. Prints absolute path on stdout.
# Exit 0 on success; exit 1 and print reason on stderr on hard failure.
#
# Rules (upgrade-safe, non-destructive):
#   1. If ONEBRAIN_LESSONS_NOTE is set and the file exists → use it.
#   2. If it is set, missing, and another "Agent Lessons.md" exists in the vault
#      → REFUSE. Writing the pin would orphan the real note (silent split-brain).
#   3. If unset: discover every "Agent Lessons.md" under the vault.
#        - exactly one → use it
#        - several → use only the exact PARA path when present; otherwise refuse
#          (ambiguous)
#        - none → return the PARA default path (caller may create on first write)
#   4. Never invent a vault-root default when a real candidate exists elsewhere.
resolve_lessons_note() {
  local vault="${OBSIDIAN_VAULT_PATH:-}"
  local pinned="${ONEBRAIN_LESSONS_NOTE:-}"
  local para
  local -a found=()
  local f

  if [ -z "$vault" ] || [ ! -d "$vault" ]; then
    echo "resolve_lessons_note: OBSIDIAN_VAULT_PATH missing or not a directory: ${vault:-<empty>}" >&2
    return 1
  fi

  para="$vault/$ONEBRAIN_LESSONS_PARA_REL"
  # Collect existing notes (null-safe; skip .git).
  while IFS= read -r -d '' f; do
    found+=("$f")
  done < <(find "$vault" -name 'Agent Lessons.md' -not -path '*/.git/*' -print0 2>/dev/null)

  if [ -n "$pinned" ]; then
    if [ -f "$pinned" ]; then
      printf '%s\n' "$pinned"
      return 0
    fi
    # Pin points at a missing file. If another real note exists, refuse — do not
    # create a second note at the pin and split the log.
    if [ "${#found[@]}" -gt 0 ]; then
      echo "resolve_lessons_note: ONEBRAIN_LESSONS_NOTE is set to a missing path:" >&2
      echo "  pin: $pinned" >&2
      echo "  existing note(s) in vault:" >&2
      for f in "${found[@]}"; do echo "    $f" >&2; done
      echo "  Fix: set ONEBRAIN_LESSONS_NOTE to the existing note (or unset it) and re-run setup." >&2
      return 1
    fi
    # Fresh pin for a path that does not exist yet (no other candidates).
    printf '%s\n' "$pinned"
    return 0
  fi

  case "${#found[@]}" in
    0)
      # Greenfield: PARA path is the only default. Not vault root.
      printf '%s\n' "$para"
      return 0
      ;;
    1)
      printf '%s\n' "${found[0]}"
      return 0
      ;;
    *)
      # Multiple matches are unsafe to infer. Only the documented PARA path is
      # deterministic; choosing the first find result could silently pin a
      # different note and leave the real lessons stream orphaned.
      for f in "${found[@]}"; do
        if [ "$f" = "$para" ]; then
          printf '%s\n' "$f"
          return 0
        fi
      done
      echo "resolve_lessons_note: multiple Agent Lessons.md files, none at the exact PARA path:" >&2
      for f in "${found[@]}"; do echo "  $f" >&2; done
      echo "  Set ONEBRAIN_LESSONS_NOTE explicitly to the one that should receive appends." >&2
      return 1
      ;;
  esac
}

# Pin ONEBRAIN_LESSONS_NOTE into ~/.secrets/.env after resolving.
# Idempotent: no-op when the value is already correct. Never rewrites other keys'
# order beyond put-style replace (same pattern as scripts/onebrain-setup.sh).
# Prints the pinned path on stdout. Exit 1 if resolution fails.
pin_lessons_note() {
  local note secrets="${SECRETS_ENV:-$HOME/.secrets/.env}" tmp
  note="$(resolve_lessons_note)" || return 1

  mkdir -p "$(dirname "$secrets")"
  touch "$secrets"; chmod 600 "$secrets"

  if grep -q "^ONEBRAIN_LESSONS_NOTE=" "$secrets" 2>/dev/null; then
    local cur
    cur="$(grep "^ONEBRAIN_LESSONS_NOTE=" "$secrets" | cut -d= -f2- | tr -d '\n"'"'"'')"
    if [ "$cur" = "$note" ]; then
      printf '%s\n' "$note"
      return 0
    fi
    tmp="$(mktemp)"
    grep -v "^ONEBRAIN_LESSONS_NOTE=" "$secrets" > "$tmp" || true
    printf 'ONEBRAIN_LESSONS_NOTE=%s\n' "$note" >> "$tmp"
    cat "$tmp" > "$secrets"; rm -f "$tmp"; chmod 600 "$secrets"
  else
    printf 'ONEBRAIN_LESSONS_NOTE=%s\n' "$note" >> "$secrets"
    chmod 600 "$secrets"
  fi

  ONEBRAIN_LESSONS_NOTE="$note"
  printf '%s\n' "$note"
}

#!/usr/bin/env bash
# Regression tests for lesson-note discovery and upgrade pinning.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$REPO_DIR/bin/onebrain-common.sh"
INSTALLER="$REPO_DIR/install.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }

run_common() {
  local vault="$1" secrets="$2" command="$3"
  HOME="$TMP_DIR/home" \
  SECRETS_ENV="$secrets" \
  OBSIDIAN_VAULT_PATH="$vault" \
  bash -c 'source "$1"; eval "$2"' _ "$COMMON" "$command"
}

# An existing nested note must be discovered and persisted before an upgrade copies
# the new lessons wrapper. This prevents a silent root-level split brain.
VAULT="$TMP_DIR/vault"
SECRETS="$TMP_DIR/secrets.env"
NOTE="$VAULT/30 Areas/AI & Systems/Agent Lessons.md"
mkdir -p "$(dirname "$NOTE")"
touch "$NOTE"

resolved="$(run_common "$VAULT" "$SECRETS" 'resolve_lessons_note')"
assert_eq "$resolved" "$NOTE"
pinned="$(run_common "$VAULT" "$SECRETS" 'pin_lessons_note')"
assert_eq "$pinned" "$NOTE"
grep -Fx "ONEBRAIN_LESSONS_NOTE=$NOTE" "$SECRETS" >/dev/null || fail "nested note was not persisted"

# A stale explicit pin plus a real note must fail closed, not create a second note.
printf 'ONEBRAIN_LESSONS_NOTE=%s\n' "$VAULT/Agent Lessons.md" > "$SECRETS"
if run_common "$VAULT" "$SECRETS" 'resolve_lessons_note' >/dev/null 2>&1; then
  fail "stale explicit pin unexpectedly resolved"
fi

# The installer must invoke the pinning step before it copies wrappers or loads agents.
pin_line="$(grep -n 'pin_lessons_note' "$INSTALLER" | head -n 1 | cut -d: -f1)"
copy_line="$(grep -n 'cp "\$REPO_DIR"/bin/\*.sh' "$INSTALLER" | head -n 1 | cut -d: -f1)"
[ -n "$pin_line" ] || fail "install.sh does not pin the lessons note"
[ -n "$copy_line" ] || fail "install.sh does not copy wrappers"
[ "$pin_line" -lt "$copy_line" ] || fail "install.sh pins after copying wrappers"

echo "ok: lessons note discovery and upgrade pinning"

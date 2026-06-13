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

GBRAIN_HOME="${GBRAIN_HOME:-$HOME/.gbrain}"
GBRAIN_CLI="$GBRAIN_REPO/src/cli.ts"
GBRAIN_PORT="${GBRAIN_PORT:-3131}"
UID_N="$(id -u)"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
SERVE_PLIST="$LAUNCH_DIR/ai.gbrain.server.plist"

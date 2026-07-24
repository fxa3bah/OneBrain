#!/bin/bash
TOK="$(grep '^GBRAIN_REMOTE_TOKEN=' "$HOME/.secrets/.env" 2>/dev/null | cut -d= -f2- | tr -d '\n' | tr -d '"' | tr -d "'")"
[ -n "$TOK" ] && /bin/launchctl setenv GBRAIN_REMOTE_TOKEN "$TOK"

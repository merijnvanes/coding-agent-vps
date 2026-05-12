#!/usr/bin/env bash
# sandbox/entrypoint.sh — container entrypoint
#
# Sources env-export files written by cred-daemon (CLOUDFLARE_API_TOKEN,
# HCLOUD_TOKEN, etc.) and then exec's into the user's chosen command
# (default: tmux).
#
# Footgun: env vars are sourced at *shell start*. If cred-daemon rotates
# the token while a shell is running, that shell keeps the stale value
# until you re-source or detach/reattach tmux.

set -euo pipefail

# Source any *.sh in /run/agent-env (mounted read-only from the creds zone)
if [[ -d /run/agent-env ]]; then
  shopt -s nullglob
  for f in /run/agent-env/*.sh; do
    # shellcheck source=/dev/null
    source "$f"
  done
fi

# Point ssh-agent at the forwarded socket
export SSH_AUTH_SOCK=/run/sockets/ssh-agent.sock

# Hand off to the user's command (default: tmux new-session)
if [[ $# -eq 0 ]]; then
  exec tmux new-session -A -s main
else
  exec "$@"
fi

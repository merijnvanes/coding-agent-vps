#!/usr/bin/env bash
# sandbox/entrypoint.sh — container entrypoint
#
# Env-export files (CLOUDFLARE_API_TOKEN, HCLOUD_TOKEN, PyPI, Docker Hub)
# are sourced via /etc/profile.d/agent-env.sh (installed by the Dockerfile),
# which is read by every interactive bash login shell — including new tmux
# windows. That way a rotation that updates the file on disk reaches the
# next new shell without restarting the container.
#
# This entrypoint just sets SSH_AUTH_SOCK and hands off to the user's
# command. Default command: tmux new-session (attached) so the user lands
# in a session that survives docker exec disconnects.

set -euo pipefail

export SSH_AUTH_SOCK=/run/sockets/ssh-agent.sock

if [[ $# -eq 0 ]]; then
  exec tmux new-session -A -s main
else
  exec "$@"
fi

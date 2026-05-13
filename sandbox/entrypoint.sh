#!/usr/bin/env bash
# sandbox/entrypoint.sh — container entrypoint
#
# Env-export files (CLOUDFLARE_API_TOKEN, HCLOUD_TOKEN, PyPI tokens)
# are sourced via /etc/profile.d/agent-env.sh (installed by the Dockerfile),
# which is read by every interactive bash login shell — including new tmux
# windows. That way a rotation that updates the file on disk reaches the
# next new shell without restarting the container.
#
# This entrypoint just sets SSH_AUTH_SOCK and hands off to the user's
# command. Default command: tmux new-session (attached) so the user lands
# in a session that survives docker exec disconnects.

set -euo pipefail

# Use the socat-bridged socket (not the raw ssh-agent socket). ssh-agent's
# kernel-level peer-UID check rejects direct connections from the sandbox
# because rootless Docker maps the container's `agent` user (UID 1000) to
# host UID 100999, which doesn't match ssh-agent's UID (999, `creds`).
# See daemon/ssh-agent-bridge.service for the rationale.
export SSH_AUTH_SOCK=/run/sockets/ssh-agent-bridge.sock

# Claude Code stores its active config at ~/.claude.json (outside the
# persisted ~/.claude/ volume) but writes backups INTO ~/.claude/backups/
# (inside the volume). Container rebuilds wipe the active file but leave
# the backups. Auto-restore from the most recent backup so users don't
# have to re-init after every `docker compose up -d --build`.
if [[ ! -f "$HOME/.claude.json" && -d "$HOME/.claude/backups" ]]; then
  latest_backup=$(ls -1t "$HOME/.claude/backups/.claude.json.backup."* 2>/dev/null | head -1)
  if [[ -n "$latest_backup" ]]; then
    cp "$latest_backup" "$HOME/.claude.json"
    echo "[entrypoint] restored ~/.claude.json from $(basename "$latest_backup")" >&2
  fi
fi

if [[ $# -eq 0 ]]; then
  exec tmux new-session -A -s main
else
  exec "$@"
fi

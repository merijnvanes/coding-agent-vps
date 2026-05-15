#!/usr/bin/env bash
# sandbox/entrypoint.sh — container entrypoint
#
# Non-secret sandbox config (INFISICAL_TOOLING_PROJECT_ID + INFISICAL_ENV
# in sandbox-config.sh) is sourced via /etc/profile.d/agent-env.sh, which
# is read by every interactive bash login shell (including new tmux
# windows). The PATH shims at /opt/agent-vps-wrappers/ then use those env
# vars to invoke `infisical run --` per command. Cloud-CLI tokens
# themselves never enter any persistent shell env — they live in the
# subprocess env of one command at a time.
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

if [[ $# -eq 0 ]]; then
  exec tmux new-session -A -s main
else
  exec "$@"
fi

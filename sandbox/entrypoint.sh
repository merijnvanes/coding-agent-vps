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
# Design note: this entrypoint deliberately does NOT exec into tmux as
# PID 1. The previous design (`exec tmux new-session -A -s main`) made
# the container's survival load-bearing on tmux's survival — an OOM kill
# of any tmux pane child that cascaded to the tmux session/server ending
# would take the container down (exit code 0, then `restart: unless-
# stopped` brings it back fresh with all sessions gone). Instead:
#
#   1. docker-compose.yml sets `init: true` so PID 1 is docker-init
#      (bundled `tini`) — handles zombie reaping and signal forwarding.
#   2. We start tmux DETACHED so its server outlives this script.
#   3. We exec `sleep infinity` as the foreground process. Container
#      stays up as long as docker-init is alive; tmux server lifecycle
#      is independent.
#   4. If tmux server dies (legit OOM kill, manual kill-server, etc.),
#      `docker exec -it sandbox tmux new-session -A -s main` recreates
#      it; the container's writable layer (~/.infisical/login state,
#      etc.) survives untouched. Compare with the old design where the
#      same event would have triggered a full container restart that
#      nuked the writable layer.

set -euo pipefail

# Use the socat-bridged socket (not the raw ssh-agent socket). ssh-agent's
# kernel-level peer-UID check rejects direct connections from the sandbox
# because rootless Docker maps the container's `agent` user (UID 1000) to
# host UID 100999, which doesn't match ssh-agent's UID (999, `creds`).
# See daemon/ssh-agent-bridge.service for the rationale.
export SSH_AUTH_SOCK=/run/sockets/ssh-agent-bridge.sock

# If an explicit command was passed, honor it (lets `docker run sandbox
# <cmd>` and `docker exec sandbox <cmd>` patterns still work cleanly).
if [[ $# -gt 0 ]]; then
  exec "$@"
fi

# Otherwise: start the tmux server with a default `main` session so the
# user's first `docker exec -it sandbox tmux attach -t main` Just Works.
# Idempotent: check for existing session first, then create only if absent.
# Avoids `|| true` swallowing real socket/config errors.
tmux has-session -t main 2>/dev/null || tmux new-session -d -s main

# Keep the container alive independently of tmux. docker-init (PID 1, via
# `init: true` in docker-compose.yml) forwards SIGTERM to this `sleep`
# process during `docker stop`, so graceful shutdown still works.
exec sleep infinity

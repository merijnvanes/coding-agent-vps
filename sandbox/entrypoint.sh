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

# --- Agent Skills bridge ---
# The skills repo (github.com/merijnvanes/skills) is a checkout under /work,
# i.e. on the bind mount, so it survives container rebuilds and is updated by
# a plain `git pull`. Its own README defines the canonical layout: the repo IS
# `~/.agents/skills`, and each agent CLI needs a symlink farm because none of
# them read `.agents/` directly yet.
#
# Doing this at every container start rather than once by hand is the whole
# point. `~/.agents` and the per-agent symlinks live in the container's
# writable layer, which `docker compose up -d --build` discards. Wiring them
# up by hand produces skills that work for months and then silently vanish on
# the next rebuild, leaving dangling symlinks behind (observed 2026-08-26:
# five dead links, three repo skills never bridged at all). Rebuilding the
# farm here is idempotent and picks up skills added to the repo since.
SKILLS_SRC=/work/skills
if [[ -d "$SKILLS_SRC" ]]; then
  mkdir -p "$HOME/.agents"
  ln -sfn "$SKILLS_SRC" "$HOME/.agents/skills"

  for dest in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.gemini/skills"; do
    # Only bridge into agents that are actually installed (their home dir is
    # a named volume mounted by docker-compose.yml).
    if [[ ! -d "$(dirname "$dest")" ]]; then
      continue
    fi
    mkdir -p "$dest"

    for s in "$SKILLS_SRC"/*/; do
      if [[ -f "$s/SKILL.md" ]]; then
        ln -sfn "$s" "$dest/$(basename "$s")"
      fi
    done

    # Drop links that point into the skills tree but no longer resolve, so a
    # skill deleted upstream doesn't linger. Links pointing anywhere else
    # (hand-installed skills, plugin-managed ones) are left alone.
    while IFS= read -r -d '' link; do
      target="$(readlink "$link")"
      case "$target" in
        "$SKILLS_SRC"/*|"$HOME/.agents/skills"/*)
          if [[ ! -e "$link" ]]; then
            rm -f "$link"
          fi
          ;;
      esac
    done < <(find "$dest" -maxdepth 1 -type l -print0)
  done
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

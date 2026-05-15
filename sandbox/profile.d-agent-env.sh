# /etc/profile.d/agent-env.sh
# Sourced by every interactive bash login shell (and by tmux when it starts
# a new window with the default-command of a login shell). Pulls in the
# non-secret sandbox config (sandbox-config.sh — INFISICAL_TOOLING_PROJECT_ID
# and INFISICAL_ENV) written by bootstrap.sh on the VPS host. The PATH shims
# at /opt/agent-vps-wrappers/ read those env vars to wrap each cloud-CLI
# invocation with `infisical run --`.

if [ -d /run/agent-env ]; then
  for f in /run/agent-env/*.sh; do
    [ -r "$f" ] && . "$f"
  done
  unset f
fi

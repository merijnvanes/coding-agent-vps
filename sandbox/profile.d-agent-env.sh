# /etc/profile.d/agent-env.sh
# Sourced by every interactive bash login shell (and by tmux when it starts
# a new window with the default-command of a login shell). Pulls in any
# env-export files written by the cred-daemon — refreshed values reach the
# next new shell automatically, without restarting the container.

if [ -d /run/agent-env ]; then
  for f in /run/agent-env/*.sh; do
    [ -r "$f" ] && . "$f"
  done
  unset f
fi

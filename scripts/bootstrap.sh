#!/usr/bin/env bash
# scripts/bootstrap.sh — runs on the VPS after first SSH-in
#
# Prompts for Infisical config + the Universal Auth bootstrap secret, writes
# the config files, then runs cred-daemon once to validate everything and
# populate the local credential cache.
#
# Re-runnable: paste the same values again to update, or fresh values to
# rotate the bootstrap secret in place.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (use sudo)" >&2; exit 1; }

CONFIG_FILE="/etc/agent-vps/config.env"
BOOTSTRAP_FILE="/etc/agent-vps/infisical-uauth"

ask()       { local prompt="$1" default="${2:-}" var=""; read -rp "$prompt${default:+ [$default]}: " var; printf '%s' "${var:-$default}"; }
ask_secret(){ local prompt="$1" var=""; read -rsp "$prompt: " var; echo >&2; printf '%s' "$var"; }

echo
echo "=== coding-agent-vps bootstrap ==="
echo
PROJECT_ID=$(ask     "Infisical project ID")
ENV=$(ask            "Infisical environment slug" "prod")
URL=$(ask            "Infisical URL" "https://us.infisical.com")
CLIENT_ID=$(ask      "Infisical Universal Auth client ID")
CLIENT_SECRET=$(ask_secret "Infisical Universal Auth client secret (input hidden)")
echo

# --- /etc/agent-vps/config.env (non-secret) ---
install -m 0644 -o root -g root /dev/stdin "$CONFIG_FILE" <<EOF
# coding-agent-vps cred-daemon configuration
# Re-run scripts/bootstrap.sh to update.
INFISICAL_PROJECT_ID=$PROJECT_ID
INFISICAL_ENV=$ENV
INFISICAL_URL=$URL
EOF

# --- /etc/agent-vps/infisical-uauth (bootstrap secret, creds-only) ---
install -m 0600 -o creds -g creds /dev/stdin "$BOOTSTRAP_FILE" <<EOF
INFISICAL_CLIENT_ID=$CLIENT_ID
INFISICAL_CLIENT_SECRET=$CLIENT_SECRET
EOF

# --- Run the daemon once ---
echo "Running first credential fetch from Infisical..."
if systemctl start cred-daemon.service; then
  echo "✓ Credential fetch succeeded."
else
  echo
  echo "ERROR: cred-daemon.service failed on first run. Check logs:"
  echo "    journalctl -u cred-daemon.service -n 80 --no-pager"
  exit 1
fi

echo
echo "=== Done ==="
echo
echo "Next steps (as the merijn user):"
echo
echo "  sudo -u merijn -H bash -lc 'cd /opt/agent-vps && docker compose up -d'"
echo "  sudo -u merijn -H bash -lc 'docker exec -it sandbox tmux attach -t main'"
echo
echo "Inside the tmux session, log in to your AI subscriptions interactively:"
echo "  claude login"
echo "  codex login"
echo
echo "Subsequent rebuilds: refresh tokens persist in the sandbox-state Docker"
echo "volume, so OAuth login is only needed the first time."

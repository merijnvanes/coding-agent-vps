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
ENV=$(ask            "Infisical environment slug" "dev")
URL=$(ask            "Infisical URL" "https://app.infisical.com")
CLIENT_ID=$(ask      "Infisical Universal Auth client ID")
CLIENT_SECRET=$(ask_secret "Infisical Universal Auth client secret (input hidden)")
echo

# Write a KEY=VALUE line with the value shell-quoted via `printf %q`, so
# the resulting file is safe for `source` to evaluate regardless of what
# characters the user pasted (spaces, $, `, ", \, etc.). Without this,
# a value containing `$` or `` ` `` would be expanded at source time.
emit_kv() { printf '%s=%q\n' "$1" "$2"; }

# --- /etc/agent-vps/config.env (non-secret) ---
{
  echo "# coding-agent-vps cred-daemon configuration"
  echo "# Re-run scripts/bootstrap.sh to update."
  emit_kv INFISICAL_PROJECT_ID "$PROJECT_ID"
  emit_kv INFISICAL_ENV         "$ENV"
  emit_kv INFISICAL_URL         "$URL"
} | install -m 0644 -o root -g root /dev/stdin "$CONFIG_FILE"

# --- /etc/agent-vps/infisical-uauth (bootstrap secret, creds-only) ---
{
  emit_kv INFISICAL_CLIENT_ID     "$CLIENT_ID"
  emit_kv INFISICAL_CLIENT_SECRET "$CLIENT_SECRET"
} | install -m 0600 -o creds -g creds /dev/stdin "$BOOTSTRAP_FILE"

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
echo "Next steps (as the dev user):"
echo
echo "  sudo -u dev -H bash -lc 'cd /opt/agent-vps && docker compose up -d'"
echo "  sudo -u dev -H bash -lc 'docker exec -it sandbox tmux attach -t main'"
echo
echo "Inside the tmux session, log in to your AI subscriptions interactively:"
echo "  claude login"
echo "  codex login"
echo
echo "Subsequent rebuilds: refresh tokens persist in the sandbox-state Docker"
echo "volume, so OAuth login is only needed the first time."

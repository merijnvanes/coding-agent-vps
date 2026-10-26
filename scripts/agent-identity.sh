#!/usr/bin/env bash
# scripts/agent-identity.sh — runs on the VPS, as root
#
# Stores the Universal Auth client ID + secret of the sandbox's Infisical
# machine identity (`<vps-name>-agent`, docs/SETUP.md "Infisical"), then
# fetches the first short-lived token for the sandbox. The secret stays in
# the creds zone; the sandbox only ever gets 1-hour access tokens
# (daemon/agent-token.sh).
#
# bootstrap.sh runs this at the end. Run it alone to rotate the client
# secret: paste the new one, then revoke the old one in Infisical.
#
# Usage: sudo /opt/agent-vps/scripts/agent-identity.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (use sudo)" >&2; exit 1; }

UAUTH_FILE="/etc/agent-vps/infisical-agent-uauth"
TOKEN_FILE="/var/lib/agent-vps/agent-token/token"

ask()       { local prompt="$1" var=""; read -rp "$prompt: " var; printf '%s' "$var"; }
ask_secret(){ local prompt="$1" var=""; read -rsp "$prompt: " var; echo >&2; printf '%s' "$var"; }
emit_kv()   { printf '%s=%q\n' "$1" "$2"; }

echo
echo "=== Sandbox Infisical identity ==="
echo
CLIENT_ID=$(ask         "Universal Auth client ID of the agent identity (<vps-name>-agent)")
CLIENT_SECRET=$(ask_secret "Universal Auth client secret (input hidden)")
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || { echo "ERROR: client ID and secret are both required" >&2; exit 1; }

{
  emit_kv AGENT_CLIENT_ID     "$CLIENT_ID"
  emit_kv AGENT_CLIENT_SECRET "$CLIENT_SECRET"
} | install -m 0600 -o creds -g creds /dev/stdin "$UAUTH_FILE"

echo "Fetching the first sandbox token..."
if systemctl start agent-token.service && [[ -s "$TOKEN_FILE" ]]; then
  echo "✓ The sandbox now reads Infisical as the agent identity."
  echo "  agent-token.timer refreshes the token every 20 minutes."
else
  echo
  echo "ERROR: agent-token.service did not write a token. Check logs:"
  echo "    journalctl -u agent-token.service -n 40 --no-pager"
  exit 1
fi

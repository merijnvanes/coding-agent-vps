#!/usr/bin/env bash
# scripts/provision.sh — runs on YOUR LAPTOP. Creates a fresh coding-agent-vps
# on Hetzner Cloud against the dedicated `coding-agent-vps` project.
#
# Prerequisites (one-time, see README.md "Pre-implementation checklist"):
#   - Hetzner project `coding-agent-vps` exists with admin token
#   - That admin token is loaded into `hcloud` as a context (default name:
#     coding-agent-vps-admin). Override via HCLOUD_CONTEXT env var.
#   - Hetzner Cloud firewall `agent-vps-deny-all` exists in that project,
#     with deny-all-inbound rules for v4 and v6.
#
# Usage: ./scripts/provision.sh

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

CONTEXT="${HCLOUD_CONTEXT:-coding-agent-vps-admin}"
SERVER_NAME="${SERVER_NAME:-coding-agent-vps}"
LOCATION="${LOCATION:-fsn1}"           # Falkenstein, DE — change to nbg1, hel1, ash, etc.
TYPE="${TYPE:-cx22}"                   # cheapest x86 (€4.49/mo)
IMAGE="${IMAGE:-ubuntu-24.04}"
FIREWALL="${FIREWALL:-agent-vps-deny-all}"

# Use the admin context for this run
hcloud context use "$CONTEXT" \
  || { echo "ERROR: hcloud context '$CONTEXT' not found. Run: hcloud context create $CONTEXT" >&2; exit 1; }

# Confirm before destroying any existing server with the same name
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  echo "WARNING: A server named '$SERVER_NAME' already exists in this project."
  read -rp "Delete and recreate? (yes/N): " confirm
  if [[ "$confirm" == "yes" ]]; then
    hcloud server delete "$SERVER_NAME"
  else
    echo "Aborted." >&2; exit 1
  fi
fi

# Prompt for Tailscale auth-key (single-use, ≤24h TTL — generate fresh)
echo
echo "Generate a fresh Tailscale auth-key:"
echo "  https://login.tailscale.com/admin/settings/keys"
echo "  → 'Generate auth key' → Reusable: NO, Ephemeral: NO, Expiration: ≤24h"
echo
read -rsp "Paste Tailscale auth-key (input hidden): " TAILSCALE_AUTH_KEY
echo

# Substitute into cloud-init template
USER_DATA=$(mktemp)
trap 'rm -f "$USER_DATA"' EXIT
sed "s|__TAILSCALE_AUTH_KEY__|${TAILSCALE_AUTH_KEY}|g" cloud-init.yaml > "$USER_DATA"

echo "Provisioning $SERVER_NAME (type=$TYPE, location=$LOCATION, firewall=$FIREWALL)..."
hcloud server create \
  --name "$SERVER_NAME" \
  --type "$TYPE" \
  --image "$IMAGE" \
  --location "$LOCATION" \
  --firewall "$FIREWALL" \
  --user-data-from-file "$USER_DATA"

echo
echo "✓ Server created. Cloud-init runs in the background and takes ~5–10 min"
echo "  (package install + Docker setup + sandbox image build)."
echo
echo "Watch progress:"
echo "  hcloud server status $SERVER_NAME"
echo "  tailscale status   # the server will appear when it joins the tailnet"
echo
echo "Once it shows in your tailnet, SSH in:"
echo "  ssh merijn@coding-agent-vps   # uses Tailscale SSH; no keys to manage"
echo
echo "Then:"
echo "  sudo bash /opt/agent-vps/scripts/bootstrap.sh"

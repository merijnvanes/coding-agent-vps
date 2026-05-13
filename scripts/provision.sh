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
#   - `gh` CLI authenticated with `repo` scope (used to register the
#     read-only deploy key for the private repo).
#
# Usage: ./scripts/provision.sh

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

CONTEXT="${HCLOUD_CONTEXT:-coding-agent-vps-admin}"
SERVER_NAME="${SERVER_NAME:-coding-agent-vps}"
LOCATION="${LOCATION:-fsn1}"           # Falkenstein, DE — change to nbg1, hel1, ash, etc.
TYPE="${TYPE:-cx23}"                   # 2 vCPU / 4GB / 40GB shared x86 (~€4.50-5/mo, cx22 successor)
IMAGE="${IMAGE:-ubuntu-24.04}"
FIREWALL="${FIREWALL:-agent-vps-deny-all}"

# Repo-scoped read-only deploy key. Generated once, registered on the private
# GitHub repo, then embedded in cloud-init user-data so the VPS can `git clone`
# at first boot. Same trust class as the Tailscale auth-key (Hetzner sees the
# user-data once); read-only and scoped to this one repo.
DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-$HOME/.ssh/coding-agent-vps-deploy}"
DEPLOY_KEY_TITLE="coding-agent-vps deploy key (provision.sh)"
GH_REPO="${GH_REPO:-merijnvanes/coding-agent-vps}"

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

# Ensure deploy key exists locally; generate if missing.
mkdir -p "$(dirname "$DEPLOY_KEY_PATH")"
chmod 0700 "$(dirname "$DEPLOY_KEY_PATH")"
if [[ ! -f "$DEPLOY_KEY_PATH" ]]; then
  echo "Generating deploy keypair: $DEPLOY_KEY_PATH"
  ssh-keygen -t ed25519 -f "$DEPLOY_KEY_PATH" -N "" -C "coding-agent-vps deploy" >/dev/null
fi
[[ -f "${DEPLOY_KEY_PATH}.pub" ]] || { echo "ERROR: ${DEPLOY_KEY_PATH}.pub missing" >&2; exit 1; }

# Register the public key as a read-only deploy key on the repo if not
# already registered (idempotent — compares the actual key material).
LOCAL_PUB_KEY=$(awk '{print $1, $2}' "${DEPLOY_KEY_PATH}.pub")
if gh api "/repos/${GH_REPO}/keys" --jq '.[].key' 2>/dev/null \
   | awk '{print $1, $2}' | grep -Fxq "$LOCAL_PUB_KEY"; then
  echo "✓ Deploy key already registered on ${GH_REPO}"
else
  echo "Registering deploy key on ${GH_REPO} (read-only)..."
  gh api -X POST "/repos/${GH_REPO}/keys" \
    -f "title=${DEPLOY_KEY_TITLE}" \
    -f "key=$(cat "${DEPLOY_KEY_PATH}.pub")" \
    -F "read_only=true" >/dev/null
  echo "✓ Registered."
fi

# Prompt for Tailscale auth-key (single-use, ≤24h TTL — generate fresh)
echo
echo "Generate a fresh Tailscale auth-key:"
echo "  https://login.tailscale.com/admin/settings/keys"
echo "  → 'Generate auth key' → Reusable: NO, Ephemeral: NO, Expiration: ≤24h"
echo
read -rsp "Paste Tailscale auth-key (input hidden): " TAILSCALE_AUTH_KEY
echo

# Base64-encode the deploy private key (single-line — safe for sed
# substitution into the cloud-init.yaml write_files block).
DEPLOY_KEY_B64=$(base64 < "$DEPLOY_KEY_PATH" | tr -d '\n')

# Substitute into cloud-init template
USER_DATA=$(mktemp)
trap 'rm -f "$USER_DATA"' EXIT
sed -e "s|__TAILSCALE_AUTH_KEY__|${TAILSCALE_AUTH_KEY}|g" \
    -e "s|__DEPLOY_KEY_B64__|${DEPLOY_KEY_B64}|g" \
    cloud-init.yaml > "$USER_DATA"

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

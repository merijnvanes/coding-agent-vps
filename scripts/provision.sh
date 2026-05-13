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

# Repo-scoped read-only deploy key. Generated once, registered on the
# GitHub repo (yours or your fork's), then embedded in cloud-init user-data
# so the VPS can `git clone` at first boot. Same trust class as the
# Tailscale auth-key (Hetzner sees the user-data once); read-only and
# scoped to this one repo.
DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-$HOME/.ssh/coding-agent-vps-deploy}"
DEPLOY_KEY_TITLE="coding-agent-vps deploy key (provision.sh)"

# Auto-detect the GitHub repo from the local `origin` remote so forks
# Just Work without editing this file. Override with `GH_REPO=owner/repo`
# if you need to point at a different repo (e.g. a tarball clone with no
# origin set).
if [[ -z "${GH_REPO:-}" ]]; then
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null) || {
    echo "ERROR: no 'origin' remote in this git repo (or not a git repo)." >&2
    echo "Set GH_REPO=owner/repo manually, or push this checkout to GitHub first." >&2
    exit 1
  }
  # Strip protocol/host prefix and .git suffix using bash parameter expansion
  # (sed with `|` as delimiter conflicted with the `|` in (https://...|git@...)
  # alternation; bash param expansion sidesteps the issue and handles repos
  # with dots in the name).
  gh_path="${ORIGIN_URL#https://github.com/}"
  gh_path="${gh_path#git@github.com:}"
  gh_path="${gh_path%.git}"
  if [[ "$gh_path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    GH_REPO="$gh_path"
    echo "Using GH_REPO=$GH_REPO (auto-detected from git origin)"
  else
    echo "ERROR: couldn't parse owner/repo from origin URL: $ORIGIN_URL" >&2
    echo "Set GH_REPO=owner/repo manually." >&2
    exit 1
  fi
fi

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

# Detect whether the repo is public or private — drives the clone strategy.
# Public: cloud-init clones via HTTPS, no auth, no deploy key needed.
# Private: cloud-init clones via SSH using a read-only deploy key registered
#          on the repo via `gh api`. The deploy-key flow requires gh CLI
#          auth + admin access on $GH_REPO (i.e., it's your fork).
echo "Checking visibility of ${GH_REPO}..."
if curl -fsSL -o /dev/null --max-time 10 "https://github.com/${GH_REPO}" 2>/dev/null; then
  REPO_VISIBILITY="public"
  CLONE_URL="https://github.com/${GH_REPO}.git"
  echo "✓ ${GH_REPO} is public — cloud-init will clone via HTTPS (no deploy key)."
else
  REPO_VISIBILITY="private"
  CLONE_URL="git@github.com:${GH_REPO}.git"
  echo "✓ ${GH_REPO} appears private — will provision a read-only deploy key for SSH clone."
fi

# Warn if there are local commits or working-tree changes not on origin —
# cloud-init clones from origin, so unpushed work won't reach the VPS.
HAS_UPSTREAM=true
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || HAS_UPSTREAM=false

LOCAL_AHEAD=0
if $HAS_UPSTREAM; then
  LOCAL_AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
fi
WORKING_DIRTY=$(git status --porcelain 2>/dev/null | head -c1)

if ! $HAS_UPSTREAM || [[ "$LOCAL_AHEAD" -gt 0 || -n "$WORKING_DIRTY" ]]; then
  echo
  echo "WARNING: this checkout may have changes not on origin:"
  $HAS_UPSTREAM                 || echo "  - no upstream tracking branch — cannot compare to origin"
  [[ "$LOCAL_AHEAD" -gt 0 ]]    && echo "  - ${LOCAL_AHEAD} commit(s) ahead of $(git rev-parse --abbrev-ref '@{u}' 2>/dev/null)"
  [[ -n "$WORKING_DIRTY" ]]     && echo "  - uncommitted changes in the working tree"
  echo "Cloud-init clones from origin, so anything not pushed will NOT reach the VPS."
  echo "Push your changes first (and rerun) if you intend them to apply."
  echo
  read -rp "Continue anyway? (yes/N): " confirm
  [[ "$confirm" == "yes" ]] || { echo "Aborted." >&2; exit 1; }
fi

# Deploy-key flow — only needed when the repo is private.
# When public, substitute a benign 1-byte placeholder so cloud-init's
# base64 decoder doesn't trip on null/empty content (some versions don't
# handle that cleanly; the resulting file is unused either way).
DEPLOY_KEY_B64="IA=="
if [[ "$REPO_VISIBILITY" == "private" ]]; then
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

  # Base64-encode for safe single-line substitution into cloud-init's
  # write_files block (encoding: base64).
  DEPLOY_KEY_B64=$(base64 < "$DEPLOY_KEY_PATH" | tr -d '\n')
fi

# Prompt for Tailscale auth-key (single-use, ≤24h TTL — generate fresh)
echo
echo "Generate a fresh Tailscale auth-key:"
echo "  https://login.tailscale.com/admin/settings/keys"
echo "  → 'Generate auth key' → Reusable: NO, Ephemeral: NO, Expiration: ≤24h"
echo "  → Tags: tick 'tag:coding-agent-vps' (REQUIRED — see docs/SETUP.md Phase 3)"
echo
read -rsp "Paste Tailscale auth-key (input hidden): " TAILSCALE_AUTH_KEY
echo

# Substitute into cloud-init template. For public repos DEPLOY_KEY_B64 is
# empty — the deploy-key write_files entry becomes a 0-byte file (harmless;
# never used because the HTTPS clone needs no auth).
USER_DATA=$(mktemp)
trap 'rm -f "$USER_DATA"' EXIT
sed -e "s|__TAILSCALE_AUTH_KEY__|${TAILSCALE_AUTH_KEY}|g" \
    -e "s|__DEPLOY_KEY_B64__|${DEPLOY_KEY_B64}|g" \
    -e "s|__CLONE_URL__|${CLONE_URL}|g" \
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

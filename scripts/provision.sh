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

# Repo-scoped read-only deploy key, private repos only. A new key for each
# run: registered on the GitHub repo, embedded in cloud-init user-data so
# the VPS can `git clone` and pull, and never stored on the laptop. Once
# the new server exists, the keys of earlier servers with this name are
# deleted from the repo; if the run fails first, the new key is deleted.
# Same trust class as the Tailscale auth-key (Hetzner sees the user-data);
# read-only and scoped to this one repo.
DEPLOY_KEY_TITLE="coding-agent-vps deploy key (${SERVER_NAME})"
# Title used before keys were made per run. It names no server, so the
# script lists these keys but never deletes them: one may still serve a
# server with another name.
LEGACY_DEPLOY_KEY_TITLE="coding-agent-vps deploy key (provision.sh)"

WORK_DIR=$(mktemp -d)
NEW_DEPLOY_PUB=""      # "type blob" of the key this run registers
NEW_DEPLOY_KEY_ID=""
SERVER_CREATED=false

# Prints "id<TAB>title<TAB>type blob" for every deploy key on the repo.
list_deploy_keys() {
  gh api --paginate "/repos/${GH_REPO}/keys" \
    --jq '.[] | "\(.id)\t\(.title)\t\(.key | split(" ") | .[0:2] | join(" "))"'
}

cleanup() {
  if [[ -n "$NEW_DEPLOY_PUB" ]] && ! $SERVER_CREATED; then
    # The POST may have succeeded without returning the id; find the key
    # by its material.
    [[ -n "$NEW_DEPLOY_KEY_ID" ]] \
      || NEW_DEPLOY_KEY_ID=$({ list_deploy_keys 2>/dev/null || true; } \
           | awk -F'\t' -v k="$NEW_DEPLOY_PUB" '$3 == k { print $1; exit }')
    if [[ -z "$NEW_DEPLOY_KEY_ID" ]]; then
      echo "WARNING: check ${GH_REPO} for an unused '${DEPLOY_KEY_TITLE}' deploy key and delete it." >&2
    elif ! gh api -X DELETE "/repos/${GH_REPO}/keys/${NEW_DEPLOY_KEY_ID}" >/dev/null 2>&1; then
      echo "WARNING: delete the unused deploy key ${NEW_DEPLOY_KEY_ID} on ${GH_REPO} by hand." >&2
    fi
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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
FETCHED=true
if $HAS_UPSTREAM; then
  # Compare with origin as it is now, not as of the last fetch.
  UPSTREAM_REMOTE=$(git config "branch.$(git branch --show-current).remote" || true)
  git fetch -q "${UPSTREAM_REMOTE:-origin}" || FETCHED=false
  LOCAL_AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
fi
WORKING_DIRTY=$(git status --porcelain 2>/dev/null | head -c1)

if ! $HAS_UPSTREAM || ! $FETCHED || [[ "$LOCAL_AHEAD" -gt 0 || -n "$WORKING_DIRTY" ]]; then
  echo
  echo "WARNING: this checkout may have changes not on origin:"
  $HAS_UPSTREAM                 || echo "  - no upstream tracking branch — cannot compare to origin"
  $FETCHED                      || echo "  - could not fetch ${UPSTREAM_REMOTE:-origin} — compared with the last fetched state"
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
DEPLOY_KEY_PATH="$WORK_DIR/deploy-key"
if [[ "$REPO_VISIBILITY" == "private" ]]; then
  ssh-keygen -q -t ed25519 -f "$DEPLOY_KEY_PATH" -N "" -C "coding-agent-vps deploy ${SERVER_NAME}"
  echo "Registering a new read-only deploy key on ${GH_REPO}..."
  NEW_DEPLOY_PUB=$(awk '{ print $1, $2 }' "${DEPLOY_KEY_PATH}.pub")
  NEW_DEPLOY_KEY_ID=$(gh api -X POST "/repos/${GH_REPO}/keys" \
    -f "title=${DEPLOY_KEY_TITLE}" \
    -f "key=$(cat "${DEPLOY_KEY_PATH}.pub")" \
    -F "read_only=true" --jq '.id')
  [[ "$NEW_DEPLOY_KEY_ID" =~ ^[0-9]+$ ]] || { echo "ERROR: deploy key registration returned no id" >&2; exit 1; }
  echo "✓ Registered (id ${NEW_DEPLOY_KEY_ID})."

  # Base64-encode for safe single-line substitution into cloud-init's
  # write_files block (encoding: base64).
  DEPLOY_KEY_B64=$(base64 < "$DEPLOY_KEY_PATH" | tr -d '\n')
fi

# The VPS pulls only commits signed by this laptop's git signing key
# (scripts/cloud-init-tasks.sh step 2d); this line becomes its
# /etc/agent-vps/allowed-signers. This script and the helper run from
# the working tree, so the laptop checkout is trusted: with the laptop
# git config from docs/SETUP.md Phase 5 "Sign commits", unsigned commits
# land in it only after you review them.
ALLOWED_SIGNERS=$(./scripts/allowed-signers-line.sh)

# Fail here, not ten minutes into cloud-init: the tip cloud-init will
# clone must carry that signature, or the VPS stops before setup. Fetch
# it the way cloud-init will (a private repo through the deploy key).
# The cloud-init template sent below comes from this same verified
# commit, never from the working tree. gpg.openpgp/x509.program=false:
# git picks the verifier from the signature, so only SSH signatures may
# count.
if [[ "$REPO_VISIBILITY" == "private" ]]; then
  GIT_SSH_COMMAND="ssh -i $(printf '%q' "$DEPLOY_KEY_PATH") -o IdentitiesOnly=yes" git fetch -q "$CLONE_URL" HEAD
else
  git fetch -q "$CLONE_URL" HEAD
fi
REMOTE_TIP=$(git rev-parse FETCH_HEAD)
SIGNERS_TMP=$(mktemp)
printf '%s\n' "$ALLOWED_SIGNERS" > "$SIGNERS_TMP"
if ! git -c gpg.ssh.allowedSignersFile="$SIGNERS_TMP" -c gpg.openpgp.program=false -c gpg.x509.program=false \
       verify-commit "$REMOTE_TIP" 2>/dev/null; then
  rm -f "$SIGNERS_TMP"
  echo "ERROR: the tip of ${GH_REPO} (${REMOTE_TIP:0:7}) is not signed by your git signing key." >&2
  echo "Cloud-init would stop before setup. Commit (signed) and push, then rerun." >&2
  exit 1
fi
rm -f "$SIGNERS_TMP"
echo "✓ the tip of ${GH_REPO} (${REMOTE_TIP:0:7}) is signed by your git signing key"

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
# a 1-byte placeholder — the deploy-key write_files entry becomes a file
# that is never used, because the HTTPS clone needs no auth.
# Bash substitution, not sed: the auth key and the deploy key would be in
# sed's argv, which every local user can read. The quoted replacements are
# taken literally, so the signer line's email needs no escaping.
USER_DATA="$WORK_DIR/user-data"
TEMPLATE=$(git show "${REMOTE_TIP}:cloud-init.yaml")
TEMPLATE=${TEMPLATE//__TAILSCALE_AUTH_KEY__/"$TAILSCALE_AUTH_KEY"}
TEMPLATE=${TEMPLATE//__DEPLOY_KEY_B64__/"$DEPLOY_KEY_B64"}
TEMPLATE=${TEMPLATE//__CLONE_URL__/"$CLONE_URL"}
TEMPLATE=${TEMPLATE//__ALLOWED_SIGNERS__/"$ALLOWED_SIGNERS"}
( umask 077; printf '%s\n' "$TEMPLATE" > "$USER_DATA" )
unset TEMPLATE

# Confirm before destroying any existing server with the same name. Last
# of all, so a failed check above never leaves you without a VPS.
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  echo "WARNING: A server named '$SERVER_NAME' already exists in this project."
  read -rp "Delete and recreate? (yes/N): " confirm
  if [[ "$confirm" == "yes" ]]; then
    hcloud server delete "$SERVER_NAME"
  else
    echo "Aborted." >&2; exit 1
  fi
fi

# No --ssh-key, on purpose: nothing logs in over OpenSSH. Without a key,
# Hetzner sets a root password; cloud-init.yaml turns password login off
# from the first boot, and scripts/cloud-init-tasks.sh step 2b locks the
# password and masks sshd. Tailscale SSH is the only way in.
echo "Provisioning $SERVER_NAME (type=$TYPE, location=$LOCATION, firewall=$FIREWALL)..."
hcloud server create \
  --name "$SERVER_NAME" \
  --type "$TYPE" \
  --image "$IMAGE" \
  --location "$LOCATION" \
  --firewall "$FIREWALL" \
  --user-data-from-file "$USER_DATA"
SERVER_CREATED=true

# The new server has its own deploy key; earlier servers of this name are
# gone, so their keys go too.
if [[ "$REPO_VISIBILITY" == "private" ]]; then
  if keys=$(list_deploy_keys); then
    old_ids=$(awk -F'\t' -v t="$DEPLOY_KEY_TITLE" -v l="$LEGACY_DEPLOY_KEY_TITLE" -v n="$NEW_DEPLOY_KEY_ID" \
      '$2 == t && $2 != l && $1 != n { print $1 }' <<<"$keys")
    for old_id in $old_ids; do
      if gh api -X DELETE "/repos/${GH_REPO}/keys/${old_id}" >/dev/null; then
        echo "✓ Deleted the previous deploy key ${old_id}"
      else
        echo "WARNING: could not delete deploy key ${old_id} on ${GH_REPO}; delete it by hand." >&2
      fi
    done
    legacy_ids=$(awk -F'\t' -v t="$LEGACY_DEPLOY_KEY_TITLE" '$2 == t { print $1 }' <<<"$keys")
    if [[ -n "$legacy_ids" ]]; then
      echo "NOTE: ${GH_REPO} still has deploy keys titled '${LEGACY_DEPLOY_KEY_TITLE}' (ids: $(echo $legacy_ids))."
      echo "      Delete them (repo Settings → Deploy keys) once no older server uses them."
    fi
  else
    echo "WARNING: could not list the deploy keys on ${GH_REPO}; delete old '${DEPLOY_KEY_TITLE}' keys by hand." >&2
  fi
fi

echo
echo "✓ Server created. Cloud-init runs in the background and takes ~5–10 min"
echo "  (package install + Docker setup + sandbox image build)."
echo
echo "Watch progress:"
echo "  hcloud server status $SERVER_NAME"
echo "  tailscale status   # the server will appear when it joins the tailnet"
echo
echo "Once it shows in your tailnet, SSH in:"
echo "  ssh dev@coding-agent-vps   # uses Tailscale SSH; no keys to manage"
echo
echo "Then:"
echo "  sudo bash /opt/agent-vps/scripts/bootstrap.sh"

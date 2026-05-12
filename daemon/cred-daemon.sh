#!/usr/bin/env bash
# daemon/cred-daemon.sh — fetch credentials from Infisical, write to local cache
#
# What this does:
#   1. Authenticate to Infisical with Universal Auth (clientId + clientSecret
#      from /etc/agent-vps/infisical-uauth — the bootstrap secret).
#   2. Fetch all secret values from the configured Infisical project + env.
#   3. Write each secret to its designated location:
#      - github-ssh-key       → /var/lib/agent-vps/creds/github-ssh-key
#                               (also: ssh-add to the running ssh-agent)
#      - gcp-sa-key (JSON)    → /var/lib/agent-vps/agent-config/gcloud/
#                               application_default_credentials.json
#      - cloudflare-token     → /var/lib/agent-vps/agent-config/env/cloudflare.sh
#      - hcloud-token         → /var/lib/agent-vps/agent-config/env/hetzner.sh
#      - npm-token            → /var/lib/agent-vps/agent-config/npm/npmrc
#      - ntfy-topic           → /var/lib/agent-vps/creds/ntfy-topic
#   4. Missing secrets are skipped silently — adding a secret to Infisical
#      later, then restarting the daemon, is sufficient to enable that CLI.
#
# What this does NOT do:
#   - Mint, rotate, or call any upstream service's API. Upstream credential
#     lifecycle is the user's responsibility (REQUIREMENTS.md §5).
#
# Runs as user `creds` via the cred-daemon.service systemd unit, both at
# boot and daily at 04:00 UTC via cred-daemon.timer.

set -euo pipefail

# === Config ===
BOOTSTRAP_FILE="/etc/agent-vps/infisical-uauth"        # source-able file with CLIENT_ID + CLIENT_SECRET
CONFIG_FILE="/etc/agent-vps/config.env"                # source-able: INFISICAL_PROJECT_ID, INFISICAL_ENV, INFISICAL_URL
CREDS_DIR="/var/lib/agent-vps/creds"
CONFIG_DIR="/var/lib/agent-vps/agent-config"
SSH_AGENT_SOCKET="/var/lib/agent-vps/sockets/ssh-agent.sock"
ALERTS_SCRIPT="/opt/agent-vps/alerts/ntfy.sh"

# Defaults if not overridden by config.env
INFISICAL_URL="${INFISICAL_URL:-https://app.infisical.com}"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"

# === Helpers ===
log()   { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }
alert() { "$ALERTS_SCRIPT" "$1" "$2" || log "WARN: alert script failed"; }
die()   { log "FATAL: $*"; alert "cred-daemon" "FATAL: $*"; exit 1; }

# Write a file atomically with explicit mode and owner. Refuses to write
# empty content (treats that as "secret missing in Infisical, skip").
atomic_write() {
  local dest="$1" mode="$2" content="$3"
  [[ -z "$content" ]] && return 1
  install -d -m 0750 -o creds -g creds "$(dirname "$dest")"
  local tmp
  tmp=$(mktemp "${dest}.XXXXXX")
  printf '%s' "$content" > "$tmp"
  chmod "$mode" "$tmp"
  chown creds:creds "$tmp"
  mv "$tmp" "$dest"
}

# Fetch one secret value by key from the in-memory $SECRETS_JSON.
secret_value() {
  jq -r --arg key "$1" '.secrets[] | select(.secretKey == $key) | .secretValue // empty' <<<"$SECRETS_JSON"
}

# === Load config + bootstrap ===
[[ -r "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
[[ -n "${INFISICAL_PROJECT_ID:-}" ]] || die "INFISICAL_PROJECT_ID not set in $CONFIG_FILE"

[[ -r "$BOOTSTRAP_FILE" ]] || die "bootstrap file not found: $BOOTSTRAP_FILE"
# shellcheck source=/dev/null
source "$BOOTSTRAP_FILE"
[[ -n "${INFISICAL_CLIENT_ID:-}" && -n "${INFISICAL_CLIENT_SECRET:-}" ]] \
  || die "INFISICAL_CLIENT_ID or INFISICAL_CLIENT_SECRET not set"

# === 1. Authenticate to Infisical ===
log "authenticating to Infisical at $INFISICAL_URL"
AUTH_RESPONSE=$(curl -fsSL --max-time 30 \
  -X POST "$INFISICAL_URL/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg id "$INFISICAL_CLIENT_ID" \
    --arg secret "$INFISICAL_CLIENT_SECRET" \
    '{clientId:$id, clientSecret:$secret}')" \
  ) || die "Infisical auth request failed (network or invalid credentials)"

ACCESS_TOKEN=$(jq -r '.accessToken // empty' <<<"$AUTH_RESPONSE")
[[ -n "$ACCESS_TOKEN" ]] || die "Infisical auth returned no accessToken"

# === 2. Fetch all secrets ===
log "fetching secrets from project=$INFISICAL_PROJECT_ID env=$INFISICAL_ENV"
SECRETS_JSON=$(curl -fsSL --max-time 30 \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$INFISICAL_URL/api/v3/secrets/raw?workspaceId=$INFISICAL_PROJECT_ID&environment=$INFISICAL_ENV" \
  ) || die "Infisical secrets fetch failed"

# === 3. Write each integration's files (skip if secret missing) ===

# Ensure target directories exist with correct ownership
install -d -m 0750 -o creds -g creds "$CREDS_DIR"
install -d -m 0750 -o creds -g creds "$CONFIG_DIR"
install -d -m 0750 -o creds -g creds "$CONFIG_DIR/env"
install -d -m 0750 -o creds -g creds "$CONFIG_DIR/gcloud"
install -d -m 0750 -o creds -g creds "$CONFIG_DIR/npm"

# --- github-ssh-key (private key file + load into ssh-agent) ---
if val=$(secret_value github-ssh-key); [[ -n "$val" ]]; then
  log "writing github-ssh-key"
  atomic_write "$CREDS_DIR/github-ssh-key" 0600 "$val"
  # Ensure trailing newline (ssh-add is picky)
  printf '\n' >> "$CREDS_DIR/github-ssh-key"

  # Reload into ssh-agent: drop all, add fresh
  if [[ -S "$SSH_AGENT_SOCKET" ]]; then
    SSH_AUTH_SOCK="$SSH_AGENT_SOCKET" ssh-add -D 2>/dev/null || true
    SSH_AUTH_SOCK="$SSH_AGENT_SOCKET" ssh-add "$CREDS_DIR/github-ssh-key" \
      || alert "cred-daemon" "ssh-add failed for github-ssh-key"
  else
    log "WARN: ssh-agent socket not present at $SSH_AGENT_SOCKET — skipping ssh-add"
  fi
fi

# --- gcp-sa-key (service account JSON) ---
if val=$(secret_value gcp-sa-key); [[ -n "$val" ]]; then
  log "writing gcp-sa-key"
  atomic_write "$CONFIG_DIR/gcloud/application_default_credentials.json" 0644 "$val"
fi

# --- cloudflare-token (env-export) ---
if val=$(secret_value cloudflare-token); [[ -n "$val" ]]; then
  log "writing cloudflare env-export"
  atomic_write "$CONFIG_DIR/env/cloudflare.sh" 0644 \
    "export CLOUDFLARE_API_TOKEN='${val//\'/\'\\\'\'}'"
fi

# --- hcloud-token (env-export, apps-scope) ---
if val=$(secret_value hcloud-token); [[ -n "$val" ]]; then
  log "writing hetzner env-export"
  atomic_write "$CONFIG_DIR/env/hetzner.sh" 0644 \
    "export HCLOUD_TOKEN='${val//\'/\'\\\'\'}'"
fi

# --- npm-token (.npmrc) ---
if val=$(secret_value npm-token); [[ -n "$val" ]]; then
  log "writing npm .npmrc"
  atomic_write "$CONFIG_DIR/npm/npmrc" 0644 \
    "//registry.npmjs.org/:_authToken=${val}"
fi

# --- ntfy-topic ---
if val=$(secret_value ntfy-topic); [[ -n "$val" ]]; then
  atomic_write "$CREDS_DIR/ntfy-topic" 0600 "$val"
fi

log "refresh complete"

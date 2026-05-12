#!/usr/bin/env bash
# daemon/cred-daemon.sh — fetch credentials from Infisical, write to local cache
#
# What this does:
#   1. Authenticate to Infisical with Universal Auth (clientId + clientSecret
#      from /etc/agent-vps/infisical-uauth — the bootstrap secret).
#   2. Fetch all secret values from the configured Infisical project + env.
#   3. Write each secret to its designated location (see "Secret routing"
#      block below). Files end up owned by the daemon's user (creds) since
#      that's who's writing them — no chown needed.
#   4. Missing secrets are skipped silently. Adding a secret to Infisical
#      later, then restarting cred-daemon.service, enables that integration.
#
# What this does NOT do:
#   - Mint, rotate, or call any upstream service's API. Upstream credential
#     lifecycle is the user's responsibility (REQUIREMENTS.md §5).
#
# Runs as user `creds` via cred-daemon.service. Triggered:
#   - On boot (multi-user.target)
#   - Daily at 04:00 UTC (cred-daemon.timer)
#   - Manually via `systemctl start cred-daemon`

set -euo pipefail

# === Config ===
BOOTSTRAP_FILE="/etc/agent-vps/infisical-uauth"   # source-able: INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET
CONFIG_FILE="/etc/agent-vps/config.env"           # source-able: INFISICAL_PROJECT_ID, INFISICAL_ENV, INFISICAL_URL
CREDS_DIR="/var/lib/agent-vps/creds"              # raw key material, 0700 — sandbox cannot read
CONFIG_DIR="/var/lib/agent-vps/agent-config"      # per-CLI files, 0755 — sandbox bind-mounts these read-only
SSH_AGENT_SOCKET="/var/lib/agent-vps/sockets/ssh-agent.sock"
ALERTS_SCRIPT="/opt/agent-vps/alerts/ntfy.sh"

# Defaults if not overridden by config.env
INFISICAL_URL="${INFISICAL_URL:-https://us.infisical.com}"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"

# === Helpers ===
log()   { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }
alert() { "$ALERTS_SCRIPT" "$1" "$2" 2>/dev/null || log "WARN: alert script failed"; }
die()   { log "FATAL: $*"; alert "cred-daemon" "FATAL: $*"; exit 1; }

# Atomic write: temp file in same dir → mv. Mode 0644 by default; pass an
# explicit mode as $2. Empty content returns 1 (caller can skip follow-up).
#
# IMPORTANT: this function does NOT create or modify the parent directory's
# mode. The caller is responsible for ensuring the directory exists with the
# correct mode — top-level setup at the script start covers this. Without
# that rule, writing ntfy-topic into the 0700 creds dir would flip it to a
# laxer mode and open the boundary.
atomic_write() {
  local dest="$1" mode="${2:-0644}" content="$3"
  [[ -z "$content" ]] && return 1
  local tmp
  tmp=$(mktemp "${dest}.XXXXXX")
  printf '%s' "$content" > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
}

# Safe shell-quote a value for inclusion in an env-export script. Uses
# bash's printf %q which is robust for any payload (including single
# quotes, newlines, etc.) when the consuming shell is bash.
quote() { printf '%q' "$1"; }

# Get one secret value by key from the in-memory $SECRETS_JSON.
# Returns the value on stdout, exit code 0 even if the key is missing
# (empty stdout in that case — callers check for that).
# Uses --arg for the KEY (not sensitive); secret VALUE never leaves
# jq's stdin/stdout, so no /proc exposure.
secret_value() {
  jq -r --arg key "$1" \
    '.secrets[]? | select(.secretKey == $key) | .secretValue // empty' \
    <<<"$SECRETS_JSON"
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

# === Ensure target directories exist with the right mode ===
# Creds zone: 0700 — only daemon can read. Sandbox cannot reach.
install -d -m 0700 "$CREDS_DIR"
# Config zone: 0755 — sandbox bind-mounts these read-only; "other" needs
# +x on the directory to traverse and +r on the files to read.
install -d -m 0755 "$CONFIG_DIR"
install -d -m 0755 "$CONFIG_DIR/env"
install -d -m 0755 "$CONFIG_DIR/gcloud"
install -d -m 0755 "$CONFIG_DIR/npm"

# === 1. Authenticate to Infisical ===
# Body and Authorization header are passed via temp files (mode 0600) so the
# client secret and access token are NOT visible in /proc/<pid>/cmdline of
# curl/jq. The temp files live in the daemon's PrivateTmp namespace (set in
# the systemd unit) and are cleaned up on exit.
TMPDIR_CLEAN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_CLEAN"' EXIT
chmod 0700 "$TMPDIR_CLEAN"

BODY_FILE="$TMPDIR_CLEAN/auth-body"
# Build JSON via jq using environment variables (already-set by source-ing
# the bootstrap file). This avoids:
#   - putting secret on jq's argv (which would leak via /proc/<pid>/cmdline)
#   - JSON-injection bugs from hand-formatted printf with values containing
#     `"`, `\`, or newlines
# The env vars are visible to jq via /proc/<jq-pid>/environ only; since
# cred-daemon is the sole process running as the `creds` user and no other
# user on the host can read that proc entry, this is acceptable.
jq -n '{clientId: env.INFISICAL_CLIENT_ID, clientSecret: env.INFISICAL_CLIENT_SECRET}' \
  > "$BODY_FILE"
chmod 0600 "$BODY_FILE"

log "authenticating to Infisical at $INFISICAL_URL"
AUTH_RESPONSE=$(curl -fsSL --max-time 30 \
  -X POST "$INFISICAL_URL/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  --data-binary "@$BODY_FILE" \
  ) || die "Infisical auth request failed (network or invalid credentials)"

# Validate response shape upfront — parallels the secrets-response check.
if ! jq -e '.accessToken | type == "string"' <<<"$AUTH_RESPONSE" >/dev/null 2>&1; then
  die "Infisical auth response missing/invalid accessToken (API change or error body?)"
fi
ACCESS_TOKEN=$(jq -r '.accessToken' <<<"$AUTH_RESPONSE")
[[ -n "$ACCESS_TOKEN" ]] || die "Infisical auth returned empty accessToken"

# === 2. Fetch all secrets ===
HEADER_FILE="$TMPDIR_CLEAN/auth-header"
printf 'Authorization: Bearer %s\n' "$ACCESS_TOKEN" > "$HEADER_FILE"
chmod 0600 "$HEADER_FILE"

log "fetching secrets from project=$INFISICAL_PROJECT_ID env=$INFISICAL_ENV"
SECRETS_JSON=$(curl -fsSL --max-time 30 \
  -H "@$HEADER_FILE" \
  "$INFISICAL_URL/api/v4/secrets?projectId=$INFISICAL_PROJECT_ID&environment=$INFISICAL_ENV&recursive=true" \
  ) || die "Infisical secrets fetch failed"

# Validate response shape upfront so a malformed body doesn't silently look
# like "every secret is missing" downstream. Fail loudly with an alert.
if ! jq -e '.secrets | type == "array"' <<<"$SECRETS_JSON" >/dev/null 2>&1; then
  die "Infisical response missing .secrets array (API shape change?)"
fi

# === 3. Write each integration's files (skip if secret missing) ===
# Routing table:
#   github-ssh-key     → CREDS_DIR/github-ssh-key (0600) + ssh-add into agent
#   gcp-sa-key         → CONFIG_DIR/gcloud/application_default_credentials.json (0644)
#   cloudflare-token   → CONFIG_DIR/env/cloudflare.sh   (0644, env-export)
#   hcloud-token       → CONFIG_DIR/env/hetzner.sh       (0644, env-export)
#   npm-token          → CONFIG_DIR/npm/npmrc            (0644)
#   pypi-token         → CONFIG_DIR/env/pypi.sh          (0644, env-export for uv/pip)
#   docker-hub-token   → CONFIG_DIR/env/docker-hub.sh    (0644, env-export)
#   ntfy-topic         → CREDS_DIR/ntfy-topic            (0600)

# --- github-ssh-key (private key + load into ssh-agent) ---
# Validate the new key BEFORE clearing the agent. If validation fails, keep
# the existing in-memory key (sshd will keep working with the previous key).
if val=$(secret_value github-ssh-key) && [[ -n "$val" ]]; then
  log "validating github-ssh-key from Infisical"
  TMP_KEY="$TMPDIR_CLEAN/new-ssh-key"
  printf '%s\n' "$val" > "$TMP_KEY"
  chmod 0600 "$TMP_KEY"

  if ssh-keygen -y -P '' -f "$TMP_KEY" >/dev/null 2>&1; then
    log "new SSH key valid, swapping into agent"
    install -m 0600 "$TMP_KEY" "$CREDS_DIR/github-ssh-key"
    if [[ -S "$SSH_AGENT_SOCKET" ]]; then
      SSH_AUTH_SOCK="$SSH_AGENT_SOCKET" ssh-add -D 2>/dev/null || true
      SSH_AUTH_SOCK="$SSH_AGENT_SOCKET" ssh-add "$CREDS_DIR/github-ssh-key" \
        || alert "cred-daemon" "ssh-add failed for new github-ssh-key"
    else
      log "WARN: ssh-agent socket not present at $SSH_AGENT_SOCKET — cred file updated but not loaded"
    fi
  else
    log "ERROR: new github-ssh-key fails ssh-keygen validation; keeping previous key"
    alert "cred-daemon" "Invalid SSH key in Infisical github-ssh-key; ignored"
  fi
fi

# --- gcp-sa-key (service account JSON, file-read at each gcloud invocation) ---
if val=$(secret_value gcp-sa-key) && [[ -n "$val" ]]; then
  log "writing gcp-sa-key"
  atomic_write "$CONFIG_DIR/gcloud/application_default_credentials.json" 0644 "$val"
fi

# --- cloudflare-token (env-export, footgun: stale in running shells) ---
if val=$(secret_value cloudflare-token) && [[ -n "$val" ]]; then
  log "writing cloudflare env-export"
  atomic_write "$CONFIG_DIR/env/cloudflare.sh" 0644 \
    "export CLOUDFLARE_API_TOKEN=$(quote "$val")"
fi

# --- hcloud-token (env-export, apps-scope) ---
if val=$(secret_value hcloud-token) && [[ -n "$val" ]]; then
  log "writing hetzner env-export"
  atomic_write "$CONFIG_DIR/env/hetzner.sh" 0644 \
    "export HCLOUD_TOKEN=$(quote "$val")"
fi

# --- npm-token (.npmrc, file-read at each npm/pnpm invocation) ---
if val=$(secret_value npm-token) && [[ -n "$val" ]]; then
  log "writing npm .npmrc"
  atomic_write "$CONFIG_DIR/npm/npmrc" 0644 \
    "//registry.npmjs.org/:_authToken=${val}"
fi

# --- pypi-token (env-export for uv publish / twine) ---
if val=$(secret_value pypi-token) && [[ -n "$val" ]]; then
  log "writing pypi env-export"
  atomic_write "$CONFIG_DIR/env/pypi.sh" 0644 \
"export UV_PUBLISH_TOKEN=$(quote "$val")
export TWINE_USERNAME=__token__
export TWINE_PASSWORD=$(quote "$val")"
fi

# Docker Hub publishing intentionally NOT scaffolded in v1:
# the Docker CLI doesn't consume a single env var — `docker login` needs a
# username + password pair, and pushing typically expects auth in ~/.docker/
# config.json. Adding it cleanly requires a username secret too plus a
# pre-exec login step. Defer until there's an actual publish workflow.

# --- ntfy-topic (creds zone; only the alert script reads this) ---
if val=$(secret_value ntfy-topic) && [[ -n "$val" ]]; then
  atomic_write "$CREDS_DIR/ntfy-topic" 0600 "$val"
fi

log "refresh complete"

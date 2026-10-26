#!/usr/bin/env bash
# daemon/agent-token.sh — hand the sandbox a short-lived Infisical token
#
# The sandbox reads Infisical as its own machine identity, `<vps-name>-agent`
# (docs/SETUP.md "Infisical"), never as the owner. That identity's client
# secret stays here in the creds zone. This script logs the identity in and
# writes only the resulting access token where the sandbox can read it. The
# Infisical CLI in the sandbox picks it up through the `infisical` PATH shim
# (sandbox/wrappers/infisical).
#
# Why not keep the client secret in the sandbox: a client secret works from
# any machine until someone revokes it. An access token dies on its own. With
# the token TTL at 1 hour, a copy taken out of the sandbox stops working
# within the hour, and stopping the VPS cuts the sandbox off from Infisical
# without any step in the Infisical UI.
#
# Fails closed, deleting the token, when:
#   - the identity's token TTL or max TTL is above MAX_TTL (a longer-lived
#     token would undo the point of this script), or
#   - the identity can read the host-side `coding-agent-vps` project, which
#     holds the raw GitHub key (docs/REQUIREMENTS.md: the key never enters
#     the sandbox).
# Any other failure (network, Infisical down, a revoked client secret)
# alerts and keeps the current token, which still expires on its own. A
# short outage then costs nothing, and the 20-minute timer gets two more
# tries before the token runs out.
#
# Runs as user `creds` via agent-token.service, every 20 minutes
# (agent-token.timer). Not set up yet (no client secret file) is not an
# error: scripts/agent-identity.sh stores the secret and runs this once.

set -euo pipefail

# === Config ===
UAUTH_FILE="/etc/agent-vps/infisical-agent-uauth"  # source-able: AGENT_CLIENT_ID, AGENT_CLIENT_SECRET
CONFIG_FILE="/etc/agent-vps/config.env"            # source-able: INFISICAL_PROJECT_ID, INFISICAL_ENV, INFISICAL_URL
TOKEN_DIR="/var/lib/agent-vps/agent-token"         # 0755, bind-mounted read-only at /run/agent-token
TOKEN_FILE="$TOKEN_DIR/token"
API_URL_FILE="$TOKEN_DIR/api-url"                  # the region the token belongs to, for the sandbox CLI
ALERTS_SCRIPT="/opt/agent-vps/alerts/ntfy.sh"
# The timer refreshes every 20 minutes, so 1 hour leaves two retries.
MAX_TTL=3600

# === Helpers ===
log()   { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }
alert() { "$ALERTS_SCRIPT" "$1" "$2" 2>/dev/null || log "WARN: alert script failed"; }
fail()  { log "ERROR: $*"; alert "agent-token" "ERROR: $*"; exit 1; }                        # keeps the current token
die()   { rm -f "$TOKEN_FILE"; log "FATAL: $*"; alert "agent-token" "FATAL: $*"; exit 1; }  # policy violation: cut off now

# === Load config ===
if [[ ! -e "$UAUTH_FILE" ]]; then
  log "no $UAUTH_FILE yet; run scripts/agent-identity.sh as root"
  rm -f "$TOKEN_FILE"
  exit 0
fi
[[ -r "$CONFIG_FILE" ]] || fail "config file not found: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# shellcheck source=/dev/null
source "$UAUTH_FILE"
[[ -n "${AGENT_CLIENT_ID:-}" && -n "${AGENT_CLIENT_SECRET:-}" ]] \
  || fail "AGENT_CLIENT_ID or AGENT_CLIENT_SECRET not set in $UAUTH_FILE"
[[ -n "${INFISICAL_PROJECT_ID:-}" ]] || fail "INFISICAL_PROJECT_ID not set in $CONFIG_FILE"
INFISICAL_URL="${INFISICAL_URL:-https://app.infisical.com}"
INFISICAL_URL="${INFISICAL_URL%/}"
INFISICAL_ENV="${INFISICAL_ENV:-dev}"
# jq's env.X reads the process environment, not shell variables.
export AGENT_CLIENT_ID AGENT_CLIENT_SECRET

# === 1. Log in ===
# The secret goes to curl through a 0600 file, never through argv, so it is
# not in /proc/<pid>/cmdline. Same pattern as daemon/cred-daemon.sh.
TMPDIR_CLEAN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_CLEAN"' EXIT
BODY_FILE="$TMPDIR_CLEAN/auth-body"
( umask 077; jq -n '{clientId: env.AGENT_CLIENT_ID, clientSecret: env.AGENT_CLIENT_SECRET}' > "$BODY_FILE" )

AUTH_RESPONSE=$(curl -fsSL --max-time 30 --proto =https --proto-redir =https \
  -X POST "$INFISICAL_URL/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  --data-binary "@$BODY_FILE" \
  ) || fail "Infisical login failed (network, revoked client secret, or wrong client ID)"

jq -e '(.accessToken | type == "string" and length > 0)
       and (.expiresIn | type == "number")
       and (.accessTokenMaxTTL | type == "number")' <<<"$AUTH_RESPONSE" >/dev/null \
  || fail "Infisical login response has no accessToken, expiresIn or accessTokenMaxTTL (API change?)"

ttl=$(jq -r '.expiresIn' <<<"$AUTH_RESPONSE")
max_ttl=$(jq -r '.accessTokenMaxTTL' <<<"$AUTH_RESPONSE")
# A max TTL of 0 means renewable without limit.
if (( ttl > MAX_TTL || max_ttl == 0 || max_ttl > MAX_TTL )); then
  die "agent identity token TTL is ${ttl}s, max TTL ${max_ttl}s; set both to ${MAX_TTL} in Infisical (Universal Auth, Configuration)"
fi

HEADER_FILE="$TMPDIR_CLEAN/auth-header"
( umask 077; jq -r '"Authorization: Bearer " + .accessToken' <<<"$AUTH_RESPONSE" > "$HEADER_FILE" )

# === 2. Check the identity cannot read the host-side project ===
status=$(curl -sS --max-time 30 --proto =https --proto-redir =https \
  -o /dev/null -w '%{http_code}' \
  -H "@$HEADER_FILE" \
  "$INFISICAL_URL/api/v4/secrets?projectId=$INFISICAL_PROJECT_ID&environment=$INFISICAL_ENV" \
  ) || fail "Infisical access check failed (network)"
case "$status" in
  401|403|404) ;;
  2??) die "agent identity can read project $INFISICAL_PROJECT_ID (coding-agent-vps); remove it from that project in Infisical" ;;
  *)   fail "Infisical access check returned HTTP $status" ;;
esac

# === 3. Hand the token to the sandbox ===
# Same-directory temp file + rename, so a reader never sees a half-written
# token. The directory is bind-mounted (not the file), so the rename shows
# up inside the container. The API URL goes first, so a token never sits
# next to the wrong region.
tmp=$(mktemp "$API_URL_FILE.XXXXXX")
printf '%s/api' "$INFISICAL_URL" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$API_URL_FILE"

tmp=$(mktemp "$TOKEN_FILE.XXXXXX")
jq -j '.accessToken' <<<"$AUTH_RESPONSE" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$TOKEN_FILE"
log "wrote a ${ttl}s token for the sandbox"

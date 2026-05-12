#!/usr/bin/env bash
# alerts/ntfy.sh — publish alerts to ntfy.sh and log to stderr
# Usage: ntfy.sh <title> <message>
#
# The ntfy topic is fetched from Infisical by cred-daemon and stored
# at /var/lib/agent-vps/creds/ntfy-topic. If that file doesn't exist
# yet (e.g. first run before initial fetch), we still log to stderr
# so the alert isn't silently lost — systemd captures it in journal.

set -euo pipefail

NTFY_TOPIC_FILE="/var/lib/agent-vps/creds/ntfy-topic"
TITLE="${1:-coding-agent-vps}"
MESSAGE="${2:-(no message)}"

# Always log to stderr (captured by systemd journal)
printf '[%s] alert: %s: %s\n' "$(date -Iseconds)" "$TITLE" "$MESSAGE" >&2

# Best-effort ntfy publish if topic is available
if [[ -r "$NTFY_TOPIC_FILE" ]]; then
  topic=$(< "$NTFY_TOPIC_FILE")
  if [[ -n "$topic" ]]; then
    curl -fsSL --max-time 10 \
      -H "Title: $TITLE" \
      -d "$MESSAGE" \
      "https://ntfy.sh/$topic" >/dev/null 2>&1 || \
      printf '[%s] WARN: ntfy publish failed (network or topic invalid)\n' \
        "$(date -Iseconds)" >&2
  fi
fi

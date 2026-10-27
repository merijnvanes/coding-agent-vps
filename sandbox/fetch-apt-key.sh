#!/usr/bin/env bash
# sandbox/fetch-apt-key.sh — download an APT signing key and refuse it
# unless its primary key fingerprints are exactly the ones expected.
#
# Usage: fetch-apt-key.sh <url> <output keyring> <fingerprint>...
#
# The output is a binary keyring for `signed-by=`. Without the check, a
# swapped key at the vendor URL (or its CDN) would be trusted for every
# later `apt-get install` from that repo. A vendor that adds or rotates a
# key fails the build here; check the new key with the vendor and update
# the fingerprint in the Dockerfile.

set -euo pipefail

url=$1 out=$2
shift 2
want=$(printf '%s\n' "$@" | sort)

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

curl -fsSL --proto =https --proto-redir =https "$url" -o "$GNUPGHOME/key"
got=$(gpg --batch --quiet --show-keys --with-colons "$GNUPGHOME/key" 2>/dev/null \
  | awk -F: '$1 == "pub" { want_fpr = 1; next } $1 == "fpr" && want_fpr { print $10; want_fpr = 0 }' \
  | sort)

if [[ "$got" != "$want" ]]; then
  echo "fetch-apt-key: $url has primary keys:" >&2
  printf '  %s\n' ${got:-'(none)'} >&2
  echo "expected:" >&2
  printf '  %s\n' "$@" >&2
  exit 1
fi

# Import and export: the output is binary whether the vendor serves an
# armored or a binary key.
gpg --batch --quiet --import "$GNUPGHOME/key" 2>/dev/null
gpg --batch --export "$@" > "$out"
chmod 0644 "$out"

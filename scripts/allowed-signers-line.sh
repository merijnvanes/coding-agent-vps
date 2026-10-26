#!/usr/bin/env bash
# scripts/allowed-signers-line.sh — runs on YOUR LAPTOP. Prints the
# /etc/agent-vps/allowed-signers line for this checkout's git signing key
# (see scripts/cloud-init-tasks.sh step 2d). provision.sh puts it in the
# cloud-init user-data; docs/USAGE.md "Signed updates" pastes it by hand.
#
# Reads git config, never a repo file, so a pushed commit cannot choose
# the key that vouches for it. Handles every user.signingkey form git
# accepts for gpg.format=ssh: `key::<public key>`, a bare public key, a
# public key file, or a private key file.
#
# Usage: ./scripts/allowed-signers-line.sh

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

die() { echo "ERROR: $*" >&2; echo "See docs/SETUP.md Phase 5 \"Sign commits\"." >&2; exit 1; }

[[ "$(git config gpg.format || true)" == ssh ]] || die "gpg.format is not ssh in this checkout"
key=$(git config user.signingkey) || die "user.signingkey is not set in this checkout"
email=$(git config user.email) || die "user.email is not set in this checkout"

is_public() { [[ "$1" =~ ^(ssh-|ecdsa-|sk-) ]]; }
# Like git: only `key::` and the legacy `ssh-` prefix mark a literal key;
# anything else is a file name, even one that starts with `ecdsa-`.
case "$key" in
  key::*) pub=${key#key::} ;;
  ssh-*)  pub=$key ;;
  *)
    file=$(git config --type=path user.signingkey)   # git's own ~ and ~user expansion
    [[ -r "$file" ]] || die "cannot read signing key file $file"
    first=$(head -n1 "$file")
    if is_public "$first"; then
      pub=$first
    elif [[ -r "${file}.pub" ]]; then
      pub=$(head -n1 "${file}.pub")
    else
      pub=$(ssh-keygen -y -f "$file")
    fi ;;
esac
is_public "$pub" || die "could not get a public key from user.signingkey"

read -r type blob _ <<<"$pub"
printf '%s namespaces="git" %s %s\n' "$email" "$type" "$blob"

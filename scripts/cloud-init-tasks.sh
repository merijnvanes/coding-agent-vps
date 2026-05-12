#!/usr/bin/env bash
# scripts/cloud-init-tasks.sh — host setup, runs once at cloud-init time
#
# Idempotent: safe to re-run. Does NOT touch credentials — that's
# bootstrap.sh's job, run manually after the user SSHes in.
#
# What this does, in order:
#   1. Create creds + merijn users
#   2. Pre-create the on-disk directory tree with correct ownership/modes
#   3. Configure subuid/subgid for merijn (default range only — the
#      previous agent-sockets-group + custom subgid trick was dropped in
#      favor of a 0666 ssh-agent socket; see daemon/ssh-agent-creds.service)
#   4. Install Docker, disable the rootful daemon, set up rootless for merijn
#   5. Build the sandbox image (no registry — built locally)
#   6. Install + enable systemd units
#   7. Print next-step instructions

set -euo pipefail

log() { printf '[cloud-init-tasks] %s\n' "$*" >&2; }
log "starting host setup"

# === 1. Users ===

# creds: dedicated system user for the credential daemon. NOT a login user.
id -u creds >/dev/null 2>&1 \
  || useradd \
       --system \
       --home-dir /var/lib/agent-vps \
       --no-create-home \
       --shell /usr/sbin/nologin \
       creds

# merijn: human SSH user. Tailscale SSH authenticates via tailnet identity
# (no authorized_keys management). Sudo for admin tasks.
id -u merijn >/dev/null 2>&1 \
  || useradd \
       --create-home \
       --shell /bin/bash \
       --groups sudo \
       merijn

# Passwordless sudo for merijn (Tailscale SSH is the auth gate)
install -m 0440 /dev/stdin /etc/sudoers.d/merijn <<<'merijn ALL=(ALL) NOPASSWD:ALL'

# === 2. Directory tree ===

install -d -m 0755 -o root   -g root   /etc/agent-vps
install -d -m 0755 -o root   -g root   /var/lib/agent-vps
install -d -m 0700 -o creds  -g creds  /var/lib/agent-vps/creds
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config/env
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config/gcloud
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config/npm
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/sockets

# Pre-create the npmrc as an empty file so docker-compose's file bind mount
# has a source to bind even when npm-token isn't in Infisical yet. Docker
# would otherwise create a directory at this path → npm sees `~/.npmrc` as a
# directory and breaks.
install -m 0644 -o creds -g creds /dev/null /var/lib/agent-vps/agent-config/npm/npmrc

# Project workspace. Mode 0777 so the rootless-Docker-mapped sandbox UID
# (host UID merijn_subuid_base + 999) can write here in addition to host
# merijn. On this single-user box the practical access set is unchanged
# (only merijn and rootless containers ever access this dir).
install -d -m 0777 -o merijn -g merijn /srv/dev
install -d -m 0777 -o merijn -g merijn /srv/dev/projects

# === 3. subuid / subgid for rootless Docker ===
# Default range — required by dockerd-rootless-setuptool.sh below. No custom
# GID mapping needed any more (the agent-sockets-group approach was dropped
# in favor of a 0666 ssh-agent socket; see daemon/ssh-agent-creds.service).
grep -q '^merijn:100000:' /etc/subuid || echo "merijn:100000:65536" >> /etc/subuid
grep -q '^merijn:100000:' /etc/subgid || echo "merijn:100000:65536" >> /etc/subgid

# === 4. Docker + rootless setup ===

if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker engine"
  curl -fsSL https://get.docker.com | sh
fi

# We use rootless Docker; disable the rootful daemon.
systemctl disable --now docker.service docker.socket 2>/dev/null || true

# Allow merijn's user systemd units to run without an active login session.
loginctl enable-linger merijn

# Configure rootless Docker for merijn (idempotent: re-running is harmless).
log "configuring rootless Docker for merijn"
sudo -u merijn -H XDG_RUNTIME_DIR=/run/user/$(id -u merijn) \
  bash -lc 'dockerd-rootless-setuptool.sh install --force 2>/dev/null || dockerd-rootless-setuptool.sh install'

sudo -u merijn -H XDG_RUNTIME_DIR=/run/user/$(id -u merijn) \
  bash -lc 'systemctl --user enable --now docker'

# === 5. Build the sandbox image ===
log "building sandbox image (~5–10 min on a CX22)"
sudo -u merijn -H XDG_RUNTIME_DIR=/run/user/$(id -u merijn) \
  bash -lc 'cd /opt/agent-vps && docker build -t coding-agent-vps/sandbox:latest ./sandbox'

# === 6. systemd units ===
log "installing systemd units"
install -m 0644 /opt/agent-vps/daemon/cred-daemon.service     /etc/systemd/system/
install -m 0644 /opt/agent-vps/daemon/cred-daemon.timer       /etc/systemd/system/
install -m 0644 /opt/agent-vps/daemon/ssh-agent-creds.service /etc/systemd/system/
systemctl daemon-reload
# ssh-agent for creds — must be running before cred-daemon attempts ssh-add
systemctl enable --now ssh-agent-creds.service
# Daily refresh timer. cred-daemon.service itself is NOT enabled directly —
# it's a oneshot triggered by the timer and by manual `systemctl start`.
# --now starts the timer in this boot so the first refresh schedule is live
# without waiting for a reboot.
systemctl enable --now cred-daemon.timer

log "cloud-init-tasks complete."
log "Next: SSH in via Tailscale, then run: sudo bash /opt/agent-vps/scripts/bootstrap.sh"

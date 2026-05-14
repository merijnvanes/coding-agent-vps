#!/usr/bin/env bash
# scripts/cloud-init-tasks.sh — host setup, runs once at cloud-init time
#
# Idempotent: safe to re-run. Does NOT touch credentials — that's
# bootstrap.sh's job, run manually after the user SSHes in.
#
# What this does, in order:
#   1. Create creds + dev users
#   2. Pre-create the on-disk directory tree with correct ownership/modes
#   3. Configure subuid/subgid for dev (default range only — the
#      previous agent-sockets-group + custom subgid trick was dropped in
#      favor of a 0666 ssh-agent socket; see daemon/ssh-agent-creds.service)
#   4. Install Docker, disable the rootful daemon, set up rootless for dev
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

# dev: human SSH user. Tailscale SSH authenticates via tailnet identity
# (no authorized_keys management). Sudo for admin tasks.
id -u dev >/dev/null 2>&1 \
  || useradd \
       --create-home \
       --shell /bin/bash \
       --groups sudo \
       dev

# Passwordless sudo for dev (Tailscale SSH is the auth gate)
install -m 0440 /dev/stdin /etc/sudoers.d/dev <<<'dev ALL=(ALL) NOPASSWD:ALL'

# === 2. Directory tree ===

install -d -m 0755 -o root   -g root   /etc/agent-vps
install -d -m 0755 -o root   -g root   /var/lib/agent-vps
install -d -m 0700 -o creds  -g creds  /var/lib/agent-vps/creds
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config/env
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config/gcloud
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/sockets

# Project workspace. Mode 0777 so the rootless-Docker-mapped sandbox UID
# (host UID dev_subuid_base + 999) can write here in addition to host
# dev. On this single-user box the practical access set is unchanged
# (only dev and rootless containers ever access this dir).
install -d -m 0777 -o dev -g dev /srv/dev
install -d -m 0777 -o dev -g dev /srv/dev/projects

# === 3. subuid / subgid for rootless Docker ===
# Default range — required by dockerd-rootless-setuptool.sh below. No custom
# GID mapping needed any more (the agent-sockets-group approach was dropped
# in favor of a 0666 ssh-agent socket; see daemon/ssh-agent-creds.service).
grep -q '^dev:100000:' /etc/subuid || echo "dev:100000:65536" >> /etc/subuid
grep -q '^dev:100000:' /etc/subgid || echo "dev:100000:65536" >> /etc/subgid

# === 4. Docker + rootless setup ===

if ! command -v docker >/dev/null 2>&1; then
  # Pinned versions — refresh at setup time per docs/SETUP.md "Refresh
  # pinned versions". docker-ce / docker-ce-cli / docker-ce-rootless-extras
  # are released together and share a version string; the other three have
  # independent release cadences. Lookup: query the Docker apt repo
  # (`apt-cache madison <pkg>` after adding the repo, or curl the noble
  # Packages file under download.docker.com/linux/ubuntu/dists/noble/).
  DOCKER_CE_VERSION="5:29.4.2-1~ubuntu.24.04~noble"
  CONTAINERD_VERSION="2.2.2-1~ubuntu.24.04~noble"
  DOCKER_BUILDX_VERSION="0.33.0-1~ubuntu.24.04~noble"
  DOCKER_COMPOSE_VERSION="5.1.2-1~ubuntu.24.04~noble"

  # Manual Docker APT setup (no `get.docker.com | sh`). Inlines what the
  # convenience script does: fetch the static GPG key file, write keyring
  # + sources.list, apt install. Subsequent apt updates are GPG-verified.
  log "installing Docker engine via manual APT setup"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  arch=$(dpkg --print-architecture)
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  # docker-ce-rootless-extras provides dockerd-rootless-setuptool.sh, which
  # we invoke below to wire up rootless Docker for the dev user. The Docker
  # convenience script installed this implicitly; doing apt by hand we have
  # to name it.
  apt-get install -y --no-install-recommends \
    docker-ce="${DOCKER_CE_VERSION}" \
    docker-ce-cli="${DOCKER_CE_VERSION}" \
    containerd.io="${CONTAINERD_VERSION}" \
    docker-buildx-plugin="${DOCKER_BUILDX_VERSION}" \
    docker-compose-plugin="${DOCKER_COMPOSE_VERSION}" \
    docker-ce-rootless-extras="${DOCKER_CE_VERSION}"
fi

# We use rootless Docker; disable the rootful daemon.
systemctl disable --now docker.service docker.socket 2>/dev/null || true

# Allow dev's user systemd units to run without an active login session.
loginctl enable-linger dev

# Start dev's user systemd manager NOW (linger only takes effect on the
# next boot; we need it in this boot too). Without this,
# dockerd-rootless-setuptool.sh detects no systemd, falls back to "manual
# mode" without installing the docker.service user unit, and the next
# `systemctl --user enable --now docker` fails.
MERIJN_UID=$(id -u dev)
systemctl start "user@${MERIJN_UID}.service"
# Wait for the user systemd private socket to appear (up to 30s).
for _ in $(seq 1 30); do
  [[ -S "/run/user/${MERIJN_UID}/systemd/private" ]] && break
  sleep 1
done
[[ -S "/run/user/${MERIJN_UID}/systemd/private" ]] \
  || { log "ERROR: dev user systemd did not start within 30s"; exit 1; }

# Configure rootless Docker for dev (idempotent: re-running is harmless).
log "configuring rootless Docker for dev"
sudo -u dev -H XDG_RUNTIME_DIR=/run/user/$(id -u dev) \
  bash -lc 'dockerd-rootless-setuptool.sh install --force 2>/dev/null || dockerd-rootless-setuptool.sh install'

sudo -u dev -H XDG_RUNTIME_DIR=/run/user/$(id -u dev) \
  bash -lc 'systemctl --user enable --now docker'

# === 5. Build the sandbox image ===
log "building sandbox image (~5–10 min on a CX23)"
sudo -u dev -H XDG_RUNTIME_DIR=/run/user/$(id -u dev) \
  bash -lc 'cd /opt/agent-vps && docker build -t coding-agent-vps/sandbox:latest ./sandbox'

# === 6. systemd units ===
log "installing systemd units"
install -m 0644 /opt/agent-vps/daemon/cred-daemon.service      /etc/systemd/system/
install -m 0644 /opt/agent-vps/daemon/cred-daemon.timer        /etc/systemd/system/
install -m 0644 /opt/agent-vps/daemon/ssh-agent-creds.service  /etc/systemd/system/
install -m 0644 /opt/agent-vps/daemon/ssh-agent-bridge.service /etc/systemd/system/
systemctl daemon-reload
# ssh-agent for creds — must be running before cred-daemon attempts ssh-add
systemctl enable --now ssh-agent-creds.service
# socat bridge — must be running before the sandbox can use the agent
# (ssh-agent's peer-UID check rejects direct sandbox connections; see
#  daemon/ssh-agent-bridge.service for the rationale)
systemctl enable --now ssh-agent-bridge.service
# Daily refresh timer. --now starts it in this boot so the schedule is live
# without waiting for a reboot.
systemctl enable --now cred-daemon.timer
# Also enable cred-daemon.service for boot. It's a oneshot wanted by
# multi-user.target — running at boot ensures ssh-agent gets the GitHub
# SSH key loaded after every reboot (otherwise the agent stays empty
# until the next timer fire or a manual `systemctl start cred-daemon`).
# We don't `--now` here because the bootstrap secret doesn't exist yet
# at cloud-init time; bootstrap.sh triggers the first manual run.
systemctl enable cred-daemon.service

log "cloud-init-tasks complete."
log "Next: SSH in via Tailscale, then run: sudo bash /opt/agent-vps/scripts/bootstrap.sh"

#!/usr/bin/env bash
# scripts/cloud-init-tasks.sh — host setup, runs once at cloud-init time
#
# Idempotent: safe to re-run. Does NOT touch credentials — that's
# bootstrap.sh's job, run manually after the user SSHes in.
#
# What this does, in order:
#   1. Configure host memory: 2 GB swapfile + vm.swappiness=10;
#      enable persistent journald so post-incident logs survive reboot
#   2. Create creds + dev users
#   3. Pre-create the on-disk directory tree with correct ownership/modes
#   4. Configure subuid/subgid for dev (default range only — the
#      previous agent-sockets-group + custom subgid trick was dropped in
#      favor of a 0666 ssh-agent socket; see daemon/ssh-agent-creds.service)
#   5. Install Docker, disable the rootful daemon, set up rootless for dev
#   6. Build the sandbox image (no registry — built locally)
#   7. Install + enable systemd units
#   8. Print next-step instructions

set -euo pipefail

log() { printf '[cloud-init-tasks] %s\n' "$*" >&2; }
log "starting host setup"

# === 1. Memory: swap + swappiness ===
#
# Why: with 4 GB RAM and no swap, the kernel cannot reclaim memory by
# paging out anonymous pages — its only reclaim option is evicting
# clean file-cache pages. Under pressure that becomes page-cache
# thrashing: mmap'd executables (Node, Claude/Codex JS bundles) get
# evicted and immediately refaulted, pegging CPU at 100% iowait. The
# OOM killer never fires because nothing technically fails to allocate
# (processes are just refaulting pages they already mapped), so the
# system stays stuck indefinitely. A 2 GB swapfile gives the kernel
# somewhere to put dirty anonymous pages and lets the OOM killer fire
# cleanly when both RAM and swap are exhausted. swappiness=10 keeps
# swap as a last-resort cushion rather than letting the kernel page
# out proactively. Paired with the cgroup mem_limit in
# docker-compose.yml — together they ensure exhaustion kills one
# in-container process, not the host.

SWAPFILE=/swapfile
SWAP_SIZE_MB=2048
# Detect whether $SWAPFILE is already a valid swap area, not just present.
# Guards against the partial-init case where `fallocate` succeeded on a
# prior run but `mkswap` did not — leaving a plain file that `swapon`
# would reject.
needs_init=0
if [[ ! -f $SWAPFILE ]]; then
  needs_init=1
elif ! blkid -p "$SWAPFILE" 2>/dev/null | grep -q 'TYPE="swap"'; then
  log "WARNING: $SWAPFILE exists but is not a valid swap area; recreating"
  swapon --show=NAME --noheadings | grep -qx "$SWAPFILE" && swapoff "$SWAPFILE"
  rm -f "$SWAPFILE"
  needs_init=1
fi
if (( needs_init )); then
  log "creating ${SWAP_SIZE_MB}MB swapfile at $SWAPFILE"
  fallocate -l "${SWAP_SIZE_MB}M" $SWAPFILE
  chmod 0600 $SWAPFILE
  mkswap $SWAPFILE >/dev/null
fi
# Activate if not already active (idempotent).
swapon --show=NAME --noheadings | grep -qx "$SWAPFILE" || swapon $SWAPFILE
# Persist across reboots.
grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab

SYSCTL_DROPIN=/etc/sysctl.d/99-coding-agent-vps.conf
if [[ ! -f $SYSCTL_DROPIN ]] || ! grep -q '^vm.swappiness=10$' $SYSCTL_DROPIN; then
  log "writing $SYSCTL_DROPIN"
  cat > $SYSCTL_DROPIN <<'EOF'
# Paired with /swapfile — see scripts/cloud-init-tasks.sh step 1.
# Swap is an emergency cushion for the OOM killer, not active memory.
vm.swappiness=10
EOF
fi
# Always apply — cheap, idempotent, and reasserts the runtime value even
# if it drifted (e.g. someone ran `sysctl -w` out of band, or a prior
# run wrote the drop-in but bailed before reloading).
sysctl -p $SYSCTL_DROPIN >/dev/null

# Persistent journald — so a previous-boot journal (`journalctl --boot=-1`)
# survives a hard `hcloud server reset`, enabling postmortems for the
# very failure mode this step is designed to prevent. Stock Ubuntu noble
# already ships with /var/log/journal present, but we don't want to
# depend on a third party's default — create it explicitly. journald
# auto-flips to persistent storage once the directory exists; the
# restart picks it up in this boot without waiting for reboot.
if [[ ! -d /var/log/journal ]]; then
  log "enabling persistent journald (/var/log/journal)"
  install -d -m 2755 -o root -g systemd-journal /var/log/journal
  systemctl restart systemd-journald
fi

# === 2. Users ===

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

# === 3. Directory tree ===

install -d -m 0755 -o root   -g root   /etc/agent-vps
install -d -m 0755 -o root   -g root   /var/lib/agent-vps
install -d -m 0700 -o creds  -g creds  /var/lib/agent-vps/creds
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/agent-config/env
install -d -m 0755 -o creds  -g creds  /var/lib/agent-vps/sockets

# Project workspace. Mode 0777 so the rootless-Docker-mapped sandbox UID
# (host UID dev_subuid_base + 999) can write here in addition to host
# dev. On this single-user box the practical access set is unchanged
# (only dev and rootless containers ever access this dir).
install -d -m 0777 -o dev -g dev /srv/dev
install -d -m 0777 -o dev -g dev /srv/dev/projects

# === 4. subuid / subgid for rootless Docker ===
# Default range — required by dockerd-rootless-setuptool.sh below. No custom
# GID mapping needed any more (the agent-sockets-group approach was dropped
# in favor of a 0666 ssh-agent socket; see daemon/ssh-agent-creds.service).
grep -q '^dev:100000:' /etc/subuid || echo "dev:100000:65536" >> /etc/subuid
grep -q '^dev:100000:' /etc/subgid || echo "dev:100000:65536" >> /etc/subgid

# === 5. Docker + rootless setup ===

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

# Assert the cgroup memory controller is delegated to dev's user slice.
# Without this, `mem_limit` in docker-compose.yml is silently a no-op
# and the page-cache-thrashing failure mode (see step 1 rationale)
# returns. Ubuntu noble's stock systemd delegates `memory pids cpu`,
# but we don't want to rely on the distro default — fail loudly here
# rather than discover it during the next incident.
DEV_UID=$(id -u dev)
DELEGATED=$(cat "/sys/fs/cgroup/user.slice/user-${DEV_UID}.slice/cgroup.controllers" 2>/dev/null || echo "")
if ! grep -qw memory <<<"$DELEGATED"; then
  log "ERROR: memory cgroup controller not delegated to dev (got: '${DELEGATED}')"
  log "       docker-compose.yml mem_limit would be silently ignored — aborting"
  exit 1
fi

# Install the sandbox slice into dev's user systemd. The slice enforces
# memory.swap.max=0 on the container, denying any swap allowance.
# Required because Docker's `memswap_limit` is silently ignored on
# rootless Docker + cgroup v2 — see daemon/sandbox.slice for the empirical
# story. Must be loaded before the first `docker compose up -d`, since
# compose's `cgroup_parent: sandbox.slice` references a slice that must
# already exist in systemd.
log "installing sandbox.slice into dev's user systemd"
DEV_HOME=$(getent passwd dev | cut -d: -f6)
install -d -m 0755 -o dev -g dev "$DEV_HOME/.config/systemd/user"
install -m 0644 -o dev -g dev /opt/agent-vps/daemon/sandbox.slice \
  "$DEV_HOME/.config/systemd/user/sandbox.slice"
# daemon-reload picks up the file change. `set-property` forces the
# kernel cgroup file to be re-written from the unit spec on re-runs —
# `daemon-reload` alone does NOT propagate slice property changes to a
# live slice (and we can't `restart` it without killing the sandbox
# container that's a member). Cheap, idempotent, and means a future
# edit to the slice file actually takes effect on the next script run.
sudo -u dev -H XDG_RUNTIME_DIR=/run/user/$DEV_UID bash -lc '
  systemctl --user daemon-reload
  systemctl --user is-active --quiet sandbox.slice || systemctl --user start sandbox.slice
  systemctl --user set-property sandbox.slice MemorySwapMax=0 MemoryHigh=2700M
'

# === 6. Build the sandbox image ===
log "building sandbox image (~5–10 min on a CX23)"
sudo -u dev -H XDG_RUNTIME_DIR=/run/user/$(id -u dev) \
  bash -lc 'cd /opt/agent-vps && docker build -t coding-agent-vps/sandbox:latest ./sandbox'

# === 7. systemd units ===
log "installing systemd units"
install -m 0644 /opt/agent-vps/daemon/cred-daemon.service      /etc/systemd/system/
install -m 0644 /opt/agent-vps/daemon/cred-daemon.timer        /etc/systemd/system/
install -m 0644 /opt/agent-vps/daemon/ssh-agent-creds.service  /etc/systemd/system/
install -m 0644 /opt/agent-vps/daemon/ssh-agent-bridge.service /etc/systemd/system/
systemctl daemon-reload

# Enable for next boot, then start only if not already active.
#
# Why split, not `enable --now`: re-running this script on a healthy
# host (see docs/USAGE.md "cloud-init status shows error" recovery)
# would otherwise force a start cycle on the already-running ssh-agent
# units. If systemd loses track of the live instance for any reason
# during that cycle, the new ssh-agent's bind() fails because the old
# instance still owns its Unix socket, the unit lands in `failed`, and
# sandbox git push breaks with "Permission denied (publickey)". The
# Unix-socket cleanup that handles the stale-socket case lives in the
# service units themselves (`ExecStartPre=rm -f <socket>` in
# daemon/ssh-agent-creds.service and daemon/ssh-agent-bridge.service),
# so any start path is self-healing; this loop layer just avoids
# starting an instance we don't need to disturb at all.
#
# Caveat: after this script overwrites a service file via `install`
# and `daemon-reload` picks up the new metadata, an already-running
# instance keeps the OLD runtime behavior until manually restarted.
# Service-file changes that need to take effect immediately require:
#   sudo systemctl restart ssh-agent-creds.service ssh-agent-bridge.service
# Acceptable trade because restart clears any ssh-agent keys cred-daemon
# had loaded — forcing it silently on every script re-run is worse.
#
# Ordering matters: ssh-agent-creds first (the bridge's socat connects
# to its socket), bridge second, timer last. cred-daemon.service itself
# is enabled separately below (intentionally not started — the
# bootstrap secret doesn't exist yet at cloud-init time).
for unit in ssh-agent-creds.service ssh-agent-bridge.service cred-daemon.timer; do
  systemctl enable "$unit"
  systemctl is-active --quiet "$unit" || systemctl start "$unit"
done

# cred-daemon.service is a oneshot wanted by multi-user.target — running
# at boot ensures ssh-agent gets the GitHub SSH key loaded after every
# reboot (otherwise the agent stays empty until the next timer fire or
# a manual `systemctl start cred-daemon`). We don't start it here
# because the bootstrap secret doesn't exist yet at cloud-init time;
# bootstrap.sh triggers the first manual run.
systemctl enable cred-daemon.service

log "cloud-init-tasks complete."
log "Next: SSH in via Tailscale, then run: sudo bash /opt/agent-vps/scripts/bootstrap.sh"

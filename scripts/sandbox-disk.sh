#!/usr/bin/env bash
# scripts/sandbox-disk.sh — give the sandbox its own fixed-size filesystem
#
# Usage (as root):
#   sandbox-disk.sh ensure    # create it on a new VPS, mount it on an existing one
#   sandbox-disk.sh migrate   # move an older VPS's data onto it (stops the sandbox)
#
# Everything the sandbox can fill lives on one ext4 image file, mounted
# with a loop device: dev's rootless Docker data (images, build cache, the
# container's writable layer, the named volumes) and /srv/dev/projects
# (/work in the sandbox). A runaway agent fills that image and gets
# ENOSPC; the root filesystem keeps its free space, so journald, the
# credential daemons and apt keep working.
#
#   /var/lib/agent-vps/sandbox-disk.img   the image, preallocated
#   /srv/sandbox-disk                     where it is mounted
#     docker/   → bind-mounted on /home/dev/.local/share/docker
#     projects/ → bind-mounted on /srv/dev/projects
#
# Size: the root filesystem minus a host reserve of 40% (at least 15 GiB).
# A 75 GB disk gives the sandbox 44 GiB; the 40 GB cx23 default gives 22.
# Override with SANDBOX_DISK_GB. The image is preallocated, so the host
# cannot later run out of the space the sandbox was promised.
#
# The three mounts are in /etc/fstab with nofail, so a broken image never
# stops the VPS from booting (Tailscale SSH must come up). They are
# ordered before dev's user manager, which starts rootless Docker. The
# mount points underneath are immutable (chattr +i): if a mount is
# missing, Docker and the sandbox fail to write there instead of filling
# the root filesystem.

set -euo pipefail

IMAGE=/var/lib/agent-vps/sandbox-disk.img
MNT=/srv/sandbox-disk
DOCKER_DIR=/home/dev/.local/share/docker
PROJECTS_DIR=/srv/dev/projects
FSTAB_MARK="# coding-agent-vps sandbox disk (scripts/sandbox-disk.sh)"

log() { printf '[%s] sandbox-disk: %s\n' "$(date -Iseconds)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"
DEV_UID=$(id -u dev) || die "no dev user"

configured() { grep -qxF "$FSTAB_MARK" /etc/fstab; }

# A directory counts as empty when it is missing or has no entries.
is_empty() { [[ ! -d "$1" ]] || [[ -z "$(ls -A "$1")" ]]; }

image_size_gb() {
  if [[ -n "${SANDBOX_DISK_GB:-}" ]]; then
    [[ "$SANDBOX_DISK_GB" =~ ^[0-9]+$ ]] || die "SANDBOX_DISK_GB must be a whole number"
    echo "$SANDBOX_DISK_GB"; return
  fi
  local total_gb reserve_gb
  total_gb=$(( $(df -B1 --output=size / | tail -1) / 1024 / 1024 / 1024 ))
  reserve_gb=$(( total_gb * 40 / 100 ))
  (( reserve_gb >= 15 )) || reserve_gb=15
  (( total_gb - reserve_gb >= 10 )) || die "root filesystem is ${total_gb} GiB; too small for a sandbox disk"
  echo $(( total_gb - reserve_gb ))
}

create_image() {
  local size_gb=$1 free_gb
  free_gb=$(( $(df -B1 --output=avail / | tail -1) / 1024 / 1024 / 1024 ))
  (( free_gb >= size_gb + 5 )) \
    || die "need ${size_gb} GiB plus 5 GiB headroom free on /, have ${free_gb} GiB"
  log "creating a ${size_gb} GiB image at $IMAGE"
  install -d -m 0755 -o root -g root /var/lib/agent-vps
  ( umask 077; fallocate -l "${size_gb}G" "$IMAGE" )
  # -m 0: no root-reserved blocks; nothing on it runs as root.
  mkfs.ext4 -q -F -m 0 -L sandbox-disk "$IMAGE"
  install -d -m 0755 -o root -g root "$MNT"
  mount -o loop "$IMAGE" "$MNT"
  install -d -m 0710 -o dev -g dev "$MNT/docker"
  install -d -m 0770 -o dev -g dev "$MNT/projects"
}

# Empty, immutable mount points, then the fstab entries, then mount.
install_mounts() {
  local d before="x-systemd.before=user@${DEV_UID}.service"
  install -d -m 0711 -o dev -g dev /home/dev/.local /home/dev/.local/share
  install -d -m 0755 -o dev -g dev /srv/dev
  for d in "$DOCKER_DIR" "$PROJECTS_DIR"; do
    is_empty "$d" || die "$d is not empty"
    install -d -m 0700 -o root -g root "$d"
    chattr +i "$d"
  done
  mountpoint -q "$MNT" && umount "$MNT"
  {
    echo "$FSTAB_MARK"
    echo "$IMAGE $MNT ext4 loop,nofail,$before 0 0"
    echo "$MNT/docker $DOCKER_DIR none bind,nofail,x-systemd.requires-mounts-for=$MNT,$before 0 0"
    echo "$MNT/projects $PROJECTS_DIR none bind,nofail,x-systemd.requires-mounts-for=$MNT,$before 0 0"
  } >> /etc/fstab
  systemctl daemon-reload
  mount_all
}

mount_all() {
  local d
  for d in "$MNT" "$DOCKER_DIR" "$PROJECTS_DIR"; do
    mountpoint -q "$d" || mount "$d"
    mountpoint -q "$d" || die "$d is not mounted"
  done
  log "mounted: $(df -h --output=size,used,avail "$MNT" | tail -1)"
}

as_dev() { sudo -u dev -H XDG_RUNTIME_DIR="/run/user/$DEV_UID" "$@"; }

case "${1:-}" in
  ensure)
    if configured; then
      mount_all
    elif is_empty "$DOCKER_DIR" && is_empty "$PROJECTS_DIR"; then
      create_image "$(image_size_gb)"
      install_mounts
    else
      log "WARN: Docker data or projects already exist outside a sandbox disk."
      log "WARN: run 'sudo bash /opt/agent-vps/scripts/sandbox-disk.sh migrate' (stops the sandbox)."
    fi
    ;;

  migrate)
    configured && { mount_all; log "already on a sandbox disk"; exit 0; }
    command -v rsync >/dev/null || apt-get install -y --no-install-recommends rsync
    size_gb=$(image_size_gb)
    used_gb=$(( $(du -sxB1 "$DOCKER_DIR" "$PROJECTS_DIR" | awk '{ s += $1 } END { print s }') / 1024 / 1024 / 1024 ))
    (( used_gb + 5 <= size_gb )) \
      || die "Docker data and projects use ${used_gb} GiB; the ${size_gb} GiB disk would be nearly full. Prune first (docker builder prune)."

    log "stopping the sandbox and rootless Docker"
    as_dev docker stop sandbox >/dev/null 2>&1 || true
    as_dev systemctl --user stop docker.service

    create_image "$size_gb"
    log "copying $DOCKER_DIR and $PROJECTS_DIR (${used_gb} GiB)"
    # -HAX: hard links, ACLs and xattrs (overlay layers use them);
    # --numeric-ids: the sandbox's files belong to subuids with no name.
    rsync -aHAX --numeric-ids "$DOCKER_DIR/" "$MNT/docker/"
    rsync -aHAX --numeric-ids "$PROJECTS_DIR/" "$MNT/projects/"

    # The old copies stay until you have checked the sandbox.
    mv "$DOCKER_DIR" "$DOCKER_DIR.pre-sandbox-disk"
    mv "$PROJECTS_DIR" "$PROJECTS_DIR.pre-sandbox-disk"
    install_mounts

    log "starting rootless Docker and the sandbox"
    as_dev systemctl --user start docker.service
    as_dev bash -c 'cd /opt/agent-vps && docker compose up -d'
    log "done. Check the sandbox, then free the space of the old copies:"
    log "  sudo rm -rf $DOCKER_DIR.pre-sandbox-disk $PROJECTS_DIR.pre-sandbox-disk"
    ;;

  *)
    echo "usage: $0 ensure|migrate" >&2
    exit 2
    ;;
esac

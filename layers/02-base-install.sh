#!/usr/bin/env bash
#
# layers/02-base-install.sh
# Bootstraps the Arch base system and stages the repository payload.
# Runs on the live ISO host, invoked by icarus-assemble.sh.
#
set -euo pipefail

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/mnt/var/log/icarus}"
ICARUS_REPO_PATH="${ICARUS_REPO_PATH:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SENTINEL="${ICARUS_LOG_DIR}/layer-2-base.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-1-partition.done"

TARGET="${ICARUS_TARGET_DEVICE:-}"

log() { echo "[layer-2] $*"; }
fatal() { echo "[layer-2] FATAL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

[[ -f "$PREV_SENTINEL" ]] || fatal "Layer 1 sentinel not found (${PREV_SENTINEL}). Run Layer 1 first."
mountpoint -q /mnt || fatal "/mnt is not a mountpoint. Layer 1 must mount the target root there."

FREE_KB=$(df --output=avail /mnt | tail -1 | tr -d ' ')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
[[ $FREE_GB -ge 8 ]] || fatal "/mnt only has ${FREE_GB}GB free. At least 8GB is required for the base install."

log "Refreshing host keyring to avoid signature failures on a rolling release live ISO..."
timedatectl set-ntp true || log "WARNING: could not enable NTP sync (no network yet?). Continuing."

log "Disabling IPv6 to prevent VirtualBox NAT blackhole freezes..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1

log "Optimizing pacman for reliable downloads..."
# Enable parallel downloads
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# ---------------------------------------------------------------------------
# Detect whether we're running from a CachyOS live ISO or a vanilla Arch
# ISO — they ship different keyrings, repos, and package names. Rather
# than forcing vanilla Arch mirrors onto a CachyOS ISO (which would lose
# access to CachyOS-optimized packages and potentially break keyring
# trust), we detect and adapt.
# ---------------------------------------------------------------------------
IS_CACHYOS=0
if grep -qi "cachyos" /etc/os-release 2>/dev/null \
   || pacman -Qi cachyos-keyring &>/dev/null; then
    IS_CACHYOS=1
    log "Detected CachyOS live ISO — using CachyOS repos and keyring."
else
    log "Detected vanilla Arch live ISO — using upstream Arch mirrors."
fi

if [[ $IS_CACHYOS -eq 1 ]]; then
    # CachyOS already has its mirrors and keyring configured in the live ISO.
    # Just refresh and make sure the keyring is current.
    pacman-key --init
    pacman-key --populate archlinux cachyos
    pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist || log "WARNING: could not refresh CachyOS keyring — continuing with what the live ISO shipped."
else
    # Force rock-solid global CDN mirrors for vanilla Arch
    cat > /etc/pacman.d/mirrorlist << 'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF
    pacman-key --init
    pacman-key --populate archlinux
    pacman -Sy --noconfirm archlinux-keyring
fi

log "Running pacstrap..."
pacstrap -K /mnt \
    base base-devel linux-firmware intel-ucode btrfs-progs \
    git vim nano networkmanager sudo zram-generator \
    mesa vulkan-intel intel-media-driver

log "Generating fstab (subvolume-aware, since /mnt is already mounted with the target's subvol options)..."
genfstab -U /mnt > /mnt/etc/fstab
grep -q "subvol=/@" /mnt/etc/fstab || log "WARNING: fstab does not show expected subvol entries — inspect /mnt/etc/fstab manually before rebooting."

log "Staging repository payload into the target..."
mkdir -p /mnt/usr/usr_src/icarus-archos
cp -a "${ICARUS_REPO_PATH}/." /mnt/usr/usr_src/icarus-archos/
# Drop VCS metadata and any prior build artifacts from the staged copy — no
# reason to carry a .git history or a previous kernel-build.log onto the
# fresh install.
rm -rf /mnt/usr/usr_src/icarus-archos/.git
find /mnt/usr/usr_src/icarus-archos -name "*.pkg.tar.zst" -delete 2>/dev/null || true

mkdir -p "$ICARUS_LOG_DIR"
touch "$SENTINEL"
log "Layer 2 complete. Sentinel written: ${SENTINEL}"

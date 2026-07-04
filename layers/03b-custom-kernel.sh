#!/usr/bin/env bash
#
# layers/03b-custom-kernel.sh
# Builds the custom linux-icarus kernel package.
#
# IMPORTANT DESIGN NOTE:
# On an 8GB machine, building a full kernel entirely inside tmpfs (as earlier
# drafts of this plan proposed) does not avoid the OOM killer — it feeds it
# directly, because tmpfs pages ARE RAM. A kernel build tree plus object
# files commonly runs into the multi-gigabyte range, and each parallel
# compiler job (cc1) can hold 1-2GB of its own. This script instead:
#   1. Sizes ZRAM and the parallel job count based on actual measured memory,
#      not a fixed assumption.
#   2. Only uses a tmpfs build scratch space, and only up to a capped size,
#      if there is verified headroom to do so safely.
#   3. Falls back to building on the Btrfs-compressed disk otherwise. A
#      single one-time kernel build is not the kind of sustained write
#      pattern that causes meaningful flash wear — that concern applies to
#      continuous small writes, not one multi-gigabyte job.
#
# A failed build here must NEVER take down a working system: the stock
# kernel entry from Layer 3a is left untouched regardless of outcome.
#
set -uo pipefail  # deliberately not -e: build failure is handled explicitly

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/var/log/icarus}"
ICARUS_REPO_PATH="${ICARUS_REPO_PATH:-/usr/usr_src/icarus-archos}"
SENTINEL="${ICARUS_LOG_DIR}/layer-3b-kernel.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-3a-core.done"

TARGET=""

log() { echo "[layer-3b] $*"; }
warn_and_exit_gracefully() {
    echo "[layer-3b] $*" >&2
    echo "[layer-3b] The stock kernel from Layer 3a remains the boot default. Skipping custom kernel; this is not fatal to the overall install." >&2
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        *) echo "[layer-3b] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -f "$PREV_SENTINEL" ]] || warn_and_exit_gracefully "Layer 3a sentinel not found. Skipping custom kernel build."

if ! curl -s --max-time 5 -o /dev/null https://geo.mirror.pkgbuild.com; then
    warn_and_exit_gracefully "No internet access detected inside chroot. Skipping custom kernel build."
fi

FREE_ROOT_KB=$(df --output=avail / | tail -1 | tr -d ' ')
FREE_ROOT_GB=$(( FREE_ROOT_KB / 1024 / 1024 ))
if [[ $FREE_ROOT_GB -lt 8 ]]; then
    warn_and_exit_gracefully "Only ${FREE_ROOT_GB}GB free on /. At least 8GB is needed to safely attempt a kernel build. Skipping."
fi

PKGDIR="${ICARUS_REPO_PATH}/pkgs/linux-icarus"
if [[ ! -f "${PKGDIR}/PKGBUILD" ]]; then
    warn_and_exit_gracefully "No PKGBUILD found at ${PKGDIR}. Skipping custom kernel build."
fi

# ---------------------------------------------------------------------------
# Kernel build dependencies. base-devel alone is not enough for a modern
# kernel build: pahole is required for CONFIG_DEBUG_INFO_BTF (its absence
# doesn't always hard-fail the build, it can silently produce a kernel
# without BTF, which breaks BPF/CO-RE tooling later) — libelf and bc are
# needed by the kbuild scripts themselves (elfutils / kconfig).
# ---------------------------------------------------------------------------
log "Installing kernel build dependencies (bc, libelf, pahole)..."
pacman -S --noconfirm --needed bc libelf pahole || warn_and_exit_gracefully "Failed to install kernel build dependencies."

# ---------------------------------------------------------------------------
# Memory-aware sizing
# ---------------------------------------------------------------------------
MEM_TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_TOTAL_GB=$(( MEM_TOTAL_KB / 1024 / 1024 ))
NPROC=$(nproc)

# Rule of thumb: budget ~1.5-2GB of RAM per parallel kernel compile job.
# Never go below 1, never exceed nproc.
SAFE_JOBS=$(( MEM_TOTAL_GB * 2 / 3 ))
[[ $SAFE_JOBS -lt 1 ]] && SAFE_JOBS=1
[[ $SAFE_JOBS -gt $NPROC ]] && SAFE_JOBS=$NPROC

log "Detected ${MEM_TOTAL_GB}GB total RAM, ${NPROC} logical CPUs. Using MAKEFLAGS=-j${SAFE_JOBS}."

# ---------------------------------------------------------------------------
# ZRAM: sized to a fraction of total RAM, not "ram" at full 1:1, so the
# compressed swap device doesn't itself compound memory pressure during a
# build that is already using most of physical RAM.
# ---------------------------------------------------------------------------
log "Configuring ZRAM..."
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(4096, ram / 2)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service || log "WARNING: could not start zram0 immediately (will apply on next boot via the generator)."

# ---------------------------------------------------------------------------
# Decide build location: capped tmpfs scratch ONLY if there is verified
# headroom; otherwise build on the Btrfs-compressed disk.
# ---------------------------------------------------------------------------
MEM_AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
MEM_AVAIL_GB=$(( MEM_AVAIL_KB / 1024 / 1024 ))
TMPFS_CAP_GB=3
BUILD_ROOT="/var/tmp/icarus-build"

# Require: enough available memory to hold the tmpfs cap AND leave at least
# 3GB of headroom for the compiler jobs themselves and the rest of the
# system. If that's not comfortably true, use disk.
if [[ $MEM_AVAIL_GB -ge $(( TMPFS_CAP_GB + 3 )) ]]; then
    log "MemAvailable=${MEM_AVAIL_GB}GB — using a ${TMPFS_CAP_GB}GB capped tmpfs build scratch."
    mkdir -p "$BUILD_ROOT"
    if ! mountpoint -q "$BUILD_ROOT"; then
        mount -t tmpfs -o size="${TMPFS_CAP_GB}G",mode=0755 tmpfs "$BUILD_ROOT" || {
            log "WARNING: tmpfs mount failed, falling back to disk build directory."
        }
    fi
else
    log "MemAvailable=${MEM_AVAIL_GB}GB is not enough headroom for a capped tmpfs build — building on the Btrfs disk instead (compressed, one-time job)."
    mkdir -p "$BUILD_ROOT"
fi

# ---------------------------------------------------------------------------
# makepkg.conf
# ---------------------------------------------------------------------------
log "Configuring /etc/makepkg.conf..."
cp /etc/makepkg.conf /etc/makepkg.conf.icarus-orig 2>/dev/null || true
sed -i "s|^#\?BUILDDIR=.*|BUILDDIR=${BUILD_ROOT}|" /etc/makepkg.conf
grep -q '^BUILDDIR=' /etc/makepkg.conf || echo "BUILDDIR=${BUILD_ROOT}" >> /etc/makepkg.conf
sed -i "s|^#\?MAKEFLAGS=.*|MAKEFLAGS=\"-j${SAFE_JOBS}\"|" /etc/makepkg.conf
grep -q '^MAKEFLAGS=' /etc/makepkg.conf || echo "MAKEFLAGS=\"-j${SAFE_JOBS}\"" >> /etc/makepkg.conf
sed -i 's|^#\?CFLAGS=.*|CFLAGS="-march=native -O3 -pipe"|' /etc/makepkg.conf
sed -i 's|^#\?CXXFLAGS=.*|CXXFLAGS="${CFLAGS}"|' /etc/makepkg.conf
sed -i 's|^#\?BUILDENV=.*|BUILDENV=(!distcc !color !ccache check !sign)|' /etc/makepkg.conf

chown -R icarus:icarus "$BUILD_ROOT"
chown -R icarus:icarus "$ICARUS_REPO_PATH"

# ---------------------------------------------------------------------------
# Build as the unprivileged user — makepkg refuses to run as root.
# ---------------------------------------------------------------------------
log "Building linux-icarus as user 'icarus'. This will take a while..."
BUILD_LOG="${ICARUS_LOG_DIR}/kernel-build.log"
mkdir -p "$ICARUS_LOG_DIR"

sudo -u icarus bash -c "
    set -e
    cd '${PKGDIR}'
    makepkg -sf --noconfirm
" 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS=${PIPESTATUS[0]}

if [[ $BUILD_STATUS -ne 0 ]]; then
    warn_and_exit_gracefully "Kernel build failed (see ${BUILD_LOG}). "
fi

PKG_FILE=$(find "$PKGDIR" -maxdepth 1 -name '*.pkg.tar.zst' | head -1)
[[ -n "$PKG_FILE" ]] || warn_and_exit_gracefully "Build reported success but no package file was found."

log "Installing built package: ${PKG_FILE}"
pacman -U --noconfirm "$PKG_FILE" || warn_and_exit_gracefully "Failed to install the built kernel package."

KERNEL_NAME=$(basename "$PKG_FILE" | sed -E 's/-[0-9].*//')
mkinitcpio -p "$KERNEL_NAME" || mkinitcpio -P || warn_and_exit_gracefully "initramfs regeneration failed for the custom kernel."

source "${ICARUS_LOG_DIR}/layer-3a-core.env" 2>/dev/null || true
ROOT_UUID="${ROOT_UUID:-$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /)")}"

cat > /boot/loader/entries/icarus-custom.conf <<EOF
title Icarus-ArchOS (Custom kernel: ${KERNEL_NAME})
linux /vmlinuz-${KERNEL_NAME}
initrd /intel-ucode.img
initrd /initramfs-${KERNEL_NAME}.img
options root=UUID=${ROOT_UUID} rootflags=subvol=@ rw quiet
EOF

log "Custom kernel entry written. Fallback entry left untouched — switch the default manually in /boot/loader/loader.conf once you've confirmed it boots cleanly."

touch "$SENTINEL"
log "Layer 3b complete. Sentinel written: ${SENTINEL}"

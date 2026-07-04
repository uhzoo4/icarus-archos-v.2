#!/usr/bin/env bash
#
# layers/03a-chroot-core.sh
# Guaranteed-bootable core: locale, user, stock kernel, Early KMS, systemd-boot.
# Runs inside `arch-chroot /mnt`, invoked by icarus-assemble.sh.
#
set -euo pipefail

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/var/log/icarus}"
SENTINEL="${ICARUS_LOG_DIR}/layer-3a-core.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-2-base.done"

TARGET=""
FORCE_XE=0
DISABLE_MITIGATIONS=0

log() { echo "[layer-3a] $*"; }
fatal() { echo "[layer-3a] FATAL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --force-xe) FORCE_XE=1; shift ;;
        --disable-mitigations) DISABLE_MITIGATIONS=1; shift ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

[[ -f "$PREV_SENTINEL" ]] || fatal "Layer 2 sentinel not found (${PREV_SENTINEL})."
[[ -f /etc/arch-release ]] || fatal "This does not look like an Arch chroot. Refusing to run."

# ---------------------------------------------------------------------------
# Localization & identity
# ---------------------------------------------------------------------------
log "Setting locale, timezone, hostname..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "icarus-archos" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1	localhost
::1		localhost
127.0.1.1	icarus-archos.localdomain	icarus-archos
EOF

# ---------------------------------------------------------------------------
# OS branding — Icarus-ArchOS identifies itself distinctly from upstream Arch
# in every place that reads /etc/os-release (neofetch, systemd, GUI "About"
# panels) without breaking anything that relies on ID_LIKE=arch for package
# compatibility checks.
# ---------------------------------------------------------------------------
log "Applying OS branding..."
cat > /etc/os-release <<'EOF'
NAME="Icarus-ArchOS"
PRETTY_NAME="Icarus-ArchOS"
ID=icarus-archos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;160;160;160"
HOME_URL="https://github.com/"
DOCUMENTATION_URL="https://wiki.archlinux.org/"
SUPPORT_URL="https://bbs.archlinux.org/"
BUG_REPORT_URL="https://bugs.archlinux.org/"
LOGO=icarus-archos-logo
EOF

cat > /etc/issue <<'EOF'
Icarus-ArchOS \r (\l)

EOF

cat > /etc/lsb-release <<'EOF'
DISTRIB_ID=Icarus-ArchOS
DISTRIB_RELEASE=rolling
DISTRIB_DESCRIPTION="Icarus-ArchOS"
EOF

cat > /etc/motd <<'EOF'
Welcome to Icarus-ArchOS.
EOF

# ---------------------------------------------------------------------------
# Admin user
# ---------------------------------------------------------------------------
log "Creating user 'icarus'..."
if ! id icarus &>/dev/null; then
    useradd -m -G wheel,video,audio,input,storage -s /bin/bash icarus
fi
echo "icarus:icarus" | chpasswd
# Force a password change on first login rather than leaving a known
# default password live indefinitely.
chage -d 0 icarus

mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel
visudo -c -f /etc/sudoers.d/wheel || fatal "Generated sudoers file failed validation."

# ---------------------------------------------------------------------------
# Stock kernel (the guaranteed-boot fallback)
# ---------------------------------------------------------------------------
log "Installing stock kernel..."
pacman -S --noconfirm --needed linux linux-headers

# ---------------------------------------------------------------------------
# GPU generation detection for Early KMS module ordering.
#
# The 'xe' driver is only the DEFAULT kernel driver on Lunar Lake and
# Battlemage-class Intel graphics. Most Iris Xe laptops (Tiger Lake, Alder
# Lake, Raptor Lake) still default to i915, and xe remains optional /
# experimental on that older silicon. Forcing xe first on hardware that
# isn't confirmed xe-default risks the exact dual-driver binding / stalled
# frame allocation problem this layer exists to avoid. So: detect first,
# and only prioritize xe if the hardware is a confirmed match or the user
# explicitly passed --force-xe.
# ---------------------------------------------------------------------------
GPU_LINE="$(lspci -nn | grep -Ei 'vga|display|3d' | grep -i intel || true)"
log "Detected GPU: ${GPU_LINE:-none found}"

XE_DEFAULT_GEN=0
if echo "$GPU_LINE" | grep -qiE 'lunar lake|battlemage|panther lake|arrow lake'; then
    XE_DEFAULT_GEN=1
fi

if [[ $XE_DEFAULT_GEN -eq 1 || $FORCE_XE -eq 1 ]]; then
    log "Using 'xe' as the primary graphics module (confirmed xe-default generation: ${XE_DEFAULT_GEN}, --force-xe: ${FORCE_XE})."
    MODULES_LINE='MODULES=(xe i915 btrfs)'
    XE_PCI_ID="$(echo "$GPU_LINE" | grep -oP '(?<=\[8086:)[0-9a-fA-F]{4}(?=\])' | head -1 || true)"
    if [[ -n "$XE_PCI_ID" ]]; then
        KMS_CMDLINE_EXTRA="xe.force_probe=${XE_PCI_ID} i915.force_probe=!${XE_PCI_ID}"
    else
        KMS_CMDLINE_EXTRA="xe.force_probe=*"
        log "WARNING: could not parse a specific PCI ID; using xe.force_probe=* (broad override)."
    fi
else
    log "Defaulting to 'i915' as the primary graphics module (this generation is not confirmed xe-default). Pass --force-xe to override."
    MODULES_LINE='MODULES=(i915 btrfs)'
    KMS_CMDLINE_EXTRA=""
fi

log "Configuring mkinitcpio for Early KMS..."
if grep -q '^MODULES=' /etc/mkinitcpio.conf; then
    sed -i "s|^MODULES=.*|${MODULES_LINE}|" /etc/mkinitcpio.conf
else
    echo "$MODULES_LINE" >> /etc/mkinitcpio.conf
fi
mkinitcpio -P

# ---------------------------------------------------------------------------
# systemd-boot
# ---------------------------------------------------------------------------
log "Installing systemd-boot..."
bootctl install

cat > /boot/loader/loader.conf <<'EOF'
default icarus-fallback
timeout 3
console-mode max
EOF

ROOT_UUID="$(blkid -s UUID -o value "${TARGET}2" 2>/dev/null || true)"
if [[ -z "$ROOT_UUID" ]]; then
    # Fall back to discovering the root device from the current mount if the
    # partition-numbering guess above didn't resolve (e.g. NVMe naming).
    ROOT_SRC="$(findmnt -n -o SOURCE /)"
    ROOT_UUID="$(blkid -s UUID -o value "$ROOT_SRC")"
fi
[[ -n "$ROOT_UUID" ]] || fatal "Could not determine root partition UUID."

KERNEL_OPTS="root=UUID=${ROOT_UUID} rootflags=subvol=@ rw quiet ${KMS_CMDLINE_EXTRA}"
if [[ $DISABLE_MITIGATIONS -eq 1 ]]; then
    KERNEL_OPTS="${KERNEL_OPTS} mitigations=off"
    log "WARNING: CPU speculative-execution mitigations disabled per --disable-mitigations. This is a deliberate security tradeoff."
fi

mkdir -p /boot/loader/entries
cat > /boot/loader/entries/icarus-fallback.conf <<EOF
title Icarus-ArchOS (Fallback, stock kernel)
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options ${KERNEL_OPTS}
EOF

log "Wrote boot entry with root UUID ${ROOT_UUID}."

mkdir -p "$ICARUS_LOG_DIR"
{
    echo "ROOT_UUID=${ROOT_UUID}"
    echo "GPU_PRIMARY_DRIVER=$([[ $XE_DEFAULT_GEN -eq 1 || $FORCE_XE -eq 1 ]] && echo xe || echo i915)"
    echo "TIMESTAMP=$(date -Iseconds)"
} > "${ICARUS_LOG_DIR}/layer-3a-core.env"

touch "$SENTINEL"
log "Layer 3a complete. The system is now bootable via the stock kernel. Sentinel written: ${SENTINEL}"

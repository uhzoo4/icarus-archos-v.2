#!/usr/bin/env bash
#
# layers/01-live-partition.sh
# Wipes the target device and lays down a flash-wear-conscious Btrfs layout.
# Runs on the live ISO host, invoked by icarus-assemble.sh.
#
set -euo pipefail

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/mnt/var/log/icarus}"
SENTINEL="${ICARUS_LOG_DIR}/layer-1-partition.done"

TARGET=""
ALLOW_INTERNAL=0
REDUNDANT_METADATA=0

log() { echo "[layer-1] $*"; }
fatal() { echo "[layer-1] FATAL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --allow-internal) ALLOW_INTERNAL=1; shift ;;
        --redundant-metadata) REDUNDANT_METADATA=1; shift ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

[[ -n "$TARGET" ]] || fatal "No --target device given."
[[ -b "$TARGET" ]] || fatal "Target '${TARGET}' is not a block device."

DEVNAME="$(basename "$TARGET")"

# --- Guard 1: minimum size ---
SIZE_BYTES=$(blockdev --getsize64 "$TARGET")
SIZE_GB=$(( SIZE_BYTES / 1024 / 1024 / 1024 ))
[[ $SIZE_GB -ge 20 ]] || fatal "Target device is ${SIZE_GB}GB. Minimum is 20GB."
if [[ $SIZE_GB -lt 29 ]]; then
    log "WARNING: device is ${SIZE_GB}GB. 29GB+ is recommended for kernel sources, build artifacts, and Wine prefixes."
fi

# --- Guard 2: refuse the live boot media itself ---
if [[ -e /run/archiso/bootmnt ]]; then
    BOOT_SRC="$(findmnt -n -o SOURCE /run/archiso/bootmnt || true)"
    if [[ -n "$BOOT_SRC" ]]; then
        BOOT_BASE="/dev/$(lsblk -no PKNAME "$BOOT_SRC" 2>/dev/null || basename "$BOOT_SRC")"
        if [[ "$BOOT_BASE" == "$TARGET" ]]; then
            fatal "Target '${TARGET}' is the live boot media. Refusing to wipe it."
        fi
    fi
fi

# --- Guard 3: refuse internal/non-removable disks unless overridden ---
REMOVABLE_FLAG="/sys/block/${DEVNAME}/removable"
IS_REMOVABLE=0
[[ -f "$REMOVABLE_FLAG" ]] && [[ "$(cat "$REMOVABLE_FLAG")" == "1" ]] && IS_REMOVABLE=1

if [[ $IS_REMOVABLE -eq 0 && $ALLOW_INTERNAL -eq 0 ]]; then
    fatal "Target '${TARGET}' does not report as removable. Pass --allow-internal if this is intentional (e.g. NVMe target). Refusing by default to avoid wiping the wrong disk."
fi

# --- Interactive confirmation ---
MODEL="$(lsblk -no MODEL "$TARGET" 2>/dev/null | xargs || echo unknown)"
log "Target device: ${TARGET}"
log "Model: ${MODEL}"
log "Size: ${SIZE_GB}GB"
log "Current partition table:"
lsblk "$TARGET"
echo
echo "This will DESTROY ALL DATA on ${TARGET}. Type 'yes' to continue:"
read -r CONFIRM
[[ "$CONFIRM" == "yes" ]] || fatal "Confirmation not given. Aborting."

# --- Determine partition naming (nvme0n1p1 vs sdb1) ---
if [[ "$DEVNAME" =~ [0-9]$ ]]; then
    PART_SUFFIX="p"
else
    PART_SUFFIX=""
fi
EFI_PART="${TARGET}${PART_SUFFIX}1"
ROOT_PART="${TARGET}${PART_SUFFIX}2"

# --- Safety: recursively unmount any existing mounts on target device partitions ---
log "Unmounting any existing filesystems on target device..."
umount -R "${TARGET}"* 2>/dev/null || true

log "Wiping partition table..."
wipefs -af "$TARGET"
sgdisk --zap-all "$TARGET"

log "Creating GPT partitions..."
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"ICARUS_ESP" "$TARGET"
sgdisk -n 2:0:0     -t 2:8300 -c 2:"ICARUS_ROOT" "$TARGET"
partprobe "$TARGET"
udevadm settle
sleep 1

[[ -b "$EFI_PART" ]] || fatal "Expected EFI partition ${EFI_PART} did not appear."
[[ -b "$ROOT_PART" ]] || fatal "Expected root partition ${ROOT_PART} did not appear."

log "Formatting EFI System Partition (${EFI_PART}) as FAT32..."
mkfs.vfat -F 32 -n ICARUS_ESP "$EFI_PART"

# Metadata profile: default to 'single' on removable flash to avoid doubling
# metadata writes via Btrfs's normal 'dup' profile. This trades a small amount
# of self-healing capability for materially fewer writes to the flash cells.
# Pass --redundant-metadata to keep Btrfs's default 'dup' behavior instead.
if [[ $REDUNDANT_METADATA -eq 1 ]]; then
    log "Formatting root partition (${ROOT_PART}) as Btrfs with default (dup) metadata profile..."
    mkfs.btrfs -f -L "ICARUS_SYSTEM" "$ROOT_PART"
else
    log "Formatting root partition (${ROOT_PART}) as Btrfs with -m single -d single (flash-wear optimized)..."
    mkfs.btrfs -f -m single -d single -L "ICARUS_SYSTEM" "$ROOT_PART"
fi

log "Creating subvolumes..."
mount "$ROOT_PART" /mnt

# Explicit guard: remove any pre-existing subvolumes (should not exist on fresh fs, but safe for idempotency)
for sv in @ @home @cache @log; do
    if btrfs subvolume list /mnt | grep -q " path ${sv}$"; then
        log "Removing pre-existing subvolume: ${sv}"
        btrfs subvolume delete "/mnt/${sv}"
    fi
done

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
umount /mnt

BTRFS_OPTS="noatime,ssd,compress=zstd:3,space_cache=v2,discard=async,commit=60"

log "Mounting subvolumes with: ${BTRFS_OPTS}"
mount -o "subvol=@,${BTRFS_OPTS}" "$ROOT_PART" /mnt
mkdir -p /mnt/{boot,home,var/cache,var/log}
mount -o "subvol=@home,${BTRFS_OPTS}" "$ROOT_PART" /mnt/home
mount -o "subvol=@cache,${BTRFS_OPTS}" "$ROOT_PART" /mnt/var/cache
mount -o "subvol=@log,${BTRFS_OPTS}" "$ROOT_PART" /mnt/var/log
mount "$EFI_PART" /mnt/boot

log "Verifying mount layout..."
findmnt /mnt >/dev/null || fatal "Root mount verification failed."
findmnt /mnt/boot >/dev/null || fatal "Boot mount verification failed."
findmnt /mnt/home >/dev/null || fatal "Home mount verification failed."

mkdir -p "$ICARUS_LOG_DIR"
{
    echo "TARGET_DEVICE=${TARGET}"
    echo "EFI_PART=${EFI_PART}"
    echo "ROOT_PART=${ROOT_PART}"
    echo "TIMESTAMP=$(date -Iseconds)"
} > "${ICARUS_LOG_DIR}/layer-1-partition.env"

touch "$SENTINEL"
log "Layer 1 complete. Sentinel written: ${SENTINEL}"

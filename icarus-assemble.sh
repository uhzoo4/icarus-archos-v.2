#!/usr/bin/env bash
#
# icarus-assemble.sh
# Master conductor for Icarus-ArchOS layered assembly.
# Run this from the Arch Linux live ISO environment as root.
#
# Usage:
#   ./icarus-assemble.sh --target /dev/sdX [options]
#
# Options:
#   --target DEVICE         Required. Block device to install onto (e.g. /dev/sdb).
#   --allow-internal        Permit installing onto a non-removable / internal disk.
#   --force-xe              Force the 'xe' kernel driver even if this hardware is
#                            not a confirmed xe-default generation. Off by default.
#   --disable-mitigations   Add mitigations=off to the kernel command line.
#                            OFF by default — this is a conscious security tradeoff,
#                            not a silent default.
#   --redundant-metadata    Keep Btrfs's default 'dup' metadata profile (safer,
#                            more writes). Default is '-m single' to minimize
#                            flash wear on a single removable device.
#   --repo-path PATH        Path to this repository. Defaults to the directory
#                            containing this script.
#   --resume                Skip layers whose sentinel files already exist.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_PATH="${SCRIPT_DIR}"
TARGET_DEVICE=""
ALLOW_INTERNAL=0
FORCE_XE=0
DISABLE_MITIGATIONS=0
REDUNDANT_METADATA=0
RESUME=0

HOST_LOG_DIR="/mnt/var/log/icarus"
CHROOT_LOG_DIR="/var/log/icarus"
CHROOT_REPO_PATH="/usr/usr_src/icarus-archos"

log() {
    echo "[icarus-assemble] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

fatal() {
    echo "[icarus-assemble] FATAL: $*" >&2
    exit 1
}

exit_handler() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo "[icarus-assemble] Aborted with exit code ${code} at line ${BASH_LINENO[0]}." >&2
        echo "[icarus-assemble] Nothing further will run. Fix the reported error and re-run with --resume." >&2
    fi
}
trap exit_handler EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DEVICE="$2"; shift 2 ;;
        --target=*)
            TARGET_DEVICE="${1#*=}"; shift ;;
        --allow-internal)
            ALLOW_INTERNAL=1; shift ;;
        --force-xe)
            FORCE_XE=1; shift ;;
        --disable-mitigations)
            DISABLE_MITIGATIONS=1; shift ;;
        --redundant-metadata)
            REDUNDANT_METADATA=1; shift ;;
        --repo-path)
            REPO_PATH="$2"; shift 2 ;;
        --repo-path=*)
            REPO_PATH="${1#*=}"; shift ;;
        --resume)
            RESUME=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
        *)
            fatal "Unknown argument: $1" ;;
    esac
done

[[ -n "$TARGET_DEVICE" ]] || fatal "You must pass --target /dev/sdX. There is no default device; this is intentional so a wrong disk can't be wiped by omission."
[[ "$(id -u)" -eq 0 ]] || fatal "This script must run as root."
[[ -f "${REPO_PATH}/icarus-assemble.sh" ]] || fatal "Repo path '${REPO_PATH}' does not look like the icarus-archos repository root."

sentinel_exists() {
    local host_path="$1"
    [[ -f "$host_path" ]]
}

run_host_layer() {
    local name="$1"
    local script="$2"
    shift 2
    local sentinel="${HOST_LOG_DIR}/${name}.done"

    if [[ $RESUME -eq 1 ]] && sentinel_exists "$sentinel"; then
        log "Skipping ${name} (sentinel present, --resume given)."
        return 0
    fi

    log "Running host layer: ${name}"
    mkdir -p "$HOST_LOG_DIR"
    ICARUS_LOG_DIR="$HOST_LOG_DIR" \
    ICARUS_REPO_PATH="$REPO_PATH" \
        bash "${REPO_PATH}/layers/${script}" "$@" 2>&1 | tee -a "${HOST_LOG_DIR}/assemble.log"

    sentinel_exists "$sentinel" || fatal "${name} did not write its sentinel file (${sentinel}). Treating as failed."
    log "Completed host layer: ${name}"
}

run_chroot_layer() {
    local name="$1"
    local script="$2"
    shift 2
    local sentinel="${HOST_LOG_DIR}/${name}.done"

    if [[ $RESUME -eq 1 ]] && sentinel_exists "$sentinel"; then
        log "Skipping ${name} (sentinel present, --resume given)."
        return 0
    fi

    [[ -d /mnt/usr ]] || fatal "/mnt does not look like a mounted target root. Did Layer 1/2 run?"

    log "Running chroot layer: ${name}"
    mkdir -p "$HOST_LOG_DIR"
    arch-chroot /mnt env \
        ICARUS_LOG_DIR="$CHROOT_LOG_DIR" \
        ICARUS_REPO_PATH="$CHROOT_REPO_PATH" \
        bash "${CHROOT_REPO_PATH}/layers/${script}" "$@" 2>&1 | tee -a "${HOST_LOG_DIR}/assemble.log"

    sentinel_exists "$sentinel" || fatal "${name} did not write its sentinel file (${sentinel}). Treating as failed."
    log "Completed chroot layer: ${name}"
}

log "Icarus-ArchOS assembly starting. Target device: ${TARGET_DEVICE}"
log "Flags: allow_internal=${ALLOW_INTERNAL} force_xe=${FORCE_XE} disable_mitigations=${DISABLE_MITIGATIONS} redundant_metadata=${REDUNDANT_METADATA}"

LAYER1_ARGS=(--target "$TARGET_DEVICE")
[[ $ALLOW_INTERNAL -eq 1 ]] && LAYER1_ARGS+=(--allow-internal)
[[ $REDUNDANT_METADATA -eq 1 ]] && LAYER1_ARGS+=(--redundant-metadata)
run_host_layer "layer-1-partition" "01-live-partition.sh" "${LAYER1_ARGS[@]}"

run_host_layer "layer-2-base" "02-base-install.sh" --target "$TARGET_DEVICE"

LAYER3A_ARGS=(--target "$TARGET_DEVICE")
[[ $FORCE_XE -eq 1 ]] && LAYER3A_ARGS+=(--force-xe)
[[ $DISABLE_MITIGATIONS -eq 1 ]] && LAYER3A_ARGS+=(--disable-mitigations)
run_chroot_layer "layer-3a-core" "03a-chroot-core.sh" "${LAYER3A_ARGS[@]}"

# Layer 3b (custom kernel) is allowed to fail without aborting the assembly:
# the whole point of the fallback/custom split is that a bad kernel build
# must never leave the machine unbootable. We call it directly rather than
# through run_chroot_layer's strict sentinel check.
log "Running chroot layer: layer-3b-kernel (non-fatal on failure)"
mkdir -p "$HOST_LOG_DIR"
set +e
arch-chroot /mnt env \
    ICARUS_LOG_DIR="$CHROOT_LOG_DIR" \
    ICARUS_REPO_PATH="$CHROOT_REPO_PATH" \
    bash "${CHROOT_REPO_PATH}/layers/03b-custom-kernel.sh" --target "$TARGET_DEVICE" \
    2>&1 | tee -a "${HOST_LOG_DIR}/assemble.log"
LAYER3B_STATUS=${PIPESTATUS[0]}
set -e
if [[ $LAYER3B_STATUS -ne 0 ]] || ! sentinel_exists "${HOST_LOG_DIR}/layer-3b-kernel.done"; then
    log "WARNING: custom kernel build did not complete. The stock kernel entry from Layer 3a remains the boot default. Continuing."
fi

run_chroot_layer "layer-3c-daemons" "03c-daemons.sh"
run_chroot_layer "layer-4-graphics" "04-graphics.sh"
run_chroot_layer "layer-5-ui-winhybrid" "05-ui-winhybrid.sh"

log "All layers processed. Review ${HOST_LOG_DIR}/assemble.log for details."
log "Unmount and reboot when ready:  umount -R /mnt && udevadm settle"

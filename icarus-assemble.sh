#!/usr/bin/env bash
#
# icarus-assemble.sh
# Master conductor for Icarus-ArchOS layered assembly.
# Run this from the Arch Linux live ISO environment as root.
#
# Layers are read from layers/MANIFEST, in order. To add a new layer,
# write layers/NN-your-layer.sh (see layers/TEMPLATE.sh for the
# conventions) and add one line to layers/MANIFEST — this script does not
# need to change.
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
#                            OFF by default — a conscious security tradeoff.
#   --redundant-metadata    Keep Btrfs's default 'dup' metadata profile (safer,
#                            more writes) instead of '-m single'.
#   --app-profiles LIST     Space-separated Layer 9 application profiles to
#                            install before first boot. Overrides profiles.conf.
#   --repo-path PATH        Path to this repository. Defaults to the directory
#                            containing this script.
#   --resume                Skip layers whose sentinel files already exist.
#
# All of the above (except --repo-path and --resume, which are
# conductor-only concerns) are exported as ICARUS_* environment variables
# for every layer to read. This is what lets layers/MANIFEST stay a flat
# list instead of needing a per-layer argument mapping here.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_PATH="${SCRIPT_DIR}"
RESUME=0

export ICARUS_TARGET_DEVICE=""
export ICARUS_ALLOW_INTERNAL=0
export ICARUS_FORCE_XE=0
export ICARUS_DISABLE_MITIGATIONS=0
export ICARUS_REDUNDANT_METADATA=0
export ICARUS_APP_PROFILES=""

HOST_LOG_DIR="/mnt/var/log/icarus"
CHROOT_LOG_DIR="/var/log/icarus"
CHROOT_REPO_PATH="/usr/usr_src/icarus-archos"
MANIFEST="layers/MANIFEST"

log() { echo "[icarus-assemble] $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
fatal() { echo "[icarus-assemble] FATAL: $*" >&2; exit 1; }

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
        --target) ICARUS_TARGET_DEVICE="$2"; shift 2 ;;
        --target=*) ICARUS_TARGET_DEVICE="${1#*=}"; shift ;;
        --allow-internal) ICARUS_ALLOW_INTERNAL=1; shift ;;
        --force-xe) ICARUS_FORCE_XE=1; shift ;;
        --disable-mitigations) ICARUS_DISABLE_MITIGATIONS=1; shift ;;
        --redundant-metadata) ICARUS_REDUNDANT_METADATA=1; shift ;;
        --app-profiles) ICARUS_APP_PROFILES="$2"; shift 2 ;;
        --app-profiles=*) ICARUS_APP_PROFILES="${1#*=}"; shift ;;
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        --repo-path=*) REPO_PATH="${1#*=}"; shift ;;
        --resume) RESUME=1; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done
export ICARUS_TARGET_DEVICE ICARUS_ALLOW_INTERNAL ICARUS_FORCE_XE ICARUS_DISABLE_MITIGATIONS ICARUS_REDUNDANT_METADATA ICARUS_APP_PROFILES

[[ -n "$ICARUS_TARGET_DEVICE" ]] || fatal "You must pass --target /dev/sdX. There is no default device; this is intentional so a wrong disk can't be wiped by omission."
[[ "$(id -u)" -eq 0 ]] || fatal "This script must run as root."
[[ -f "${REPO_PATH}/icarus-assemble.sh" ]] || fatal "Repo path '${REPO_PATH}' does not look like the icarus-archos repository root."
[[ -f "${REPO_PATH}/${MANIFEST}" ]] || fatal "Manifest not found at ${REPO_PATH}/${MANIFEST}."

sentinel_exists() { [[ -f "$1" ]]; }

run_layer() {
    local name="$1" context="$2" fail_mode="$3" script="$4"
    local sentinel="${HOST_LOG_DIR}/${name}.done"

    if [[ $RESUME -eq 1 ]] && sentinel_exists "$sentinel"; then
        log "Skipping ${name} (sentinel present, --resume given)."
        return 0
    fi

    [[ -f "${REPO_PATH}/layers/${script}" ]] || fatal "Layer script not found: layers/${script} (declared in ${MANIFEST} as ${name})."

    log "Running ${context} layer: ${name}"
    mkdir -p "$HOST_LOG_DIR"

    local status=0
    if [[ "$context" == "host" ]]; then
        ICARUS_LOG_DIR="$HOST_LOG_DIR" ICARUS_REPO_PATH="$REPO_PATH" \
            bash "${REPO_PATH}/layers/${script}" 2>&1 | tee -a "${HOST_LOG_DIR}/assemble.log"
        status=${PIPESTATUS[0]}
    elif [[ "$context" == "chroot" ]]; then
        [[ -d /mnt/usr ]] || fatal "/mnt does not look like a mounted target root. Did earlier layers run?"
        arch-chroot /mnt env \
            ICARUS_LOG_DIR="$CHROOT_LOG_DIR" \
            ICARUS_REPO_PATH="$CHROOT_REPO_PATH" \
            ICARUS_TARGET_DEVICE="$ICARUS_TARGET_DEVICE" \
            ICARUS_ALLOW_INTERNAL="$ICARUS_ALLOW_INTERNAL" \
            ICARUS_FORCE_XE="$ICARUS_FORCE_XE" \
            ICARUS_DISABLE_MITIGATIONS="$ICARUS_DISABLE_MITIGATIONS" \
            ICARUS_REDUNDANT_METADATA="$ICARUS_REDUNDANT_METADATA" \
            ICARUS_APP_PROFILES="$ICARUS_APP_PROFILES" \
            bash "${CHROOT_REPO_PATH}/layers/${script}" 2>&1 | tee -a "${HOST_LOG_DIR}/assemble.log"
        status=${PIPESTATUS[0]}
    else
        fatal "Unknown context '${context}' for layer ${name} in ${MANIFEST} (expected 'host' or 'chroot')."
    fi

    if [[ $status -ne 0 ]] || ! sentinel_exists "$sentinel"; then
        if [[ "$fail_mode" == "soft" ]]; then
            log "WARNING: ${name} did not complete successfully (exit ${status}). Marked 'soft' in ${MANIFEST} — continuing."
            return 0
        fi
        fatal "${name} did not complete successfully (exit ${status}, sentinel ${sentinel} present: $(sentinel_exists "$sentinel" && echo yes || echo no))."
    fi

    log "Completed ${context} layer: ${name}"
}

log "Icarus-ArchOS assembly starting. Target device: ${ICARUS_TARGET_DEVICE}"
log "Flags: allow_internal=${ICARUS_ALLOW_INTERNAL} force_xe=${ICARUS_FORCE_XE} disable_mitigations=${ICARUS_DISABLE_MITIGATIONS} redundant_metadata=${ICARUS_REDUNDANT_METADATA} app_profiles=${ICARUS_APP_PROFILES:-config-default}"

while IFS=':' read -r name context fail_mode script; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    run_layer "$name" "$context" "$fail_mode" "$script"
done < "${REPO_PATH}/${MANIFEST}"

log "All layers processed. Review ${HOST_LOG_DIR}/assemble.log for details."
log "Unmount and reboot when ready:  umount -R /mnt && udevadm settle"

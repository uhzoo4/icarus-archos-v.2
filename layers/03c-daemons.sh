#!/usr/bin/env bash
#
# layers/03c-daemons.sh
# Enables core services. Works regardless of which kernel ends up default.
#
set -euo pipefail

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/var/log/icarus}"
SENTINEL="${ICARUS_LOG_DIR}/layer-3c-daemons.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-3a-core.done"

log() { echo "[layer-3c] $*"; }
fatal() { echo "[layer-3c] FATAL: $*" >&2; exit 1; }

[[ -f "$PREV_SENTINEL" ]] || fatal "Layer 3a sentinel not found (${PREV_SENTINEL})."

log "Enabling network services..."
systemctl enable NetworkManager
systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

log "Enabling flash trim timer..."
systemctl enable fstrim.timer

log "Enabling monthly Btrfs scrub timer..."
systemctl enable btrfs-scrub@-.timer

mkdir -p "$ICARUS_LOG_DIR"
touch "$SENTINEL"
log "Layer 3c complete. Sentinel written: ${SENTINEL}"

#!/usr/bin/env bash
#
# layers/04-graphics.sh
# Intel Iris Xe acceleration stack: Mesa, VA-API, VDPAU bridge, multilib.
#
set -euo pipefail

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/var/log/icarus}"
SENTINEL="${ICARUS_LOG_DIR}/layer-4-graphics.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-3c-daemons.done"

log() { echo "[layer-4] $*"; }
fatal() { echo "[layer-4] FATAL: $*" >&2; exit 1; }

[[ -f "$PREV_SENTINEL" ]] || fatal "Layer 3c sentinel not found (${PREV_SENTINEL})."

log "Enabling multilib repository (needed for lib32-mesa / lib32-vulkan-intel / Wine)..."
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
fi
pacman -Sy

log "Installing graphics acceleration packages..."
pacman -S --noconfirm --needed \
    mesa vulkan-intel intel-media-driver libva-intel-driver libva-utils \
    libvdpau-va-gl \
    lib32-mesa lib32-vulkan-intel

log "Installing hardware monitoring / burn-in test tools..."
pacman -S --noconfirm --needed \
    stress-ng lm_sensors power-profiles-daemon upower
systemctl enable power-profiles-daemon.service

# ---------------------------------------------------------------------------
# /etc/environment
#
# LIBVA_DRIVER_NAME=iHD  -> real, selects the modern VA-API driver for
#                           Iris Xe / Arc-generation hardware.
# VDPAU_DRIVER=va_gl     -> real, requires libvdpau-va-gl (installed above)
#                           to bridge VDPAU calls onto the VA-API backend.
#
# A variable called ANV_QUEUE_THREAD_DISABLE was in an earlier draft of this
# plan. It does not appear in Mesa's documented environment variable list
# for the ANV Vulkan driver and could not be verified — it's dropped here
# rather than shipped as an unverified system-wide setting.
# ---------------------------------------------------------------------------
log "Writing /etc/environment..."
touch /etc/environment
for VAR in LIBVA_DRIVER_NAME VDPAU_DRIVER; do
    sed -i "/^${VAR}=/d" /etc/environment
done
cat >> /etc/environment <<'EOF'
LIBVA_DRIVER_NAME=iHD
VDPAU_DRIVER=va_gl
EOF

mkdir -p "$ICARUS_LOG_DIR"
touch "$SENTINEL"
log "Layer 4 complete. Sentinel written: ${SENTINEL}"

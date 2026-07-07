#!/usr/bin/env bash
#
# layers/08-silent-boot.sh
# Plymouth splash + quiet kernel boot — for systemd-boot, which is what
# this entire system actually uses (Layer 3a: `bootctl install`).
#
# An earlier draft of this layer assumed GRUB: it ran `grub-install
# --efi-directory=/boot` against the same ESP systemd-boot already
# manages, edited a /etc/default/grub that doesn't exist anywhere in this
# build, and wrote kernel parameters to a grub.cfg systemd-boot never
# reads. Installing a second bootloader onto an ESP an existing one
# already manages risks a broken or competing UEFI boot entry — that
# version is not used here. This one only ever touches:
#   - /etc/mkinitcpio.conf (inserting the plymouth hook, not replacing
#     the array)
#   - the actual systemd-boot entries Layer 3a/3b already wrote
#
set -uo pipefail  # deliberately not -e: cosmetic layer, must not risk boot

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/var/log/icarus}"
SENTINEL="${ICARUS_LOG_DIR}/layer-8-silent-boot.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-7-native-apps.done"

log() { echo "[layer-8] $*"; }
warn() { echo "[layer-8] WARNING: $*" >&2; }
fatal_soft() {
    echo "[layer-8] $*" >&2
    echo "[layer-8] Not fatal to the overall install — continuing without silent boot." >&2
    exit 0
}

[[ -f "$PREV_SENTINEL" ]] || fatal_soft "Layer 7 sentinel not found (${PREV_SENTINEL}). Skipping."
[[ -f /boot/loader/loader.conf ]] || fatal_soft "No systemd-boot loader.conf found at /boot/loader/loader.conf — this layer only supports systemd-boot. Skipping."

log "Installing plymouth..."
if ! pacman -S --noconfirm --needed plymouth; then
    fatal_soft "Failed to install plymouth."
fi

# ---------------------------------------------------------------------------
# mkinitcpio HOOKS: insert 'plymouth' immediately after the udev/systemd
# hook, preserving every other hook exactly as Arch's base package (or
# Layer 3a) left it — never wholesale-replace this array. Idempotent:
# skips if plymouth is already present (e.g. on --resume).
# ---------------------------------------------------------------------------
log "Configuring mkinitcpio HOOKS..."
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.pre-plymouth.bak

if grep -qE '^HOOKS=\([^)]*\bplymouth\b' /etc/mkinitcpio.conf; then
    log "plymouth hook already present, skipping insertion."
elif grep -qE '^HOOKS=\([^)]*\budev\b' /etc/mkinitcpio.conf; then
    sed -i -E 's/^(HOOKS=\([^)]*\budev\b)/\1 plymouth/' /etc/mkinitcpio.conf
elif grep -qE '^HOOKS=\([^)]*\bsystemd\b' /etc/mkinitcpio.conf; then
    sed -i -E 's/^(HOOKS=\([^)]*\bsystemd\b)/\1 plymouth/' /etc/mkinitcpio.conf
else
    warn "Could not find udev or systemd in the HOOKS array — inserting after 'base' as a fallback."
    sed -i -E 's/^(HOOKS=\(base)\b/\1 plymouth/' /etc/mkinitcpio.conf
fi

if ! grep -qE '^HOOKS=\([^)]*\bplymouth\b' /etc/mkinitcpio.conf; then
    cp /etc/mkinitcpio.conf.pre-plymouth.bak /etc/mkinitcpio.conf
    fatal_soft "Failed to insert the plymouth hook — restored the original mkinitcpio.conf. Skipping."
fi
log "HOOKS now: $(grep '^HOOKS=' /etc/mkinitcpio.conf)"

# ---------------------------------------------------------------------------
# Patch the actual systemd-boot entries' kernel command lines. Both the
# fallback (always present) and custom (present only if Layer 3b's kernel
# build succeeded) entries get the same silent-boot parameters. Idempotent
# via the 'splash' substring check.
# ---------------------------------------------------------------------------
log "Patching systemd-boot entry kernel command lines..."
SILENT_PARAMS="quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 splash"
PATCHED_ANY=0
for entry in /boot/loader/entries/icarus-fallback.conf /boot/loader/entries/icarus-custom.conf; do
    [[ -f "$entry" ]] || continue
    if grep -q "^options .*splash" "$entry"; then
        log "  $entry already has silent-boot params, skipping."
    else
        cp "$entry" "${entry}.pre-plymouth.bak"
        sed -i -E "s|^(options .*)|\1 ${SILENT_PARAMS}|" "$entry"
        log "  Patched: $entry"
        PATCHED_ANY=1
    fi
done

if [[ ! -f /boot/loader/entries/icarus-fallback.conf ]]; then
    fatal_soft "No icarus-fallback.conf boot entry found — something upstream of this layer didn't run as expected. Skipping."
fi

# ---------------------------------------------------------------------------
# Plymouth theme: bgrt shows the firmware/OEM logo already in the UEFI
# boot graphics, which works on any hardware without needing a
# custom-drawn theme asset.
# ---------------------------------------------------------------------------
log "Setting Plymouth theme to bgrt..."
plymouth-set-default-theme -R bgrt || warn "plymouth-set-default-theme failed — continuing, initramfs regen will still pick up the plymouth hook."

log "Regenerating initramfs for all installed kernels..."
if ! mkinitcpio -P; then
    warn "mkinitcpio -P reported errors — check /etc/mkinitcpio.conf and re-run 'mkinitcpio -P' manually after fixing."
fi

mkdir -p "$ICARUS_LOG_DIR"
touch "$SENTINEL"
log "Layer 8 complete. Sentinel written: ${SENTINEL}"

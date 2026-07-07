#!/usr/bin/env bash
#
# layers/07-native-apps.sh
#
# Chrome doesn't need Wine — it has a native Linux build. Running it
# through Wine would be strictly worse (translation overhead, worse
# GPU acceleration) than running it natively, so that's what this does.
# Same logic applies to "Microsoft apps": there's no native Linux MS
# Office, but there are native alternatives with strong compatibility,
# and Office/Teams both work fine as web apps in a native browser without
# any Wine involved at all. Wine stays reserved (per Layer 5) for the
# things that genuinely have no native or web equivalent.
#
# Chrome and a few others aren't in Arch's official repos, so this layer
# bootstraps an AUR helper (paru) to get them. Worth knowing: AUR packages
# are community-maintained PKGBUILDs, not vetted the way extra/core
# packages are — reasonable for well-known, widely-used packages like
# these, worth being more careful about for anything obscure later.
#
set -uo pipefail  # deliberately not -e — per-app failures shouldn't cascade

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/var/log/icarus}"
ICARUS_REPO_PATH="${ICARUS_REPO_PATH:-/usr/usr_src/icarus-archos}"
SENTINEL="${ICARUS_LOG_DIR}/layer-7-native-apps.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-6-ai-engineering-perf.done"

log() { echo "[layer-7] $*"; }
warn() { echo "[layer-7] WARNING: $*" >&2; }
fatal() { echo "[layer-7] FATAL: $*" >&2; exit 1; }

[[ -f "$PREV_SENTINEL" ]] || fatal "Layer 6 sentinel not found (${PREV_SENTINEL})."
id icarus &>/dev/null || fatal "User 'icarus' not found — this layer needs a real user to build AUR packages as (makepkg refuses to run as root)."

try_install() {
    if ! pacman -S --noconfirm --needed "$@"; then
        warn "Failed to install one or more of: $* — continuing without it/them."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 1. Chromium now — official repo, zero AUR dependency, available
#    immediately even if the AUR bootstrap below fails for any reason.
# ---------------------------------------------------------------------------
log "Installing Chromium (native, official repo)..."
try_install chromium

# ---------------------------------------------------------------------------
# 1b. chafa — enables fastfetch to render images as ASCII/sixel in the
#     terminal. Official repo, no AUR needed.
# ---------------------------------------------------------------------------
log "Installing chafa (terminal image renderer for fastfetch)..."
try_install chafa

# ---------------------------------------------------------------------------
# 2. Bootstrap an AUR helper. paru-bin (prebuilt binary) avoids needing a
#    Rust toolchain just to get the helper itself running.
# ---------------------------------------------------------------------------
log "Bootstrapping paru (AUR helper)..."
try_install base-devel git
AUR_OK=0
if ! command -v paru &>/dev/null; then
    BUILD_DIR="/home/icarus/.cache/icarus-aur-bootstrap"
    sudo -u icarus mkdir -p "$BUILD_DIR"
    if sudo -u icarus bash -c "
        set -e
        cd '${BUILD_DIR}'
        [[ -d paru-bin ]] || git clone https://aur.archlinux.org/paru-bin.git
        cd paru-bin
        git pull
        makepkg -sf --noconfirm
    "; then
        PKG_FILE=$(find "${BUILD_DIR}/paru-bin" -maxdepth 1 -name '*.pkg.tar.zst' | head -1)
        if [[ -n "$PKG_FILE" ]] && pacman -U --noconfirm "$PKG_FILE"; then
            AUR_OK=1
            log "paru installed."
        else
            warn "paru package built but install failed."
        fi
    else
        warn "Could not build paru — AUR-dependent apps below will be skipped. Chromium/LibreOffice above are unaffected."
    fi
else
    AUR_OK=1
fi

aur_install() {
    # Runs as icarus (paru refuses root, same as makepkg) — non-interactive.
    # --skipreview skips the PKGBUILD diff prompt; --useask additionally
    # routes pacman's own conflict/replace prompts through --noconfirm
    # instead of blocking. Both are needed together for this to actually
    # run unattended rather than hanging on the first conflict prompt.
    if [[ $AUR_OK -eq 1 ]]; then
        if ! sudo -u icarus paru -S --noconfirm --skipreview --useask "$@"; then
            warn "paru failed to install: $* — check manually later with 'paru -S $*'."
        fi
    else
        warn "Skipping AUR package(s) '$*' — no working AUR helper."
    fi
}

# ---------------------------------------------------------------------------
# 3. Chrome itself, via AUR now that paru exists.
# ---------------------------------------------------------------------------
log "Installing Google Chrome (AUR)..."
aur_install google-chrome

# ---------------------------------------------------------------------------
# 3b. Theme packages referenced by configs/hypr/hyprland.conf and Layer 5's
#     GTK settings.ini (adw-gtk3-dark, Bibata-Modern-Ice) but not installed
#     there since both are AUR-only and paru doesn't exist until this layer.
# ---------------------------------------------------------------------------
log "Installing theme packages (adw-gtk-theme, bibata-cursor-theme)..."
aur_install adw-gtk-theme
aur_install bibata-cursor-theme

# ---------------------------------------------------------------------------
# 3d. Eww dashboard dependencies. eww-wayland is the Wayland-native build
#     variant (AUR-only); socat/jq/pamixer are runtime deps its widgets
#     call out to for IPC and volume control.
# ---------------------------------------------------------------------------
log "Installing Eww dashboard dependencies..."
aur_install eww-wayland
try_install socat jq pamixer

# ---------------------------------------------------------------------------
# 3c. Live wallpaper. mpvpaper is AUR-only, hence installed here rather
#     than alongside the static PNG in Layer 5. configs/wallpaper/
#     icarus-wallpaper.sh (installed in Layer 5) already falls back to the
#     static PNG via swaybg if mpvpaper isn't present — so if this
#     specific install fails, the desktop still gets a wallpaper, just not
#     the animated one.
# ---------------------------------------------------------------------------
log "Installing mpvpaper (live wallpaper) and the animated wallpaper file..."
aur_install mpvpaper
if [[ -f "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-midnight-live.mp4" ]]; then
    install -d /usr/share/backgrounds/icarus
    install -m 0644 "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-midnight-live.mp4" /usr/share/backgrounds/icarus/icarus-midnight-live.mp4
else
    warn "Missing configs/wallpaper/icarus-midnight-live.mp4 — will fall back to the static wallpaper even if mpvpaper installed fine."
fi
log "Note: mpvpaper decodes video continuously, which costs more battery than a static wallpaper. The 'mpvpaper-stop' companion tool (AUR) can pause it on idle/lock if that matters more than the motion — not installed by default."

# ---------------------------------------------------------------------------
# 4. Microsoft-adjacent needs — native/web-first, Wine only where nothing
#    else covers it.
# ---------------------------------------------------------------------------
log "Installing native Office-compatible suite (LibreOffice)..."
try_install libreoffice-fresh hunspell-en_us

log "Notes on the rest (not auto-installed — pick based on what you actually use):"
log "  - Office/Word/Excel/PowerPoint: office.com works fully in Chrome/Chromium — no install needed."
log "  - Teams: Microsoft dropped native Linux Teams. Use teams.microsoft.com in Chrome, or 'paru -S teams-for-linux' for an unofficial wrapper."
log "  - Edge (if you specifically want it over Chrome): 'paru -S microsoft-edge-stable-bin'."
log "  - VS Code: 'paru -S visual-studio-code-bin' for the MS-branded build."

mkdir -p "$ICARUS_LOG_DIR"
touch "$SENTINEL"
log "Layer 7 complete. Sentinel written: ${SENTINEL}"

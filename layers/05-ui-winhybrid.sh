#!/usr/bin/env bash
#
# layers/05-ui-winhybrid.sh
# Hyprland/Waybar UI layer, native Wine-Wayland integration, lock screen,
# idle management, notifications, power menu, system info, audio
# visualizer, eww dashboard, and dynamic wallpaper-driven theming.
#
set -euo pipefail

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/var/log/icarus}"
ICARUS_REPO_PATH="${ICARUS_REPO_PATH:-/usr/usr_src/icarus-archos}"
SENTINEL="${ICARUS_LOG_DIR}/layer-5-ui-winhybrid.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-4-graphics.done"

log() { echo "[layer-5] $*"; }
fatal() { echo "[layer-5] FATAL: $*" >&2; exit 1; }

[[ -f "$PREV_SENTINEL" ]] || fatal "Layer 4 sentinel not found (${PREV_SENTINEL})."

log "Installing Hyprland desktop stack..."
pacman -S --noconfirm --needed \
    hyprland waybar rofi-wayland kitty dolphin dunst swaybg \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    qt5-wayland qt6-wayland xdg-desktop-portal-hyprland polkit-kde-agent \
    ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji grim slurp \
    greetd greetd-tuigreet papirus-icon-theme

log "Installing lock screen, idle management, and power menu..."
pacman -S --noconfirm --needed \
    hyprlock hypridle wlogout

log "Installing screenshot, clipboard, and brightness tools..."
pacman -S --noconfirm --needed \
    wl-clipboard cliphist brightnessctl playerctl

log "Installing terminal extras and system info..."
pacman -S --noconfirm --needed \
    fastfetch cava pavucontrol python python-pillow

log "Installing Wine / Windows-app compatibility stack..."
pacman -S --noconfirm --needed \
    wine-staging winetricks bottles \
    giflib lib32-giflib libpng lib32-libpng \
    libldap lib32-libldap gnutls lib32-gnutls \
    mpg123 lib32-mpg123 openal lib32-openal \
    v4l-utils lib32-v4l-utils libclc lib32-libclc \
    libxkbcommon lib32-libxkbcommon

# ---------------------------------------------------------------------------
# Wayland application hints — real, widely used variables for making
# Qt/GTK/Electron apps prefer Wayland with an X11 fallback.
# ---------------------------------------------------------------------------
log "Writing Wayland session hints to /etc/environment..."
for VAR in XDG_SESSION_TYPE QT_QPA_PLATFORM GDK_BACKEND ELECTRON_OZONE_PLATFORM_HINT; do
    sed -i "/^${VAR}=/d" /etc/environment
done
cat >> /etc/environment <<'EOF'
XDG_SESSION_TYPE=wayland
QT_QPA_PLATFORM=wayland;xcb
GDK_BACKEND=wayland,x11
ELECTRON_OZONE_PLATFORM_HINT=wayland
EOF

# ---------------------------------------------------------------------------
# Config skeletons — installed to /etc/skel for future users, and also
# copied directly into /home/icarus, since that account was already created
# in Layer 3a before this skeleton existed.
# ---------------------------------------------------------------------------
log "Installing config skeletons..."
mkdir -p /etc/skel/.config/{hypr,waybar,rofi,dunst,kitty,wlogout,fastfetch,cava,eww,icarus/theme}

require_config() {
    local src="$1" dst="$2"
    if [[ -f "$src" ]]; then
        cp "$src" "$dst"
    else
        fatal "Missing required config: $src"
    fi
}

require_config "${ICARUS_REPO_PATH}/configs/hypr/hyprland.conf" /etc/skel/.config/hypr/hyprland.conf
require_config "${ICARUS_REPO_PATH}/configs/hypr/hyprlock.conf" /etc/skel/.config/hypr/hyprlock.conf
require_config "${ICARUS_REPO_PATH}/configs/hypr/hypridle.conf" /etc/skel/.config/hypr/hypridle.conf
require_config "${ICARUS_REPO_PATH}/configs/waybar/config.jsonc" /etc/skel/.config/waybar/config.jsonc
require_config "${ICARUS_REPO_PATH}/configs/waybar/style.css" /etc/skel/.config/waybar/style.css
require_config "${ICARUS_REPO_PATH}/configs/dunst/dunstrc" /etc/skel/.config/dunst/dunstrc
require_config "${ICARUS_REPO_PATH}/configs/kitty/kitty.conf" /etc/skel/.config/kitty/kitty.conf
[[ -f "${ICARUS_REPO_PATH}/configs/kitty/open-actions.conf" ]] && cp "${ICARUS_REPO_PATH}/configs/kitty/open-actions.conf" /etc/skel/.config/kitty/open-actions.conf
require_config "${ICARUS_REPO_PATH}/configs/wlogout/layout" /etc/skel/.config/wlogout/layout
require_config "${ICARUS_REPO_PATH}/configs/wlogout/style.css" /etc/skel/.config/wlogout/style.css
[[ -d "${ICARUS_REPO_PATH}/configs/wlogout/icons" ]] && cp -r "${ICARUS_REPO_PATH}/configs/wlogout/icons" /etc/skel/.config/wlogout/
require_config "${ICARUS_REPO_PATH}/configs/fastfetch/config.jsonc" /etc/skel/.config/fastfetch/config.jsonc
require_config "${ICARUS_REPO_PATH}/configs/fastfetch/logo.txt" /etc/skel/.config/fastfetch/logo.txt
require_config "${ICARUS_REPO_PATH}/configs/cava/config" /etc/skel/.config/cava/config

if [[ -f "${ICARUS_REPO_PATH}/configs/wine/wine-wayland.sh" ]]; then
    install -m 0755 "${ICARUS_REPO_PATH}/configs/wine/wine-wayland.sh" /etc/profile.d/wine-wayland.sh
else
    fatal "Missing configs/wine/wine-wayland.sh in repo payload."
fi

# --- Eww dashboard ---
if [[ -d "${ICARUS_REPO_PATH}/configs/eww" ]]; then
    cp -r "${ICARUS_REPO_PATH}/configs/eww/"* /etc/skel/.config/eww/
    [[ -d /etc/skel/.config/eww/scripts ]] && chmod +x /etc/skel/.config/eww/scripts/*.sh
else
    fatal "Missing configs/eww/ in repo payload."
fi

# --- Rofi themes (system-wide default + skel copies of all variants) ---
if [[ -f "${ICARUS_REPO_PATH}/configs/rofi/icarus-spotlight.rasi" ]]; then
    log "Installing rofi themes..."
    install -d /usr/share/rofi/themes
    install -m 0644 "${ICARUS_REPO_PATH}/configs/rofi/icarus-spotlight.rasi" /usr/share/rofi/themes/icarus-spotlight.rasi
else
    fatal "Missing configs/rofi/icarus-spotlight.rasi in repo payload."
fi
if [[ -d "${ICARUS_REPO_PATH}/configs/rofi" ]]; then
    cp -r "${ICARUS_REPO_PATH}/configs/rofi/"* /etc/skel/.config/rofi/
else
    fatal "Missing configs/rofi/ in repo payload."
fi

# ---------------------------------------------------------------------------
# Wallpapers. Two distinct tools, two distinct names — this distinction
# matters and was a real bug earlier in this file's history:
#   icarus-wallpaper        — the startup daemon wrapper (live video via
#                              mpvpaper, falls back to static PNG via
#                              swaybg). Runs once, via exec-once.
#   icarus-wallpaper-switch — the interactive Rofi-based picker over
#                              configs/wallpaper/references/. Runs
#                              repeatedly, bound to SUPER+W.
# Installing both to the same path would make one silently overwrite the
# other depending on install order.
# ---------------------------------------------------------------------------
if [[ ! -f "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-midnight.png" ]]; then
    fatal "Missing configs/wallpaper/icarus-midnight.png in repo payload."
fi
install -d /usr/share/backgrounds/icarus
install -m 0644 "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-midnight.png" /usr/share/backgrounds/icarus/icarus-midnight.png

if [[ -f "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-wallpaper.sh" ]]; then
    install -m 0755 "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-wallpaper.sh" /usr/local/bin/icarus-wallpaper
else
    fatal "Missing configs/wallpaper/icarus-wallpaper.sh in repo payload."
fi

if [[ -f "${ICARUS_REPO_PATH}/configs/wallpaper/switcher.sh" ]]; then
    log "Installing wallpaper switcher..."
    install -m 0755 "${ICARUS_REPO_PATH}/configs/wallpaper/switcher.sh" /usr/local/bin/icarus-wallpaper-switch
else
    fatal "Missing configs/wallpaper/switcher.sh in repo payload."
fi

if [[ -d "${ICARUS_REPO_PATH}/configs/wallpaper/references" ]]; then
    mkdir -p /usr/share/backgrounds/icarus/references
    cp -r "${ICARUS_REPO_PATH}/configs/wallpaper/references/"* /usr/share/backgrounds/icarus/references/
else
    fatal "Missing configs/wallpaper/references/ in repo payload — the switcher would error on first use without it."
fi

# ---------------------------------------------------------------------------
# Dynamic palette generator + static theme defaults. The defaults matter:
# eww, GTK, and Waybar all import files under ~/.config/icarus/theme/ that
# only get (re)generated when icarus-palette runs — without a pre-shipped
# static default, those imports would fail on first login before the
# wallpaper switcher is ever used.
# ---------------------------------------------------------------------------
if [[ -f "${ICARUS_REPO_PATH}/tools/icarus-palette.py" && -d "${ICARUS_REPO_PATH}/configs/theme" ]]; then
    log "Installing icarus-palette generator and static theme defaults..."
    install -m 0755 "${ICARUS_REPO_PATH}/tools/icarus-palette.py" /usr/local/bin/icarus-palette
    cp -r "${ICARUS_REPO_PATH}/configs/theme" /etc/skel/.config/icarus/
else
    fatal "Missing tools/icarus-palette.py or configs/theme/ in repo payload."
fi

# ---------------------------------------------------------------------------
# GTK theme/icon/cursor settings. Papirus-Dark is installed above (official
# repo). adw-gtk3-dark and Bibata-Modern-Ice are AUR-only and installed by
# Layer 7 once paru exists — referencing their names here is safe regardless
# of install order, since nothing reads settings.ini until first login,
# which happens after every layer has finished.
# ---------------------------------------------------------------------------
log "Writing GTK theme settings..."
mkdir -p /etc/skel/.config/gtk-3.0 /etc/skel/.config/gtk-4.0
for GTK_DIR in gtk-3.0 gtk-4.0; do
cat > "/etc/skel/.config/${GTK_DIR}/settings.ini" << 'EOF'
[Settings]
gtk-theme-name=adw-gtk3-dark
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Bibata-Modern-Ice
gtk-cursor-theme-size=22
gtk-application-prefer-dark-theme=1
EOF
# NOTE: exactly one ".." here, not two — this file lives at
# /etc/skel/.config/<gtk-dir>/gtk.css, and the theme lives at
# /etc/skel/.config/icarus/theme/gtk.css, which is one level up
# (out of <gtk-dir>/) then into icarus/theme/, not two.
cat > "/etc/skel/.config/${GTK_DIR}/gtk.css" << 'EOF'
@import url("../icarus/theme/gtk.css");
EOF
done

# ---------------------------------------------------------------------------
# Fastfetch on terminal open — runs every time a new interactive bash
# session starts so the Icarus branding is the first thing you see.
# ---------------------------------------------------------------------------
log "Adding fastfetch to shell startup..."
if ! grep -q "fastfetch" /etc/skel/.bashrc 2>/dev/null; then
    cat >> /etc/skel/.bashrc << 'EOF'

# Icarus-ArchOS — show system info on terminal open
if command -v fastfetch &>/dev/null; then
    fastfetch
fi
EOF
fi

# ---------------------------------------------------------------------------
# Display manager. Without this, boot lands at a plain TTY login and
# Hyprland has to be started by hand every time — greetd + tuigreet gives an
# actual login screen that launches Hyprland on successful auth. Both
# packages are in Arch's official 'extra' repo, no AUR helper needed.
# ---------------------------------------------------------------------------
log "Configuring greetd + tuigreet as the login manager..."
mkdir -p /etc/greetd
cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --remember --remember-session --time --cmd Hyprland --theme 'border=darkgray;text=lightgray;prompt=lightgray;time=darkgray;action=blue;button=darkgray;container=black;input=white'"
user = "greeter"
EOF

if ! id greeter &>/dev/null; then
    useradd -M -G video greeter
fi

systemctl enable greetd.service

# ---------------------------------------------------------------------------
# Pipewire user services. Arch's pipewire packaging generally auto-enables
# these via systemd presets, but that isn't guaranteed across package
# revisions — enabling explicitly and globally (i.e. for every user, not
# just whoever is logged in when this script runs) removes the ambiguity.
# ---------------------------------------------------------------------------
log "Enabling Pipewire audio services for all users..."
systemctl --global enable pipewire.service pipewire-pulse.service wireplumber.service 2>&1 \
    || log "WARNING: could not globally enable Pipewire user services — verify manually after first login with 'systemctl --user status pipewire'."

if id icarus &>/dev/null; then
    log "Populating existing user 'icarus' home directory with the skeleton..."
    mkdir -p /home/icarus/.config
    cp -rn /etc/skel/.config/. /home/icarus/.config/
    chown -R icarus:icarus /home/icarus
fi

mkdir -p "$ICARUS_LOG_DIR"
touch "$SENTINEL"
log "Layer 5 complete. Sentinel written: ${SENTINEL}"

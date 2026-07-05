#!/usr/bin/env bash
#
# layers/05-ui-winhybrid.sh
# Hyprland/Waybar UI layer and native Wine-Wayland integration.
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
mkdir -p /etc/skel/.config/{hypr,waybar,rofi}

if [[ -f "${ICARUS_REPO_PATH}/configs/hypr/hyprland.conf" ]]; then
    cp "${ICARUS_REPO_PATH}/configs/hypr/hyprland.conf" /etc/skel/.config/hypr/hyprland.conf
else
    fatal "Missing configs/hypr/hyprland.conf in repo payload."
fi

if [[ -f "${ICARUS_REPO_PATH}/configs/waybar/config.jsonc" ]]; then
    cp "${ICARUS_REPO_PATH}/configs/waybar/config.jsonc" /etc/skel/.config/waybar/config.jsonc
    cp "${ICARUS_REPO_PATH}/configs/waybar/style.css" /etc/skel/.config/waybar/style.css
else
    fatal "Missing configs/waybar/*.{jsonc,css} in repo payload."
fi

if [[ -f "${ICARUS_REPO_PATH}/configs/wine/wine-wayland.sh" ]]; then
    install -m 0755 "${ICARUS_REPO_PATH}/configs/wine/wine-wayland.sh" /etc/profile.d/wine-wayland.sh
else
    fatal "Missing configs/wine/wine-wayland.sh in repo payload."
fi

if [[ -f "${ICARUS_REPO_PATH}/configs/rofi/icarus-spotlight.rasi" ]]; then
    log "Installing rofi theme system-wide..."
    install -d /usr/share/rofi/themes
    install -m 0644 "${ICARUS_REPO_PATH}/configs/rofi/icarus-spotlight.rasi" /usr/share/rofi/themes/icarus-spotlight.rasi
else
    fatal "Missing configs/rofi/icarus-spotlight.rasi in repo payload."
fi

if [[ -f "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-midnight.png" ]]; then
    log "Installing wallpaper..."
    install -d /usr/share/backgrounds/icarus
    install -m 0644 "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-midnight.png" /usr/share/backgrounds/icarus/icarus-midnight.png
else
    fatal "Missing configs/wallpaper/icarus-midnight.png in repo payload."
fi

if [[ -f "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-wallpaper.sh" ]]; then
    install -m 0755 "${ICARUS_REPO_PATH}/configs/wallpaper/icarus-wallpaper.sh" /usr/local/bin/icarus-wallpaper
else
    fatal "Missing configs/wallpaper/icarus-wallpaper.sh in repo payload."
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
done

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
command = "tuigreet --remember --remember-session --time --cmd Hyprland"
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

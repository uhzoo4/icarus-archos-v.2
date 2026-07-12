#!/usr/bin/env bash
# apply-extra.sh
#
# Helper script to apply the newly integrated EXTRA themes, cursors,
# wallpapers, and dynamic video palette upgrades directly to an already booted system.
#
# Run this as your normal user (it will prompt for sudo when necessary).

set -euo pipefail

# Style helpers
c_reset='\033[0m'; c_bold='\033[1m'; c_green='\033[1;32m'; c_yellow='\033[1;33m'; c_red='\033[1;31m'; c_blue='\033[1;34m'
info()  { printf "    %s\n" "$1"; }
ok()    { printf "${c_green}[ok]${c_reset} %s\n" "$1"; }
warn()  { printf "${c_yellow}[warn]${c_reset} %s\n" "$1"; }
err()   { printf "${c_red}[error]${c_reset} %s\n" "$1"; }
step()  { printf "\n${c_blue}==>${c_reset} ${c_bold}%s${c_reset}\n" "$1"; }

if [[ "${EUID}" -eq 0 ]]; then
    err "Do not run this script as root. Run it as your normal user. Sudo will be requested when needed."
    exit 1
fi

REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${REPO_PATH}/icarus-assemble.sh" ]]; then
    err "This script must be executed from inside the icarus-archos repository root."
    exit 1
fi

step "1. Installing system dependencies"
sudo pacman -S --needed --noconfirm sassc ffmpeg socat
ok "System dependencies installed."

step "2. Copying Icarus wallpaper scripts & dynamic palette generator"
sudo cp "${REPO_PATH}/configs/wallpaper/switcher.sh" /usr/local/bin/icarus-wallpaper-switch
sudo cp "${REPO_PATH}/configs/wallpaper/icarus-wallpaper.sh" /usr/local/bin/icarus-wallpaper
sudo cp "${REPO_PATH}/configs/wallpaper/daemon.sh" /usr/local/bin/icarus-wallpaper-daemon
sudo cp "${REPO_PATH}/tools/icarus-palette.py" /usr/local/bin/icarus-palette

sudo chmod +x /usr/local/bin/icarus-wallpaper* /usr/local/bin/icarus-palette
ok "Scripts installed to /usr/local/bin/."

step "3. Compiling and installing Archos themes & Mew cursor"
# Archos GTK Theme
if [[ -d "${REPO_PATH}/pkgs/themes/Archos-gtk-theme" ]]; then
    info "Compiling Archos GTK Theme..."
    ( cd "${REPO_PATH}/pkgs/themes/Archos-gtk-theme" && ./install.sh -d /usr/share/themes -l -c dark -n Archos --silent-mode )
    ok "Archos GTK theme compiled and installed."
else
    warn "Archos GTK theme source not found."
fi

# Archos Icon Theme
if [[ -d "${REPO_PATH}/pkgs/themes/Archos-icon-theme" ]]; then
    info "Installing Archos Icon Theme..."
    ( cd "${REPO_PATH}/pkgs/themes/Archos-icon-theme" && ./install.sh -d /usr/share/icons -n Archos -t all )
    ok "Archos icon theme installed."
else
    warn "Archos icon theme source not found."
fi

# Archos Cursors
if [[ -d "${REPO_PATH}/pkgs/themes/Archos-cursors" ]]; then
    info "Installing Archos Cursors..."
    sudo mkdir -p /usr/share/icons/Archos-cursors
    sudo cp -pr "${REPO_PATH}/pkgs/themes/Archos-cursors/dist/." /usr/share/icons/Archos-cursors/
    ok "Archos cursors installed."
else
    warn "Archos cursors source not found."
fi

# Aura Mew Cursor
if [[ -d "${REPO_PATH}/pkgs/themes/Aura-Mew-Cursor" ]]; then
    info "Installing Aura Mew Cursor..."
    sudo mkdir -p /usr/share/icons/Aura-Mew-Cursor
    sudo cp -pr "${REPO_PATH}/pkgs/themes/Aura-Mew-Cursor/." /usr/share/icons/Aura-Mew-Cursor/
    ok "Aura Mew cursor installed."
else
    warn "Aura Mew cursor source not found."
fi

step "4. Copying and caching new wallpapers"
sudo mkdir -p /usr/share/backgrounds/icarus/references
if [[ -d "${REPO_PATH}/configs/wallpaper/references" ]]; then
    sudo cp -rn "${REPO_PATH}/configs/wallpaper/references/." /usr/share/backgrounds/icarus/references/
fi
ok "Wallpapers integrated into references."

step "5. Caching Firefox Archos theme"
if [[ -d "${REPO_PATH}/pkgs/themes/Archos-firefox-theme" ]]; then
    sudo mkdir -p /usr/share/archos
    sudo cp -r "${REPO_PATH}/pkgs/themes/Archos-firefox-theme" /usr/share/archos/firefox-theme
    ok "Firefox theme cached. You can apply it anytime by running 'icarus-welcome'."
fi

step "6. Writing user GTK default preferences"
mkdir -p "${HOME}/.config/gtk-3.0" "${HOME}/.config/gtk-4.0"
cat > "${HOME}/.config/gtk-3.0/settings.ini" << 'EOF'
[Settings]
gtk-theme-name=Archos-Dark
gtk-icon-theme-name=Archos-dark
gtk-cursor-theme-name=Archos-cursors
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=1
EOF
cp "${HOME}/.config/gtk-3.0/settings.ini" "${HOME}/.config/gtk-4.0/settings.ini"
ok "User GTK parameters written."

step "7. Restarting wallpaper daemon services"
killall icarus-wallpaper-daemon mpvpaper swaybg 2>/dev/null || true
(icarus-wallpaper &)
ok "Wallpaper launcher & intelligente pausing daemon successfully booted!"

step "Setup complete! Enjoy the peak visuals."

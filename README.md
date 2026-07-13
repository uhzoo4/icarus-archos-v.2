<div align="center">

```text
  █████▒ ▒█████   ██▀███   ▄████▄   ██▀███   ▄████▄    ██████ 
▓██   ▒ ▒██▒  ██▒▓██ ▒ ██▒▒██▀ ▀█  ▓██ ░▄█ ▒▒██▀ ▀█  ▒██    ▒ 
▒████ ░ ▒██░  ██▒▓██ ░▄█ ▒▒▓█    ▄ ▓██ ░▄█ ▒▒▓█    ▄ ░ ▓██▄   
░▓█▒  ░ ▒██   ██░▒██▀▀█▄  ▒▓▓▄ ▄██▒▒██▀▀█▄  ▒▓▓▄ ▄██▒  ▒   ██▒
░▒█░    ░ ████▓▒░░██▓ ▒██▒▒ ▓███▀ ░░██▓ ▒██▒▒ ▓███▀ ░▒██████▒▒
 ▒ ░    ░ ▒░▒░▒░ ░ ▒▓ ░▒▓░░ ░▒ ▒  ░░ ▒▓ ░▒▓░░ ░▒ ▒  ░░ ▒▓▒ ▒ ░
 ░        ░ ▒ ▒░   ░▒ ░ ▒░  ░  ▒     ░▒ ░ ▒░  ░  ▒   ░ ░▒  ░ ░
 ░ ░    ░ ░ ░ ▒    ░░   ░ ░          ░░   ░ ░          ░  ░  
            ░ ░     ░     ░ ░         ░     ░ ░             ░
                          ░                 ░                
```

# ARCHOS HYPRLAND — UI & RICING LAYER
**The Premium Ricing & Custom Desktop Configuration for CachyOS / Arch Linux**

[![CachyOS](https://img.shields.io/badge/OS-CachyOS-blue.svg?logo=arch-linux&logoColor=white&style=for-the-badge)](#)
[![Arch Linux](https://img.shields.io/badge/OS-Vanilla_Arch-blue.svg?logo=arch-linux&logoColor=white&style=for-the-badge)](#)
[![Compositor](https://img.shields.io/badge/WM-Hyprland-orange.svg?style=for-the-badge)](#)
[![Theme Engine](https://img.shields.io/badge/THEME-Archos_Glass-purple.svg?style=for-the-badge)](#)
[![System Protection](https://img.shields.io/badge/System-Kernel_Safe-success.svg?style=for-the-badge)](#)

*This is a dedicated, system-safe frontend and ricing build. It is optimized to deploy custom GTK/icon themes, application preferences, window manager configs, and wallpapers directly onto an already booted CachyOS/Arch Linux system without touching kernel settings, /boot configurations, or level-zero compute operations.*

</div>

---

## ⚡ Key Features

### 🎨 The Archos Premium Aesthetic Stack
- **Archos GTK Theme**: A glassmorphic dark theme supporting GTK3, GTK4, and Libadwaita.
- **Archos Icon Theme**: Muted, premium high-res icon set tailored for dark layouts.
- **Archos Cursors & Aura-Mew-Cursor**: Premium macOS-like animated cursors or custom Aura-Mew animations.
- **Archos Firefox Theme**: Natively styles your browser to merge into the desktop's styling.
- **Hyprlock Fades**: Custom Bezier curves and overshot spring physics integrated directly into your lock screen configuration.

### 🎥 Video Wallpaper & Dynamic Color Engine
An absolute monster of a live wallpaper system. It plays high-res `.mp4`, `.webm`, `.mkv`, and `.gif` wallpapers natively via `mpvpaper` with two key features:
1. **Dynamic Video Frame Extraction**: When you select a video wallpaper, `ffmpeg` automatically extracts a representative frame to generate a custom Material You dynamic color palette for your entire OS (Hyprland, Waybar, kitty, Rofi) in real-time.
2. **Battery & Fullscreen Pausing Daemon**: A background service (`icarus-wallpaper-daemon`) monitors your state. If you switch to battery power or run any fullscreen application, it instantly pauses video decoding to save energy and GPU performance, resuming immediately when plugged back in or when the window is closed.

### 📋 Cockpit Terminal Bindings
No more awkward keyboard finger-twisting. `kitty.conf` is configured with smart clipboard maps:
- **`Ctrl + C`**: Copies selected text when there is active selection; otherwise, it sends `SIGINT` (standard interrupt) to cancel a command.
- **`Ctrl + V`**: Pastes directly from the clipboard.

---

## 🚀 How to Deploy on a Booted System

To apply this custom desktop ricing, wallpapers, video wallpaper engine, and configurations directly onto your running CachyOS or Arch Linux installation:

```bash
# Clone and enter the repository (rename to your preferred choice)
git clone https://github.com/your-username/archos-hyprland.git
cd archos-hyprland

# Run the master user configuration launcher
./run.sh
```

### What this script does:
1. Installs system dependencies for UI (Hyprland desktop stack, waybar, rofi, dunst, kitty, fastfetch, cava, etc.) and AUR dependencies via your helper (`paru` or `yay`).
2. Installs custom wallpaper tools, switcher, and pause-daemon utilities into `/usr/local/bin/`.
3. Compiles and installs the custom GTK themes, icons, and cursor sets.
4. Integrates the WhiteSur/Archos custom wallpapers.
5. Populates your user folder (`~/.config/`) with configuration files for Hyprland, Waybar, Kitty, Dunst, Rofi, Fastfetch, and Eww.

> [!NOTE]
> This build **specifically skips SDDM login screen overrides and Plymouth bootloader splash themes** in order to avoid altering core system initialization files or calling root commands for boot configurations.

---

## 📂 Repository Layout

```text
archos-hyprland/
├── apply-extra.sh                  # One-click theme applicator (adapted to skip boot configurations)
├── run.sh                          # Master script to initialize, update, and deploy the UI layer
├── update.sh                       # Pulls the latest commits and executes run.sh
├── configs/
│   ├── hypr/                       # Hyprland & Hyprlock configurations
│   ├── waybar/                     # Waybar status panel configurations
│   ├── kitty/                      # Cockpit terminal setup (smart copy/paste)
│   ├── cava/                       # Cava audio visualizer configuration
│   ├── dunst/                      # Dunst notification configurations
│   ├── eww/                        # Eww dashboard widgets
│   ├── fastfetch/                  # Fastfetch system info logo configurations
│   ├── nvim/                       # Neovim text editor configs
│   ├── rofi/                       # Rofi launcher and power menus
│   ├── theme/                      # CSS/Conf assets for dynamic coloring
│   ├── wallpaper/                  # Wallpaper picker UI, daemon, and references
│   └── wine/                       # Wine-Wayland launch wrapper scripts
├── pkgs/
│   ├── themes/                     # Theme packages (GTK, Icon, Cursor themes)
│   └── sddm-themes/                # Desktop login theme assets
├── layers/
│   ├── MANIFEST                    # Frontend-only ordered layers index
│   ├── 05-ui-winhybrid.sh          # Hyprland/Waybar configuration setup
│   ├── 07-native-apps.sh           # Apps layout (Firefox styling, welcome scripts)
│   └── 09-curated-apps.sh          # Small daily-use tool profiler (icarus-apps)
└── tools/
    └── icarus-palette.py           # Python dynamic palette generator script
```

---

<div align="center">
Optimized to the limits. Enjoy the flight.
</div>

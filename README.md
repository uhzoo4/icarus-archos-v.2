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

# ARCHOS WORKSTATION — ICARUS-ARCHOS
**The Absolute Peak of CachyOS, Vanilla Arch Linux & Hyprland Engineering**

[![CachyOS](https://img.shields.io/badge/OS-CachyOS-blue.svg?logo=arch-linux&logoColor=white&style=for-the-badge)](#)
[![Arch Linux](https://img.shields.io/badge/OS-Vanilla_Arch-blue.svg?logo=arch-linux&logoColor=white&style=for-the-badge)](#)
[![Compositor](https://img.shields.io/badge/WM-Hyprland-orange.svg?style=for-the-badge)](#)
[![Theme Engine](https://img.shields.io/badge/THEME-Archos_Glass-purple.svg?style=for-the-badge)](#)
[![Status](https://img.shields.io/badge/Status-Fully_Weaponized-success.svg?style=for-the-badge)](#)

*An automated, hyper-optimized workstation assembly toolkit that builds an ultra-premium, dynamically-themed graphical environment from scratch on both CachyOS and vanilla Arch Linux. Zero limits. Maximum visual performance.*

---

### 🌌 The Experience (Cinematic Animations)
<div align="center">
  <img src="configs/wallpaper/references/icarus-redshift-relay-live.gif" width="48%" style="border-radius: 8px; box-shadow: 0 4px 20px rgba(0,0,0,0.5);" />
  <img src="configs/wallpaper/references/icarus-event-horizon-live.gif" width="48%" style="border-radius: 8px; box-shadow: 0 4px 20px rgba(0,0,0,0.5);" />
</div>

</div>

---

## ⚡ Peak Features

### 🎨 The Archos Premium Aesthetic Stack
We built a matching visual system that makes the desktop look like a unified interface:
* **Archos GTK Theme**: A glassmorphic dark theme supporting GTK3, GTK4, and Libadwaita.
* **Archos Icon Theme**: Muted, premium high-res icon set tailored for dark layouts.
* **Archos Cursors & Aura-Mew-Cursor**: Switch between sleek macOS-like animated cursors or custom Aura-Mew animations.
* **Archos Firefox Theme**: Natively styles your browser to merge into the desktop's styling.
* **SDDM Astronaut Login**: Hardware-accelerated Qt6 login interface with smooth fades.
* **Qylock Native Fades**: Overshot spring physics and custom Bezier curves integrated directly into `hyprlock.conf`.

### 🎥 Intelligent Video Wallpaper Engine (Caelestia-AW Inspired)
An absolute monster of a live wallpaper system. It plays high-res `.mp4`, `.webm`, `.mkv`, and `.gif` wallpapers natively via `mpvpaper` with two peak features:
1. **Dynamic Video Frame Extraction**: When you select a video wallpaper, `ffmpeg` automatically extracts a representative frame to generate a custom Material You dynamic color palette for your entire OS (Hyprland, Waybar, kitty, Rofi) in real-time. **No static companion images needed.**
2. **Battery & Fullscreen Pausing Daemon**: A background service (`icarus-wallpaper-daemon`) monitors your state. If you switch to battery power or run any fullscreen application, it instantly pauses video decoding to save energy and GPU performance, resuming immediately when plugged back in or when the window is closed.

### 📋 Cockpit Terminal Bindings
No more awkward keyboard finger-twisting. [kitty.conf](configs/kitty/kitty.conf) is configured with smart clipboard maps:
* **`Ctrl + C`**: Copies selected text when there is active selection; otherwise, it sends `SIGINT` (standard interrupt) to cancel a command.
* **`Ctrl + V`**: Pastes directly from the clipboard.

---

## 🛠️ System Architecture

The conductor (`icarus-assemble.sh`) reads the `layers/MANIFEST` and runs script layers sequentially:

```mermaid
graph TD
    A[Conductor: icarus-assemble.sh] --> B[01-live-partition.sh: Drive partitioning & Btrfs config]
    B --> C[02-base-install.sh: Pacstrap core Skeleton]
    C --> D[03a-03c: Custom Kernel, Daemons & seat config]
    D --> E[04-graphics.sh: Mesa & VA-API acceleration]
    E --> F[05-ui-winhybrid.sh: Hyprland, Waybar, SDDM, Archos Theme compilation]
    F --> G[07-native-apps.sh: Welcome script, web browsers, Firefox styling]
    G --> H[08-silent-boot.sh: Plymouth boot animations & quiet logs]
```

---

## 🚀 How to Deploy

### Scenario A: Clean Install on a Live USB
Boot any CachyOS or Arch Linux Live USB, connect to Wi-Fi using `nmtui`, clone the repo, and run:

```bash
# Clone the repository
git clone https://github.com/uhzoo4/icarus-archos-v.2.git
cd icarus-archos-v.2

# Execute the installer against your target drive (e.g. /dev/nvme0n1)
sudo ./icarus-assemble.sh --target /dev/nvme0n1 --allow-internal
```
Once complete, reboot, remove your USB pendrive, and boot directly into your new Archos system!

### Scenario B: Direct Setup on an Already Booted System
If you are already running CachyOS or Arch and just want to apply this theme, the wallpapers, the video wallpaper engine, and the terminal keybinds without re-installing:

```bash
# Clone and enter the repository
git clone https://github.com/uhzoo4/icarus-archos-v.2.git
cd icarus-archos-v.2

# Run the single-step theme applicator
./apply-extra.sh
```

---

## 📂 Repository Structure

```text
icarus-archos-v.2/
├── apply-extra.sh                  # One-click theme applicator for running systems
├── icarus-assemble.sh              # Master installer conductor for live USBs
├── pkgs/
│   └── themes/                     # Archos GTK, Icon, Cursor, and Firefox theme sources
├── layers/
│   ├── MANIFEST                    # Ordered list of install steps
│   ├── 05-ui-winhybrid.sh          # Hyprland UI layer & Archos assets compilation
│   └── 07-native-apps.sh           # Native applications & welcome script
├── configs/
│   ├── hypr/                       # Hyprland & Hyprlock (Qylock) curves
│   ├── kitty/                      # Cockpit terminal (smart copy/paste)
│   └── wallpaper/
│       ├── references/             # Tracked macOS & Nord wallpapers
│       ├── switcher.sh             # Rofi wallpaper switcher
│       └── daemon.sh               # Intelligent pause daemon
└── tools/
    └── icarus-palette.py           # Dynamic palette generator (ffmpeg frame extractor)
```

---

<div align="center">
<i>"If you fly too close to the sun, you better have a cooling system that can handle it."</i><br>
Optimized to the limits. Enjoy the flight.
</div>

<div align="center">

```text
  ██▓ ▄████▄   ▄▄▄       ██▀███   █    ██   ██████ 
 ▓██▒▒██▀ ▀█  ▒████▄    ▓██ ▒ ██▒ ██  ▓██▒▒██    ▒ 
 ▒██▒▒▓█    ▄ ▒██  ▀█▄  ▓██ ░▄█ ▒▓██  ▒██░░ ▓██▄   
 ░██░▒▓▓▄ ▄██▒░██▄▄▄▄██ ▒██▀▀█▄  ▓▓█  ░██░  ▒   ██▒
 ░██░▒ ▓███▀ ░ ▓█   ▓██▒░██▓ ▒██▒▒▒█████▓ ▒██████▒▒
 ░▓  ░ ░▒ ▒  ░ ▒▒   ▓▒█░░ ▒▓ ░▒▓░░▒▓▒ ▒ ▒ ▒ ▒▓▒ ▒ ░
  ▒ ░  ░  ▒     ▒   ▒▒ ░  ░▒ ░ ▒░░░▒░ ░ ░ ░ ░▒  ░ ░
  ▒ ░░          ░   ▒     ░░   ░  ░░░ ░ ░ ░  ░  ░  
  ░  ░ ░            ░  ░   ░        ░           ░  
     ░                                             
```

# ICARUS-ARCHOS
**The Absolute Peak of CachyOS & Hyprland Engineering**

[![Arch Linux](https://img.shields.io/badge/OS-CachyOS-blue.svg?logo=arch-linux)](#)
[![Hyprland](https://img.shields.io/badge/WM-Hyprland-orange.svg)](#)
[![Status](https://img.shields.io/badge/Status-Locked_&_Loaded-success.svg)](#)

*An automated, hyper-optimized, standalone installer that transforms a blank drive into an absolute masterpiece of Linux customization. No bloat. No limits. Just pure performance and breathtaking aesthetics.*

</div>

---

## ⚡ What is this?
Icarus-ArchOS is not just a configuration file—it is a **fully weaponized, automated operating system assembly toolkit**. It physically partitions your drive, straps down the CachyOS kernel, and builds an ultra-premium graphical environment from scratch. 

We took the absolute best components of **Awesome-Omarchy**, **SDDM Astronaut**, and **Qylock**, reverse-engineered their animations and optimizations, and hardcoded them directly into the native Hyprland ecosystem. The result is a desktop that looks and feels like it belongs in the year 2077.

### 🌌 The Experience (Animated)
<div align="center">
  <img src="configs/wallpaper/references/icarus-redshift-relay-live.gif" width="48%" />
  <img src="configs/wallpaper/references/icarus-event-horizon-live.gif" width="48%" />
</div>

### 🔥 Peak Features
- **SDDM Astronaut Login**: Replaced the terminal login with a butter-smooth, hardware-accelerated Qt6 login screen.
- **Cyber-Industrial Boot Splash**: The OEM boot logo is obliterated, replaced by a glowing Plymouth `circuit` animation.
- **Qylock Native Fades**: We stole the exact Bezier curves and overshot spring physics from `qylock` and natively integrated them into `hyprlock.conf` for the most premium lockscreen experience on Wayland.
- **Automated Wallpaper Harvesting**: Our reverse-engineering algorithm automatically hunts through your `STEAL` directory, grabs every high-res image it can find, and dynamically integrates them into your `configs/wallpaper/references` folder for immediate deployment.
- **Dynamic Theming**: Hit `SUPER + SHIFT + D` and watch your entire OS—Hyprland, Waybar, Terminal, and GTK apps—recolor themselves instantly to match your wallpaper.

---

## 🛠️ How it Works (The Architecture)

The installer uses a **layered, resumable conductor** (`icarus-assemble.sh`). It reads the `layers/MANIFEST` and executes shell scripts in perfect sequence:

1. **`01-live-partition.sh`**: Wipes the drive, creates Btrfs subvolumes, and prepares the filesystem.
2. **`02-base-install.sh`**: Pacstraps the core Arch/CachyOS skeleton.
3. **`03a-04`**: Builds the custom kernel, daemons, and graphics stack (Mesa/VA-API).
4. **`05-ui-winhybrid.sh`**: The heart of the beast. Installs Hyprland, SDDM, Waybar, dynamically harvests your `STEAL` folder, and wires up all the animations and UI elements.
5. **`08-silent-boot.sh`**: Configures Plymouth, masks kernel outputs, and rebuilds the `initramfs` so your boot process is flawlessly silent.

---

## 🚀 How to Deploy (Usage)

This is designed to be completely standalone. You do **not** run the CachyOS GUI installer.

1. **Boot a CachyOS or Arch Linux Live USB**.
2. **Close any installer windows** that pop up. You want the raw terminal.
3. **Mount your USB** containing this folder (or `git clone` it).
4. **Execute the Conductor**:

```bash
# Navigate to the repository
cd /path/to/icarus-archos

# Make the scripts executable
chmod +x icarus-assemble.sh
chmod +x layers/*.sh

# Run the installer against your target drive (e.g., /dev/nvme0n1)
./icarus-assemble.sh --target /dev/nvme0n1
```

*(Note: If you are installing onto an internal drive, append `--allow-internal`. Make sure you don't accidentally wipe your Windows drive!)*

---

## 📂 Directory Layout

```text
icarus-archos/
├── icarus-assemble.sh              # Master conductor — run this
├── STEAL/                          # Drop any Omarchy/SDDM/Plymouth themes here. The installer will auto-harvest them.
├── layers/
│   ├── MANIFEST                    # Ordered layer list the conductor reads
│   ├── 01-live-partition.sh        # Host: wipe + partition + Btrfs subvolumes
│   ├── 02-base-install.sh          # Host: pacstrap + fstab + stage repo
│   ├── 05-ui-winhybrid.sh          # Chroot: Hyprland/Waybar/SDDM/Animations
│   └── 08-silent-boot.sh           # Chroot: Plymouth splash + quiet boot
├── configs/
│   ├── hypr/                       # Hyprland configs + Qylock Bezier curves
│   ├── theme/                      # Dynamic color generation
│   └── wallpaper/references/       # Harvested wallpapers live here
```

---

<div align="center">
<i>"If you fly too close to the sun, you better have a cooling system that can handle it."</i><br>
Built for peak performance. Optimized for absolute zero-latency rendering. Enjoy the flight.
</div>

# Theme research and provenance

The theme references below informed Icarus's motion, composition, and
personalization direction. Icarus does **not** vendor their theme code,
artwork, fonts, videos, or icon packs: several source collections include
third-party media or are for incompatible desktop stacks. The wallpapers in
`configs/wallpaper/references/icarus-*.png` and their live variants are
original Icarus assets.

| Project | Licence | Icarus decision |
| --- | --- | --- |
| [Qylock](https://github.com/Darkkal44/qylock) | GPL-3.0 | Used as a motion-first lock/login design reference only. Its documentation lists third-party wallpaper and font sources, so none are imported. |
| [SDDM Astronaut Theme](https://github.com/Keyitdev/sddm-astronaut-theme) | GPL-3.0 | Informed the idea of optional animated visual states. Not installed because Icarus uses `greetd`, not SDDM. |
| [SilentSDDM](https://github.com/uiriansan/SilentSDDM) | GPL-3.0 | Reviewed for its minimalist animated login approach. Not imported for the same display-manager reason. |
| [adi1090x Plymouth Themes](https://github.com/adi1090x/plymouth-themes) | GPL-3.0 | Studied for boot motion; no theme or frames are copied because it contains ports of Android boot animations. |
| [Awesome Omarchy](https://github.com/aorumbayev/awesome-omarchy) | CC0-1.0 | Used as a discovery index for composable Hyprland theming ideas. |
| [ddh4r4m/Arch](https://github.com/ddh4r4m/Arch) | GPL-2.0 | KDE/Plasma-specific; not technically applicable to Icarus's Hyprland stack. |

This keeps the project legally clear and preserves the single Icarus visual
language rather than mixing several unrelated themes.

The original Icarus Ring theme under configs/plymouth/icarus-ring is work in
progress. It is deliberately not the installer default yet: Layer 8 continues
to use the hardware-safe bgrt Plymouth theme until Icarus Ring is exercised
through a real initramfs and encrypted-boot prompt test. This keeps visual
experimentation from risking the boot path.

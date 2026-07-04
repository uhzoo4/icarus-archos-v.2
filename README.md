# Icarus-ArchOS — Assembly Repository

A layered, resumable installer that turns a blank ≥29GB USB drive into a
bootable Arch Linux derivative tuned for an 8GB Intel Iris Xe laptop, with a
Hyprland desktop and native (non-XWayland) Wine application support.

## Directory layout

```
icarus-archos/
├── icarus-assemble.sh              # Master conductor — run this
├── layers/
│   ├── 01-live-partition.sh        # Host: wipe + partition + Btrfs subvolumes
│   ├── 02-base-install.sh          # Host: pacstrap + fstab + stage repo
│   ├── 03a-chroot-core.sh          # Chroot: locale/user/stock kernel/boot — guaranteed bootable
│   ├── 03b-custom-kernel.sh        # Chroot: build linux-icarus (non-fatal on failure)
│   ├── 03c-daemons.sh              # Chroot: NetworkManager, resolved, fstrim
│   ├── 04-graphics.sh              # Chroot: Mesa/VA-API/VDPAU, multilib
│   └── 05-ui-winhybrid.sh          # Chroot: Hyprland/Waybar/Wine stack
├── configs/
│   ├── hypr/hyprland.conf
│   ├── waybar/config.jsonc
│   ├── waybar/style.css
│   └── wine/wine-wayland.sh
└── pkgs/
    └── linux-icarus/PKGBUILD       # YOU must provide this — your kernel config/patches.
                                     # Layer 3b skips gracefully if it's missing.
```

## Usage

Boot the Arch live ISO, get network up, then:

```bash
git clone <your-repo-url> icarus-archos   # or copy it over from another drive
cd icarus-archos
chmod +x icarus-assemble.sh layers/*.sh
./icarus-assemble.sh --target /dev/sdb
```

`--target` has no default on purpose — you must name the exact device.
Double-check with `lsblk` first. This wipes it completely.

Useful flags:

| Flag | Effect | Default |
|---|---|---|
| `--allow-internal` | Permit installing onto a non-removable disk | off |
| `--force-xe` | Force the `xe` GPU driver even if your chip isn't a confirmed xe-default generation | off |
| `--disable-mitigations` | Add `mitigations=off` to the kernel command line | off |
| `--redundant-metadata` | Keep Btrfs's default `dup` metadata profile instead of `single` | off |
| `--resume` | Skip layers whose sentinel already exists | off |

If it dies partway through, fix the reported problem and re-run with
`--resume` — completed layers are skipped.

## What changed from the earlier draft, and why

The versions of this plan that came before this one contained a few things
that would have actively worked against the goals they were trying to
achieve. Fixed here:

1. **Kernel build no longer lives entirely in tmpfs.** On 8GB of RAM, an
   uncapped tmpfs build directory competes directly with the compiler for
   the same memory it's supposed to be protecting — that's the OOM crash
   this whole layer exists to prevent, not a fix for it. `03b-custom-kernel.sh`
   now measures actual `MemAvailable` at build time and only uses a
   **capped** (3GB) tmpfs scratch space if there's genuine headroom to do so;
   otherwise it builds on the Btrfs-compressed disk. A single one-time
   kernel build isn't the sustained write pattern that causes flash wear —
   that concern applies to continuous small writes, not one large job.
   Parallel job count (`MAKEFLAGS`) is also computed from measured RAM
   instead of blindly using `-j$(nproc)`, which can spawn more compiler
   processes than memory can hold.

2. **The `xe` driver is no longer force-loaded by default.** `xe` is only
   the *default* kernel driver on Lunar Lake and Battlemage-generation Intel
   graphics. Most Iris Xe laptops (Tiger Lake / Alder Lake / Raptor Lake)
   still default to `i915`, and there are real reports of both drivers
   binding to the same GPU and hanging when force-loaded together.
   `03a-chroot-core.sh` now detects your GPU generation via `lspci` and only
   prioritizes `xe` if it's a confirmed match, or if you pass `--force-xe`
   explicitly.

3. **Btrfs metadata profile is now explicit.** Btrfs's default `dup`
   metadata profile mirrors metadata even on a single device, which doubles
   metadata writes on the exact flash medium this plan is trying to protect.
   `01-live-partition.sh` now formats with `-m single -d single` by default;
   pass `--redundant-metadata` if you'd rather keep the extra safety margin.

4. **`ANV_QUEUE_THREAD_DISABLE` has been removed.** It doesn't appear in
   Mesa's documented ANV environment variable list and couldn't be
   verified as real. Shipping unverified environment variables system-wide
   is worse than leaving them out.

5. **`mitigations=off` is opt-in, not silent.** It's a real CPU security
   tradeoff (disables Spectre/Meltdown-class mitigations) and now requires
   `--disable-mitigations` explicitly rather than riding along in every
   boot entry by default.

6. **Wine-Wayland hook had broken syntax.** The registry command's quoting
   didn't survive a real shell, and it ran wine on every single login
   instead of once. `configs/wine/wine-wayland.sh` fixes the quoting, checks
   the Wine major version actually supports the native Wayland driver
   (9.0+), and only runs once per prefix via a marker file.

7. **Invented Hyprland syntax removed.** `windowdance` and `forceinput`
   aren't real `windowrulev2` directives. Replaced with real ones
   (`tile`, `rounding`, `opacity`).

8. **`--target` has no default device.** Earlier drafts assumed `/dev/sdX`
   implicitly. It's now a required, explicit argument with no fallback, so
   a typo or a re-plugged drive can't result in wiping the wrong disk.

## Later additions

- `layers/03b-custom-kernel.sh` now installs `bc`, `libelf`, and `pahole`
  before building. Without `pahole` specifically, a kernel built with
  `CONFIG_DEBUG_INFO_BTF=y` can silently end up without BTF data rather than
  failing loudly — worth having even though `base-devel` doesn't pull it in.
- `layers/05-ui-winhybrid.sh` now installs `libxkbcommon` and
  `lib32-libxkbcommon`, which Wine's native Wayland driver needs for
  keyboard input mapping.

## Things you still need to check on your own hardware before running this

- **Your exact Iris Xe generation.** Run `lspci -nn | grep -i vga` on the
  live ISO before installing, and compare against Intel's generation
  naming (Tiger Lake / Alder Lake / Raptor Lake / Lunar Lake / etc.) so you
  know whether `--force-xe` is likely to help or hurt on your chip.
- **Your actual free space margin.** 29GB is the stated minimum; a kernel
  source tree, build artifacts, and a couple of Wine prefixes will use a
  meaningful chunk of that. More headroom is better.
- **`pkgs/linux-icarus/PKGBUILD`** must exist in this repo with your actual
  kernel version/config/patches — that file is yours to provide; Layer 3b
  will skip gracefully (not fail the whole install) if it's absent.

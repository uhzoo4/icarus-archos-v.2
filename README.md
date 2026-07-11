# Icarus-ArchOS — Assembly Repository

A layered, resumable installer that turns a blank ≥29GB USB drive into a
bootable Arch Linux derivative tuned for an 8GB Intel Iris Xe laptop, with a
Hyprland desktop and native (non-XWayland) Wine application support.

## Directory layout

```
icarus-archos/
├── icarus-assemble.sh              # Master conductor — run this
├── ROADMAP.md                      # Read before adding new customization
├── burn-in-checklist.md            # Post-install validation plan — run before trusting this as your only OS
├── layers/
│   ├── MANIFEST                    # Ordered layer list the conductor reads — add a line here for new layers
│   ├── TEMPLATE.sh                 # Copy this to start a new layer
│   ├── 01-live-partition.sh        # Host: wipe + partition + Btrfs subvolumes
│   ├── 02-base-install.sh          # Host: pacstrap + fstab + stage repo
│   ├── 03a-chroot-core.sh          # Chroot: locale/user/stock kernel/boot — guaranteed bootable
│   ├── 03b-custom-kernel.sh        # Chroot: build linux-icarus (non-fatal on failure)
│   ├── 03c-daemons.sh              # Chroot: NetworkManager, resolved, fstrim
│   ├── 04-graphics.sh              # Chroot: Mesa/VA-API/VDPAU, multilib, burn-in tools
│   ├── 05-ui-winhybrid.sh          # Chroot: Hyprland/Waybar/Wine/greetd + lock/idle/notifications/dashboard
│   ├── 06-ai-engineering-perf.sh   # Chroot (soft): iGPU compute stack, sched_ext, memory/thermal tuning, dev tooling
│   ├── 07-native-apps.sh           # Chroot (soft): Chromium/Chrome, paru bootstrap, LibreOffice, Eww deps
│   ├── 08-silent-boot.sh           # Chroot (soft): Plymouth splash + quiet boot, systemd-boot only
│   └── 09-curated-apps.sh          # Chroot (soft): opt-in official-repository app profiles
├── configs/
│   ├── hypr/{hyprland,hyprlock,hypridle}.conf
│   ├── waybar/{config.jsonc,style.css}
│   ├── rofi/{icarus-spotlight,icarus,wallpaper}.rasi
│   ├── dunst/dunstrc
│   ├── kitty/{kitty.conf,open-actions.conf}
│   ├── wlogout/{layout,style.css,icons/}
│   ├── fastfetch/{config.jsonc,logo.txt}
│   ├── cava/config
│   ├── eww/{eww.yuck,eww.scss,dashboard.yuck,scripts/}
│   ├── theme/{colors.conf,colors.css,colors.rasi,colors.sh,colors.scss,gtk.css}  — static defaults; icarus-palette regenerates these
│   ├── wallpaper/{icarus-midnight.png,icarus-midnight-live.mp4,icarus-wallpaper.sh,switcher.sh,references/}
│   └── wine/wine-wayland.sh
└── pkgs/
    └── linux-icarus/PKGBUILD       # mainline 7.2-rc1 via git+tag, see file header
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
| `--app-profiles "LIST"` | Install Layer 9 profiles before first boot, overriding `configs/apps/profiles.conf` | `essentials sharing` |
| `--resume` | Skip layers whose sentinel already exists | off |

If it dies partway through, fix the reported problem and re-run with
`--resume` — completed layers are skipped.

Layers are read from `layers/MANIFEST` in order — the conductor doesn't
hardcode the sequence. Adding future customization means writing a new
`layers/NN-name.sh` (copy `layers/TEMPLATE.sh`) and adding one line to the
manifest, not editing `icarus-assemble.sh`. See `ROADMAP.md` before adding
anything, especially once this starts getting genuinely complex — it has
the actual conventions (idempotency, fatal-vs-soft failure) and a backlog
of where half-formed ideas should go instead of getting wedged into
whichever layer happens to be open at the time.

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
- **`layers/05-ui-winhybrid.sh` now actually gets you to a desktop.**
  Two things were missing before: (1) `hyprland.conf` referenced a Rofi
  theme called `icarus-spotlight` that was never actually written anywhere
  — now shipped at `configs/rofi/icarus-spotlight.rasi` and installed to
  `/usr/share/rofi/themes/`. (2) There was no display manager, so boot would
  have landed at a bare TTY with nothing launching Hyprland. `greetd` +
  `greetd-tuigreet` (both official Arch `extra` packages, no AUR needed) are
  now installed and configured to present a login screen that launches
  Hyprland on successful auth. Pipewire's user services are also explicitly
  enabled globally rather than assumed to auto-enable via packaging presets.

## Merged from a manually-edited copy

Two real fixes came in from a separately edited copy of this repo and are
now merged in:

- `layers/01-live-partition.sh` unmounts anything already mounted on the
  target device before wiping it (`umount -R`), so a re-run or an
  auto-mounted partition fails cleanly at the guard checks instead of
  making `sgdisk`/`mkfs` error out with "device busy". It also removes any
  pre-existing subvolumes before creating new ones — mostly a no-op given
  `mkfs.btrfs -f` already wipes everything just before this runs, but it's
  free insurance if this layer is ever invoked standalone during debugging.
- `layers/02-base-install.sh` now overwrites `/etc/fstab` via `genfstab -U
  /mnt > /mnt/etc/fstab` instead of appending, so re-running Layer 2 can't
  produce duplicate fstab entries.

Two new files also came in, one of which needed real fixes before it was
safe to build with:

- **`burn-in-checklist.md`** — an 18-step post-install validation plan
  (boot reliability, suspend/resume, thermals, Wine Wayland, networking,
  Btrfs health). Good as submitted; `layers/04-graphics.sh` now installs
  the tools it references (`stress-ng`, `lm_sensors`, `power-profiles-daemon`,
  `upower`) since none of them were in the package list before.
- **`pkgs/linux-icarus/PKGBUILD`** went through two rounds:
  1. The first version targeted `7.2-rc1` via a `git.kernel.org/torvalds/t/...`
     tarball URL with a supplied sha256 hash. That URL pattern has no
     precedent anywhere in kernel.org's own docs, the ArchWiki's kernel-build
     pages, or real AUR packages that fetch mainline/RC kernels — so rather
     than ship an unverifiable URL+hash pair, it was corrected.
  2. Final version: still targets `7.2-rc1` (that choice is reasonable —
     Layer 3a's stock-kernel fallback means a bad -rc build here can't take
     down a working system), but fetches it via `git+https://git.kernel.org/
     pub/scm/linux/kernel/git/torvalds/linux.git#tag=v7.2-rc1` — the same
     mechanism real mainline-kernel AUR packages (`linux-mainline`,
     `linux-git`) use — and verifies the tag's PGP signature against
     Torvalds' actual key in `prepare()` instead of relying on a tarball
     hash. `.config` is built via `make defconfig` plus explicit
     `scripts/config` toggles (a deliberate lean-kernel choice, not the
     stock-kernel-config inheritance approach floated earlier) —
     `burn-in-checklist.md` step 10 exists specifically to catch anything
     that approach misses before you rely on it day-to-day.

- **The conductor is now manifest-driven.** `icarus-assemble.sh` used to
  hardcode each layer's invocation and argument list. It now reads
  `layers/MANIFEST` and exports all global flags as `ICARUS_*` environment
  variables that every layer receives automatically — adding a future
  layer means writing a script (from `layers/TEMPLATE.sh`) and adding one
  line to the manifest, not editing the conductor's logic. The loop
  mechanics (env passthrough, soft-failure continuation, `--resume` skip
  behavior) were verified with a standalone dry run before shipping this
  change. See `ROADMAP.md`.

## Later additions

- **Layer 6 — AI & Engineering Performance** (soft, non-fatal). This is
  what "beast for AI/engineering" actually decomposes into on this
  hardware — none of it is custom CPU/iGPU code:
  - `intel-compute-runtime` + `level-zero-loader` expose the Iris Xe to
    real compute frameworks instead of it sitting idle outside display/
    video decode.
  - A Python venv (`~/.venvs/ai`) with OpenVINO and PyTorch's XPU build —
    pip-based since Arch's system Python is externally managed (PEP 668).
  - A documented (not auto-run) recipe at `~/bin/build-llamacpp-openvino.sh`
    for llama.cpp's new OpenVINO backend (Intel shipped this in OpenVINO
    2026.1, June 2026) — too new/fast-moving to bake into an unattended
    script reliably.
  - `scx-scheds` (sched_ext pluggable CPU schedulers, real Arch `extra`
    package) with `scx_bpfland` as default — genuinely useful for mixed
    compile+inference+desktop load. This needed `CONFIG_SCHED_CLASS_EXT`
    added to the kernel PKGBUILD, since generic `defconfig` doesn't
    guarantee it's on.
  - `earlyoom` + `vm.swappiness=150` — the actual 8GB bottleneck is memory
    pressure, not raw CPU/GPU speed, and swappiness is tuned high
    specifically because swap is zram (compressed RAM), not disk.
  - `thermald` — CPU and iGPU share one thermal budget; bad thermal
    handling throttles both under sustained load.
  - `ccache`, `podman`, `qemu-desktop`/`libvirt`, raised inotify watches
    and file-descriptor ulimits, a USB-aware I/O scheduler udev rule.
  - `icarus-perf {compute|desktop|battery}` — one command tying
    power-profiles-daemon and the active scx scheduler together.

- **Layer 7 — Native Apps** (soft, non-fatal). Chrome and "Microsoft
  apps" don't need Wine:
  - Chromium installed immediately from the official repo.
  - `paru` (AUR helper) bootstrapped via `paru-bin` so Chrome and similar
    packages outside the official repos become installable — AUR
    packages are community-maintained, not vetted like `extra`/`core`,
    worth knowing even for well-known ones like these.
  - Google Chrome via AUR once paru exists.
  - LibreOffice as the native Office-compatible suite.
  - Documented but not auto-installed: Office/Teams work as web apps in
    Chrome with no install at all; `teams-for-linux`,
    `microsoft-edge-stable-bin`, and `visual-studio-code-bin` are one
    `paru -S` away if you want them specifically.

- **Layer 9 — Curated applications** (soft, non-fatal). The project uses
  [Awesome Linux Software](https://github.com/luong-komorebi/Awesome-Linux-Software)
  as a discovery source, rather than copying or blindly installing its entire
  catalogue. Layer 9 installs `essentials sharing` **before first boot** by
  default. Change `configs/apps/profiles.conf` before assembly, or pass
  `--app-profiles "development gaming"` to the conductor for a one-off image.
  `icarus-apps list` remains available after boot for additional profiles. The
  tool only installs official Arch packages. Attribution and the source licence are recorded in
  `docs/AWESOME_LINUX_SOFTWARE.md`.

## Theme pass — "Intelligent Darkness"

`configs/hypr/hyprland.conf`, `configs/waybar/style.css`,
`configs/rofi/icarus-spotlight.rasi` were recolored to a fixed palette
(near-black `#050505`–`#16181D`, titanium/steel-blue structure, ice-blue/
amber/soft-red reserved strictly for functional states like battery
warnings — no other color). Border reduced to 1px, blur made subtler,
animation curve changed to a no-overshoot deceleration curve.
`configs/wallpaper/icarus-midnight.png` is original generative art (a
procedurally drawn moon/fog/brutalist-skyline scene, not a photo — no
copyright concern) matching the same palette. `Papirus-Dark` installs from
the official repo in Layer 5; `adw-gtk-theme` and `bibata-cursor-theme`
are AUR-only and install in Layer 7, once `paru` exists — referencing
their names in Layer 5's configs before they're installed is safe since
nothing reads them until first login, after every layer finishes.

## Live wallpaper, glassmorphism, macOS-style transitions

- **`configs/wallpaper/icarus-midnight-live.mp4`** — a 12-second seamless
  loop of the same scene (twinkling stars, a slowly breathing moon glow,
  drifting fog), procedurally generated and ffmpeg-encoded, not sourced
  from anywhere — 96KB, because the content compresses extremely well.
  Played via `mpvpaper` (AUR, installed in Layer 7).
  `configs/wallpaper/icarus-wallpaper.sh` (installed in Layer 5) picks
  mpvpaper if it's actually present and falls back to the static PNG via
  `swaybg` otherwise, so a failed AUR bootstrap degrades to "wrong
  wallpaper" rather than "no wallpaper."
- **Glassmorphism now applies to layer-shell surfaces, not just windows.**
  `decoration:blur` in Hyprland only covers ordinary windows automatically
  — Waybar, Rofi, and dunst's notification popups needed explicit
  `layerrule = blur, <namespace>` entries to actually get frosted glass
  too. Hyprland is mid-migration toward a Lua config format (hyprlang
  deprecated as of 0.55) — this is flagged in the config file itself; if
  a future Hyprland update rejects these lines, that's why.
- **Window open/close now uses `popin` (scale + fade from center)**
  instead of a slide — this is what actually reads as "macOS-like," not
  the color palette. Applied to `windowsIn`/`windowsOut` and
  `layersIn`/`layersOut` (so Rofi and notifications pop in the same way).

## Desktop-completeness merge (lock screen, idle, notifications, dashboard, silent boot)

A large batch of additions came in covering most of the gaps from the
completeness assessment — `hyprlock`/`hypridle` (lock + idle chain),
`dunstrc` (styled notifications), `wlogout` (power menu), `fastfetch` +
`cava` (system info + audio visualizer), an `eww` dashboard, a
wallpaper-driven dynamic accent-color system (`icarus-palette.py`), and a
Plymouth silent-boot layer. Genuinely good additions, and comprehensively
audited before merging — real bugs found and fixed rather than merged
as-is:

- **Layer 8 assumed GRUB.** This system uses `systemd-boot` exclusively
  (`bootctl install` in Layer 3a) — no GRUB package is installed anywhere.
  The original would have run `grub-install --efi-directory=/boot` against
  the same ESP systemd-boot already manages (risking a broken/competing
  bootloader), edited a `/etc/default/grub` that doesn't exist in this
  build, and written kernel parameters to a `grub.cfg` systemd-boot never
  reads — so even ignoring the risk, the actual feature wouldn't have
  worked. Rewritten to insert the `plymouth` hook into the *existing*
  mkinitcpio `HOOKS` array (never replace it wholesale) and patch the real
  systemd-boot entries' kernel command lines directly.
- **`/usr/local/bin/icarus-wallpaper` naming collision.** The live-wallpaper
  startup daemon (mpvpaper/swaybg fallback, from the earlier theme pass)
  and the new interactive wallpaper switcher both installed to the same
  path — whichever ran last in Layer 5 silently overwrote the other. Now
  two names: `icarus-wallpaper` (daemon, `exec-once`) and
  `icarus-wallpaper-switch` (picker, bound to `SUPER+W`).
- **Wrong path + missing directory.** Layer 5 checked for
  `configs/wallpaper/switcher.sh`; the actual file was at
  `configs/switcher.sh` (moved to match). The switcher also requires
  `configs/wallpaper/references/`, which didn't exist anywhere — it would
  have errored on first use. Now ships with the existing wallpaper as its
  first entry.
- **`SUPER SHIFT S` bound to two different actions** (screenshot-to-file
  and move-to-special-workspace) — the second silently killed the first.
  Special workspace moved to `SUPER ALT S`.
- **`SUPER W`** pointed at the startup daemon instead of the switcher —
  fixed to call `icarus-wallpaper-switch`.
- **The same relative-import bug in four files**
  (`../../icarus/theme/...` where only one `../` was correct — the
  importing files live exactly one level below `~/.config/`, not two):
  Layer 5's GTK `gtk.css` heredoc, `waybar/style.css`, `eww/eww.scss`
  (which hadn't even made it into the repo before this pass — added now),
  `wlogout/style.css`.
- **`eww.scss` imports `colors.scss`, never pre-generated as a static
  default** — the dashboard would fail to load until the wallpaper
  switcher was run once manually. Added `colors.scss` and `colors.sh`
  (also missing) as static defaults alongside the four that already
  existed, matching exactly what `icarus-palette.py` generates.
- **`eww daemon` was never started** — the `SUPER Tab` dashboard toggle
  needs it running in the background first. Added to `exec-once`.
- **"Hibernate" in the wlogout menu removed.** This system has zero
  disk-backed swap (ZRAM only) — hibernation writes its image to swap
  then cuts power entirely, which a RAM-backed swap device cannot survive.
  A "Hibernate" button here would silently fail or lose state, not
  gracefully degrade. Proper support (a real swapfile + `resume=` kernel
  parameters on both boot entries) is a real feature, just not a five-line
  fix — added to `ROADMAP.md`'s backlog instead of rushing it into this
  pass.
- **`hyprlock.conf`'s `$USER` in a plain `text =` field** — unlikely to
  shell-expand reliably; wrapped in `cmd[update:0] echo "..."` matching
  the pattern the same file already uses for the clock.
- **No `layerrule = blur, eww-blur`** despite the dashboard's namespace
  being named specifically for it — added alongside the existing
  waybar/rofi/notifications rules.
- **An unused overshoot bezier curve** (`softBounce`, y-value 1.2) sitting
  in `hyprland.conf`, contradicting the no-bounce design rule and never
  actually applied anywhere — removed.
- **`icarus-palette.py`'s cava updater** collapsed a 4-stop gradient into
  2 duplicated colors on every wallpaper change. Fixed to interpolate 4
  distinct shades along the same hue — tested end-to-end with a synthetic
  image before merging, not just read.

Everything else — the keybind set, window rules, dwindle/misc tuning,
dunst/kitty/wlogout/fastfetch/cava static styling, the dynamic
accent-color system's overall design — was correct as submitted and
merged as-is.

## Things you still need to check on your own hardware before running this

- **Your exact Iris Xe generation.** Run `lspci -nn | grep -i vga` on the
  live ISO before installing, and compare against Intel's generation
  naming (Tiger Lake / Alder Lake / Raptor Lake / Lunar Lake / etc.) so you
  know whether `--force-xe` is likely to help or hurt on your chip.
- **Your actual free space margin.** 29GB is the stated minimum; a kernel
  source tree, build artifacts, and a couple of Wine prefixes will use a
  meaningful chunk of that. More headroom is better.
- **`pkgs/linux-icarus/PKGBUILD`'s PGP verification.** `prepare()` tries to
  fetch Torvalds' key from a keyserver and verify the `v7.2-rc1` tag —
  that needs real network access from inside the chroot to actually
  succeed. If the keyserver is unreachable during the build, you'll get a
  warning rather than a hard failure; run `git tag -v v7.2-rc1` yourself
  inside the extracted source once you have network access, and don't
  fully trust the build until that comes back clean.
- **A pre-release kernel needs the burn-in checklist more than a stable
  one would.** `7.2-rc1` is a moving, unreleased target — run every step
  of `burn-in-checklist.md` against it specifically, not just the stock
  kernel, before you'd consider deleting Windows based on it working.
- **Layer 7's AUR bootstrap needs live network access to actually work**
  — if `paru` fails to build, Chromium and LibreOffice from earlier in
  the same layer are unaffected, but Chrome/Teams/Edge/VS Code won't be
  until you fix and re-run it (or install `paru` manually afterward).
- **Specific engineering/CAD software isn't covered here** — Wine
  compatibility varies enormously app-to-app (MATLAB has a native Linux
  build; SolidWorks essentially doesn't work under Wine at all and needs
  a Windows VM if you need it). If there's specific software beyond
  browsers/Office/dev tooling this needs to run, that's worth mapping
  per-app before assuming Wine will handle it.
- **The live wallpaper costs more battery than a static one** — mpvpaper
  decodes video continuously. If that matters more than the motion on
  battery, either drop the `exec-once` line for it in `hyprland.conf`
  (falls back to the static PNG automatically) or look at wiring up
  `mpvpaper-stop` (AUR, not installed by default) to pause on idle/lock.
- **Icarus scene gallery.** `SUPER W` opens the gallery; it understands
  static wallpapers and live `.gif`/video entries. When `mpvpaper` is
  present, choosing a live entry plays it and derives the UI palette from its
  paired static image; otherwise it automatically falls back to that still.
  `SUPER SHIFT W` randomly selects an original Icarus scene. The choice
  persists across login sessions.
- External theme packs were evaluated as visual research rather than copied
  wholesale. See `docs/THEME_RESEARCH.md` for the compatibility and licence
  decisions behind that boundary.
- **The `layerrule` blur syntax is on the older side of an active Hyprland
  config migration** (see the theme-pass note above) — if Waybar/Rofi/
  notifications stop looking blurred after a Hyprland update, that's the
  first thing to check against the current wiki, not a sign something
  else broke.
- **Test the lock screen before you rely on it.** `SUPER L` and lid-close
  (via `hypridle`) should both trigger `hyprlock` — confirm the password
  prompt actually accepts your login password before treating this as a
  working security boundary.
- **First boot won't have a custom accent color yet** — the static
  defaults (steel blue) apply until you run the wallpaper switcher
  (`SUPER W`) at least once. That's expected, not a bug.
- **Proper hibernate support isn't implemented** — see the merge note
  above. `Suspend` (RAM-only, no swap needed) works; `Hibernate` was
  removed rather than shipped broken.

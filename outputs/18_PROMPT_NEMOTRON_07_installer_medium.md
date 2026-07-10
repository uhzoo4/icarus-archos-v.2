# Task: Port the existing icarus-archos installer to the arkdep model (not a blank-slate design)

**Model:** Nemotron 3 Ultra
**Stage in pipeline:** Replaces the old version of this file. The old
version assumed no installer material existed and asked Nemotron to design
one from scratch using only EndeavourOS as a reference. That assumption
was wrong — a real, working, stateful installer (`icarus-assemble.sh` +
`layers/01`–`08` + `MANIFEST`) already exists for this exact project. This
prompt asks Nemotron to port it, not replace it blind.

**Why Nemotron:** deciding what changes and what doesn't, across 10
sequential scripts plus a conductor, while keeping the finished
architecture (arkdep, mkosi, single Btrfs root, systemd-boot counting)
consistent, is a wide-context reconciliation job — the same category of
task as files 03/15's arkdep reconciliation.

## Ground truth: the real, existing installer (verbatim from the project)

```
Project: Icarus-ArchOS
Current Architecture: Stateful, script-driven, layer-by-layer automated
Arch Linux installation directly onto a Btrfs root.

Conductor: A master script (icarus-assemble.sh) reads a MANIFEST file and
executes bash scripts sequentially. It supports resuming from failures
using sentinel files (layer-X.done).

The Layers (executed in order):

1. 01-live-partition.sh (Host Context): Wipes the target disk, creates an
   EFI partition and a Btrfs partition. Formats Btrfs, creates subvolumes
   (@, @home, @cache, @log), and mounts them to /mnt.
2. 02-base-install.sh (Host Context): Optimizes pacman.conf (parallel
   downloads), syncs keys, runs pacstrap to install the base system (base,
   linux-firmware, btrfs-progs, networkmanager, etc.) to /mnt, generates
   fstab, and copies this repository into the new root.
3. 03a-chroot-core.sh (Chroot Context): Configures timezone, locale,
   hostname, sets up systemd-boot, enables NetworkManager, and installs the
   stock Arch kernel (linux) as a guaranteed bootable fallback.
4. 03b-custom-kernel.sh (Chroot Context): Compiles a hyper-optimized custom
   kernel (linux-icarus) from source using makepkg with march=native and
   CachyOS patches. Installs the compiled package and adds it as the
   primary boot entry.
5. 03c-daemons.sh (Chroot Context): Installs and enables system-level
   services: bluetooth, cups, fstrim, btrfs-scrub, and Audio/Pipewire
   services.
6. 04-graphics.sh (Chroot Context): Installs GPU drivers (specifically
   targeting Intel Iris Xe with mesa, vulkan-intel), sets kernel module
   parameters, and configures hardware video acceleration.
7. 05-ui-winhybrid.sh (Chroot Context): Installs the graphical desktop
   environment: Hyprland (Wayland), Waybar, Rofi, Kitty, and custom dynamic
   Python-based theming scripts that extract colors from wallpapers. Sets
   up the primary unprivileged user (icarus).
8. 06-ai-engineering-perf.sh (Chroot Context): Installs performance and AI
   engineering tools: intel-gpu-tools, nvtop, Docker, and mimalloc (with an
   ai-run wrapper for overriding memory allocators during heavy Python
   inference).
9. 07-native-apps.sh (Chroot Context): Installs userland applications
   (Firefox, VS Code), sets up a modern Rust-based terminal UX (starship,
   eza, bat, zoxide), and creates an interactive first-boot onboarding
   script (icarus-welcome) using gum.
10. 08-silent-boot.sh (Chroot Context): Configures plymouth, hides kernel
    boot messages, and sets up SDDM for a completely silent, branded boot
    experience into the desktop.
```

## My own preliminary read on this (give to Nemotron as a starting
hypothesis to confirm, correct, or overrule — not as settled fact)

| Layer | Preliminary take |
|---|---|
| `02-base-install.sh` | Disappears from the target machine entirely — this becomes "what mkosi does in CI," not an install-day step |
| `03a`, `03c`, `04`, `05-ui-winhybrid.sh`, `06-ai-engineering-perf.sh`, `07-native-apps.sh`, `08-silent-boot.sh` | Port over almost mechanically — each is "install packages + drop config files," which maps to mkosi's `Packages=` list and `mkosi.extra/` tree |
| `01-live-partition.sh` | Needs rework (subvolume layout changes to arkdep's model) but its disk-wipe/partition logic is the real starting skeleton for the still-undesigned installer |
| `03b-custom-kernel.sh` | The one genuine problem — `march=native`, compiled **on the target machine**, is fundamentally incompatible with "build once, deploy the same image everywhere." Since this is a single personal machine (stated from the start of this project), the fix isn't dropping the optimization — it's moving *when* it compiles: from "during install, on the disk being wiped" to "a build step on the dev machine that produces a `linux-icarus` package mkosi folds in like any other package." |
| `icarus-assemble.sh` conductor (MANIFEST + sentinel resume files) | No reason to discard a working pattern — likely still useful for the **installer** (writing the image, initializing arkdep, first boot), just needs to stop assuming it's building the OS live |

## Also still relevant (secondary reference — real archiso ground truth)

```
--- EndeavourOS's real profiledef.sh (confirmed against actual source) ---
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
airootfs_image_type="squashfs"

--- airootfs/root/.automated_script.sh — unattended-install convention ---
Reads a script=<url-or-path> kernel cmdline parameter for headless installs.

--- airootfs/etc/pacman.conf — real repo signature convention ---
SigLevel = PackageRequired
```

## Paste before sending: `RUNNING_CONTEXT.md`'s four sections — Partition
layout & deployment model, Rollback mechanism, Secure Boot, Recovery
environment (the already-finished architecture this installer must target)

## System / Role Prompt

```
You are a principal Linux systems architect. You are being given a real,
existing, working installer for a specific project (a stateful,
script-driven conductor with 10 sequential layers) and asked to port it to
an already-finalized immutable arkdep-based architecture — not design a
new installer from nothing. Preserve everything from the existing design
that still works; change only what the architecture mismatch actually
requires. Do not discard the conductor/sentinel-resume pattern, the
specific package choices, or the branding/theming work unless there's a
concrete technical reason tied to immutability, not just "this is how
other projects do it." Where you disagree with the preliminary layer-by-
layer read provided, say so explicitly and explain why.
```

## Task Prompt

```
Port the existing Icarus-ArchOS installer (verbatim architecture and my
own preliminary layer-by-layer read, both above) to the arkdep-based
immutable architecture (pasted above from RUNNING_CONTEXT.md). Specifically:

1. Confirm, correct, or overrule my preliminary read of which layers port
   mechanically into mkosi's Packages=/mkosi.extra vs. which need real
   rework. For each of the 10 layers, state explicitly: unchanged,
   moved-to-build-time, or rework-required, and why.

2. Redesign 01-live-partition.sh for the arkdep model: replace the
   @/@home/@cache/@log subvolume scheme with arkdep's deployments/ +
   shared/{home,root,flatpak} structure (from RUNNING_CONTEXT.md), while
   keeping whatever of the original disk-wipe/EFI-partition-creation logic
   still applies.

3. Solve the 03b-custom-kernel.sh problem concretely: design how a
   march=native, CachyOS-patched linux-icarus kernel gets built as a
   reproducible package on a dev machine (not the target being wiped) and
   folded into the mkosi image, while preserving the original design's
   intent (guaranteed-bootable stock kernel as fallback, custom kernel as
   primary boot entry) — reconcile "guaranteed bootable fallback" with the
   already-decided systemd-boot automatic-rollback mechanism from
   RUNNING_CONTEXT.md, since these may now be solving the same problem
   two different ways.

4. Decide whether icarus-assemble.sh's conductor pattern (MANIFEST +
   sentinel .done files for resumable execution) should be kept for the
   NEW installer (writing the pre-built image + initializing arkdep +
   first-boot setup), given it's a proven, working pattern for this
   specific project.

5. Decide installer type (minimal custom script vs. archiso+Calamares,
   using the EndeavourOS excerpts as one data point) now that a working
   custom conductor already exists for this project — does that change
   the calculus toward "extend what's already built" over "adopt a
   different project's tooling"?

6. State what should be dropped entirely and why (if anything).

Structure output as: a corrected layer-by-layer table, then the redesigned
01-live-partition.sh logic, then the kernel-build solution, then the
conductor/installer-type decision, then the new directory structure this
adds to the project.
```

## What good output looks like

Output that treats the existing 10-layer design as the primary input, not
as background color for a fresh design — if it re-derives an installer
from EndeavourOS patterns without engaging point-by-point with the actual
`layers/` content above, that's the wrong output. It should also give a
concrete, buildable answer to the kernel problem, not just "consider
building it elsewhere."

## Validation before you trust it

- The kernel-build solution is the one part worth testing before trusting:
  build `linux-icarus` off-target once, boot it in a VM, confirm it
  actually works before assuming the "move compilation off-target" fix is
  sound for this specific `march=native` + CachyOS-patch combination.
- If it recommends real changes to `05-ui-winhybrid.sh`'s theming scripts
  or `07-native-apps.sh`'s onboarding script beyond "these move into
  mkosi.extra unchanged," check specifically why — most of that layer's
  content shouldn't need to change at all.

## Common failure modes for this task

- Watch for it quietly re-litigating settled decisions (partition count,
  Secure Boot model) instead of treating RUNNING_CONTEXT.md as fixed and
  only working out how this installer targets it.
- Watch for it flattening the kernel fallback problem — "stock kernel as
  bootable fallback" (the original design's answer) and "systemd-boot
  automatic rollback to an older deployment" (the already-decided answer)
  are two different mechanisms solving overlapping problems; it should
  explicitly reconcile them, not silently pick one without saying so.

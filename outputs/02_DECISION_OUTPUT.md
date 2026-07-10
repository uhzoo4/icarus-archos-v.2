# Autonomous Arch OS — mkosi Image Architecture

**Status**: Draft for review — all `{{PLACEHOLDERS}}` must be resolved before implementation.  
**Assumptions**: x86_64, systemd-boot, UKI, Btrfs root, GitHub Actions runners (Ubuntu 24.04, 4 vCPU, 16 GB RAM, KVM enabled).

---

## 1. Top-Level `mkosi.conf` Structure

### 1.1 Minimal Working Skeleton

```ini
# image/mkosi.conf
# SPDX-License-Identifier: MIT

[Distribution]
Distribution=arch
Release=rolling

[Output]
Format=uki
OutputDirectory=mkosi.output
# UKI filename template — systemd-boot expects /efi/EFI/Linux/arch-<version>.efi
ImageName=arch-{{IMAGE_VERSION}}

[Build]
# Cache pacman packages between builds (speeds up GitHub Actions ~3×)
CacheDirectory=mkosi.cache
# Incremental rebuilds — only re-run stages that changed
Incremental=yes
# BuildSources=.  # enable if you want mkosi to copy this repo into the build chroot
ToolsTree=yes
# Use the host's pacman keyring for verification
PackageKeyring=/etc/pacman.d/gnupg

[Content]
# ── Packages ──────────────────────────────────────────────────────
# Base + boot + crypto + filesystem + your custom meta-packages
Packages=
    base
    base-devel
    linux
    linux-firmware
    mkinitcpio
    systemd-ukify
    sbctl
    btrfs-progs
    cryptsetup
    networkmanager
    pipewire
    wireplumber
    flatpak
    {{DESKTOP_META_PACKAGE}}          # e.g. plasma-meta, gnome, hyprland-git
    {{CUSTOM_DESKTOP_META_PACKAGE}}   # your repository/packages/custom-desktop-meta
    {{SYSTEM_HOOKS_PACKAGE}}          # your repository/packages/system-hooks

# ── Read-only /usr enforcement ───────────────────────────────────
# mkosi 22+ supports this natively; it sets the ro mount flag on /usr
ReadOnly=yes

# ── Kernel command line baked into the UKI ───────────────────────
KernelCommandLine=
    root=LABEL=arch_root
    rootflags=subvol=@
    rw
    quiet
    loglevel=3
    systemd.show_status=auto
    rd.udev.log_level=3
    # Secure Boot: enforcing=0 keeps SELinux permissive if pulled in
    enforcing=0
    # Your custom params (resume, nvidia-drm.modeset=1, etc.)
    {{EXTRA_KERNEL_PARAMS}}

# ── Initrd profile — mkosi builds a minimal UKI initrd ───────────
InitrdProfiles=default

# ── Files to remove from the final image (saves ~200 MB) ─────────
RemoveFiles=
    /usr/lib/modules/*/kernel/drivers/gpu/drm/nouveau
    /usr/lib/modules/*/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko
    /usr/lib/firmware/amdgpu/*
    /usr/share/doc
    /usr/share/man
    /usr/share/locale/*
    !/usr/share/locale/en*
    /usr/share/i18n/locales/*
    !/usr/share/i18n/locales/en_US
    /var/cache/pacman/pkg/*

# ── sysext directories (populated at build time, see §2) ─────────
# These become /usr/lib/extension-release.d/ and /usr/lib/extension.d/
# mkosi copies image/mkosi.extra/ into the image root before sealing
# so we declare them here for clarity:
# (no extra config needed — mkosi.extra/ is automatic)

[Bootloader]
# systemd-boot + UKI — no grub, no separate initrd files
Bootloader=systemd-boot
# mkosi 22+ auto-generates loader.conf and entries/arch-<version>.conf
# from the UKI it produces.  If you need custom entry options, use:
# BootloaderEntry=image/mkosi.extra/etc/kernel/cmdline

[Runtime]
# QEMU test boot (scripts/test_boot.sh)
RAM=4G
CPU=2
# Forward host KVM — required for nested virtualization in CI
KVM=yes
```

### 1.2 Version Injection (CI Responsibility)

`{{IMAGE_VERSION}}` is **not** a mkosi variable. Your `nightly-build.yml` must:

```yaml
- name: Compute image version
  id: version
  run: |
    DATE=$(date -u +%Y%m%d)
    COMMIT=$(git rev-parse --short HEAD)
    echo "version=${DATE}-${COMMIT}" >> $GITHUB_OUTPUT

- name: Build image
  run: |
    sed "s/{{IMAGE_VERSION}}/${{ steps.version.outputs.version }}/g" image/mkosi.conf > mkosi.conf.tmp
    mkosi -f mkosi.conf.tmp
```

### 1.3 Flags You Must Validate on Real Hardware

| Flag | Why It May Need Change |
|------|------------------------|
| `root=LABEL=arch_root` | Your `partitions/layout.sfdisk` must label the root partition `arch_root` |
| `rootflags=subvol=@` | Assumes Btrfs subvolume `@` for rootfs; adjust if you use `@root` or flat layout |
| `{{EXTRA_KERNEL_PARAMS}}` | `nvidia-drm.modeset=1`, `amdgpu.ppfeaturemask=0xffffffff`, `initrd=amd-ucode.img initrd=intel-ucode.img` (microcode handled by systemd-boot, not UKI) |
| `InitrdProfiles=default` | If you need LVM/RAID in initrd, add `lvm` or `mdadm` profile |

---

## 2. Read-Only `/usr` + Branding/Config Defaults

### 2.1 Decision: **Use `mkosi.extra/` for static defaults, `systemd-sysext` for layered overrides**

| Mechanism | What It Does | When to Use |
|-----------|--------------|-------------|
| `mkosi.extra/` | Files copied **into the image** at build time. Become part of the read-only `/usr`. | **Static, version-pinned defaults** — theme files, `skel/` dotfiles, `pacman.conf`, `mkinitcpio.conf`, `systemd` unit drop-ins that never change between builds. |
| `systemd-sysext` (`.raw` images in `/usr/lib/extension.d/`) | Mounted **at boot** via `systemd-sysext.service` as overlay on `/usr`. Can be added/removed without rebuilding the base image. | **Optional/conditional layers** — NVIDIA userspace, Steam Deck hardware enablement, third-party kernel modules, per-machine overrides. |

**Why not sysext for everything?**  
sysext images are loop-mounted at boot, adding ~200–500 ms latency and a moving part (verity signature verification). Your branding/theme files are **always present** and **never optional** — baking them into the UKI via `mkosi.extra/` is simpler, faster, and tamper-evident (the UKI is signed).

### 2.2 Concrete Layout

```
image/
├── mkosi.conf
├── mkosi.extra/
│   ├── etc/
│   │   ├── pacman.conf              # your repos + SigLevel
│   │   ├── mkinitcpio.conf          # HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)
│   │   ├── default/
│   │   │   └── useradd              # SKEL=/etc/skel
│   │   ├── skel/
│   │   │   ├── .config/
│   │   │   │   ├── plasma-workspace/   # KDE example
│   │   │   │   │   └── kdeglobals      # theme, colors, fonts
│   │   │   │   └── gtk-3.0/
│   │   │   │       └── settings.ini    # GTK theme fallback
│   │   │   ├── .bashrc
│   │   │   └── .profile
│   │   ├── systemd/
│   │   │   ├── system/
│   │   │   │   ├── systemd-sysext.service.d/
│   │   │   │   │   └── 10-enable.conf  # [Service] Environment=SYSEXT_MASK= (enable all)
│   │   │   │   └── flatpak-system-helper.service.d/
│   │   │   │       └── 10-enable.conf
│   │   │   └── user/
│   │   │       └── pipewire-session-manager.service.d/
│   │   │           └── 10-wireplumber.conf
│   │   └── flatpak/
│   │       └── remotes.d/
│   │           └── flathub.conf      # [remote "flathub"] url=https://flathub.org/repo/flathub.flatpakrepo
│   └── usr/
│       ├── share/
│       │   ├── backgrounds/          # your wallpapers
│       │   ├── plasma/look-and-feel/ # KDE global theme
│       │   └── glib-2.0/schemas/
│       │       └── 99-custom.gschema.override  # compiled at build via glib-compile-schemas
│       └── lib/
│           └── extension-release.d/
│               └── custom.conf       # ID=arch-custom VERSION={{IMAGE_VERSION}}
```

### 2.3 Build-Time Schema Compilation

Add a `mkosi.postinst` script (runs inside the build chroot **after** package install, **before** image sealing):

```bash
#!/usr/bin/env bash
# image/mkosi.postinst
set -euo pipefail

# Compile GSettings schemas so they work on read-only /usr
if [[ -d /usr/share/glib-2.0/schemas ]]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas
fi

# Regenerate initrd with your mkinitcpio.conf (mkosi does this automatically
# for UKI, but explicit is safer if you tweak HOOKS)
mkinitcpio -P

# sbctl sign the UKI (requires MOK.key enrolled in firmware)
# This runs in the chroot — copy keys in via mkosi.extra/etc/sbctl/keys/
if command -v sbctl >/dev/null && [[ -f /etc/sbctl/keys/db.key ]]; then
    sbctl sign -s /efi/EFI/Linux/arch-*.efi
fi
```

> **Note**: `mkosi.postinst` must be executable (`chmod +x`). mkosi runs it automatically if present next to `mkosi.conf`.

---

## 3. `/var` and `/home` Layout — Surviving Image Swaps

### 3.1 Design Principle: **Separate mutable state from config drift**

| Path | Backing Store | Survives `mkosi` Image Swap? | Config-Drift Protection |
|------|---------------|------------------------------|-------------------------|
| `/home` | Btrfs subvolume `@home` (separate from root) | **Yes** — never touched by image deploy | User files only; no system config |
| `/var` | Btrfs subvolume `@var` (separate from root) | **Yes** — persists across deploys | **Problem**: `/etc` is read-only in image, but `/var/lib/flatpak`, `/var/lib/NetworkManager`, etc. accumulate state |
| `/etc` | **OverlayFS** (lower=image `/etc`, upper=`/var/overlay/etc`) | **Yes** — upper dir in `@var` | **Solution**: `systemd-sysext` + `systemd-tmpfiles` + `arkdep`-style `migrate_files` |

### 3.2 Recommended Partition Layout (`partitions/layout.sfdisk`)

```sfdisk
label: gpt
unit: sectors

# 1. ESP — 1 GiB (UKI + microcode + loader entries)
/dev/disk/by-partlabel/esp : start=2048, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"

# 2. Boot (optional, if you keep kernels outside ESP) — 2 GiB
# /dev/disk/by-partlabel/boot : size=4194304, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="boot"

# 3. Root (A/B) — 50 GiB each (adjust for {{TARGET_DISK_SIZE}})
/dev/disk/by-partlabel/root_a : size=104857600, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root_a"
/dev/disk/by-partlabel/root_b : size=104857600, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root_b"

# 4. Var — remaining space (shared by A/B)
/dev/disk/by-partlabel/var : type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="var"

# 5. Home — optional separate partition, or subvolume under var
# /dev/disk/by-partlabel/home : type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="home"
```

### 3.3 Btrfs Subvolume Map (Created by `scripts/build_image.sh` → `mkosi.postinst` → first boot)

```
@                    ← rootfs (read-only, swapped A/B)
@var                 ← /var (persistent)
  ├─ overlay/
  │   └─ etc/        ← OverlayFS upper/work for /etc
  ├─ lib/
  │   ├─ flatpak/    ← system Flatpak installations
  │   ├─ NetworkManager/
  │   ├─ libvirt/
  │   └─ ...
  ├─ log/
  ├─ cache/
  └─ tmp/
@home                ← /home (persistent, user data only)
@snapshots           ← optional: timeshift/btrfs snapshots
```

### 3.4 OverlayFS for `/etc` (First-Boot Setup)

**`image/mkosi.extra/etc/fstab.overlay`** (copied to `/etc/fstab.d/overlay.conf`):

```fstab
# /etc overlay — lower=read-only image /etc, upper=/var/overlay/etc
/var/overlay/etc /etc overlay defaults,lowerdir=/etc,upperdir=/var/overlay/etc/upper,workdir=/var/overlay/etc/work 0 0 0 0
```

**`image/mkosi.extra/etc/tmpfiles.d/overlay-etc.conf`** (creates dirs at boot):

```tmpfiles
d /var/overlay/etc/upper 0755 root root -
d /var/overlay/etc/work0 0755 root root -
```

**`image/mkosi.extra/usr/lib/systemd/system/etc-overlay.mount`**:

```ini
[Unit]
Description=OverlayFS for /etc
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target sysinit.target
After=var.mount

[Mount]
What=/var/overlay/etc
Where=/etc
Type=overlay
Options=lowerdir=/etc,upperdir=/var/overlay/etc/upper,workdir=/var/overlay/etc/work0

[Install]
WantedBy=local-fs.target
```

Enable via `mkosi.extra/etc/systemd/system/local-fs.target.wants/etc-overlay.mount` (symlink).

### 3.5 Config-Drift Mitigation: `migrate_files` Pattern (from Arkane)

Your `repository/packages/system-hooks/PKGBUILD` installs a hook that runs on **every boot** (via `systemd-sysupdate` or a oneshot service):

```bash
# /usr/lib/systemd/system/migrate-config.service
[Unit]
Description=Migrate user-modified configs from old deployment
After=local-fs.target
Before=sysinit.target
ConditionPathExists=/var/overlay/etc/upper

[Service]
Type=oneshot
ExecStart=/usr/lib/systemd/scripts/migrate-config.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
```

```bash
#!/usr/bin/env bash
# /usr/lib/systemd/scripts/migrate-config.sh
set -euo pipefail

# List of files that MUST be preserved across image swaps
MIGRATE_FILES=(
    'etc/NetworkManager/system-connections'
    'etc/ssh'
    'etc/fstab'
    'etc/crypttab'
    'etc/luks-keys'
    'etc/passwd'
    'etc/shadow'
    'etc/group'
    'etc/subuid'
    'etc/subgid'
    'etc/locale.conf'
    'etc/locale.gen'
    'etc/hostname'
    'etc/machine-id'
    'var/lib/AccountsService'
    'var/lib/bluetooth'
    'var/lib/power-profiles-daemon'
)

# Source = previous deployment's /etc (read-only, mounted at /run/previous-root/etc)
# Dest   = current overlay upper dir
SRC="/run/previous-root/etc"
DST="/var/overlay/etc/upper"

for f in "${MIGRATE_FILES[@]}"; do
    if [[ -e "$SRC/$f" ]] && [[ ! -e "$DST/$f" ]]; then
        mkdir -p "$(dirname "$DST/$f")"
        cp -a "$SRC/$f" "$DST/$f"
        echo "Migrated $f from previous deployment"
    fi
done
```

> **How `/run/previous-root` exists**: Your `ab-switch.sh` (or `systemd-sysupdate`) bind-mounts the **old** rootfs at `/run/previous-root` before kexec/reboot. This is the same pattern Arkane uses.

---

## 4. Flatpak / Flathub Integration

### 4.1 Principle: **Flatpak apps live entirely outside the immutable image**

| Component | Location | Managed By |
|-----------|----------|------------|
| `flatpak` CLI + `flatpak-system-helper` | Inside image (`/usr/bin/flatpak`) | `mkosi` (package `flatpak`) |
| Flathub remote config | Inside image (`/etc/flatpak/remotes.d/flathub.conf`) | `mkosi.extra/` |
| **System-wide app installations** | `/var/lib/flatpak` (on `@var` subvolume) | User via `flatpak install` |
| **Per-user app installations** | `~/.local/share/flatpak` (on `@home`) | User via `flatpak install --user` |
| **Runtime dependencies** | Same as apps — pulled from Flathub at install time | Flatpak |

**No Flatpak apps or runtimes are baked into the UKI.** This keeps the image small (~2–3 GB) and lets users update apps independently of OS updates.

### 4.2 mkosi Config for Flatpak

**`image/mkosi.extra/etc/flatpak/remotes.d/flathub.conf`**:

```ini
[remote "flathub"]
url=https://flathub.org/repo/flathub.flatpakrepo
title=Flathub
filter=runtime/org.freedesktop.Platform*,runtime/org.kde.Platform*,runtime/org.gnome.Platform*
# Optional: pin to a specific commit for reproducibility
# commit=abcdef123456
```

**`image/mkosi.extra/etc/flatpak/installations.d/system.conf`** (optional, for custom install path):

```ini
[Installation "system"]
Path=/var/lib/flatpak
DisplayName=System-wide
StorageType=harddisk
```

**`image/mkosi.extra/usr/lib/tmpfiles.d/flatpak.conf`** (ensure dirs exist):

```tmpfiles
d /var/lib/flatpak 0755 root root -
d /var/lib/flatpak/repo 0755 root root -
d /var/lib/flatpak/app 0755 root root -
d /var/lib/flatpak/runtime 0755 root root -
```

### 4.3 Preinstalling *Specific* Flatpaks (Optional)

If you want **certain apps preinstalled for every user** (e.g., `org.mozilla.firefox`, `com.valvesoftware.Steam`), do it at **first boot**, not build time:

```bash
# /usr/lib/systemd/scripts/flatpak-preinstall.sh
#!/usr/bin/env bash
set -euo pipefail

PREINSTALL=(
    org.mozilla.firefox
    com.valvesoftware.Steam
    org.libreoffice.LibreOffice
    com.discordapp.Discord
)

for app in "${PREINSTALL[@]}"; do
    if ! flatpak info --system "$app" >/dev/null 2>&1; then
        flatpak install --system --noninteractive --assumeyes flathub "$app"
    fi
done
```

Trigger via a `systemd` oneshot with `ConditionFirstBoot=yes` (systemd 256+).

### 4.4 Your `repository/flatpak-manifest.txt`

Keep this as a **human-readable list** for documentation/CI validation:

```
# repository/flatpak-manifest.txt
# Apps preinstalled by default (see flatpak-preinstall.sh)
org.mozilla.firefox
com.valvesoftware.Steam
org.libreoffice.LibreOffice
com.discordapp.Discord
# Runtimes pulled automatically as dependencies
```

**Do not** try to bake Flatpak data into the UKI — it breaks deduplication, bloats the image, and defeats the purpose of Flatpak's delta updates.

---

## 5. Gap Analysis: SteamOS vs. Fedora Silverblue vs. This Project

| Capability | SteamOS (Valve) | Fedora Silverblue (Red Hat) | This Project (Solo, GitHub Actions) | Verdict |
|------------|-----------------|----------------------------|-------------------------------------|---------|
| **Image format** | Custom `steamos-installer` + `partclone` images | OSTree commits (rpm-ostree) | **mkosi UKI + btrfs send/receive** | ✅ Copy concept: atomic image swap. Use mkosi — it's maintained by systemd, no custom tooling. |
| **Bootloader** | systemd-boot + UKI (since 3.5) | systemd-boot + UKI (since F39) | **systemd-boot + UKI** | ✅ Same. mkosi generates loader entries automatically. |
| **Root FS** | Read-only ext4 (A/B) + OverlayFS for `/etc` | Read-only `/usr` (OSTree) + `/var` + `/etc` overlay | **Read-only Btrfs `/usr` (UKI) + Btrfs `@var` + OverlayFS `/etc`** | ✅ Btrfs gives free snapshots + send/receive for A/B. |
| **A/B Updates** | `steamos-update` (custom, signed payloads) | `rpm-ostree` (OSTree deltas, GPG) | **Custom: `arkdep`-style deploy + `sbctl` signed UKI** | ⚠️ You **must** implement: signed UKI, rollback, healthcheck. Arkane's `arkdep` is the closest reference — adapt its `deploy`/`remove`/`healthcheck` logic. |
| **Delta Updates** | Full image (Valve CDN) | OSTree deltas (small, ~50 MB) | **Full UKI (~300 MB compressed)** | ❌ No delta infrastructure. Mitigate: zstd -19, GitHub Actions cache, `Incremental=yes` in mkosi. Accept 5–10 min download on user end. |
| **Package Layering** | `pacman` + `steamos-readonly` (limited) | `rpm-ostree install` (layers on top of OSTree) | **`systemd-sysext` + `pacman` in chroot at build time** | ⚠️ No runtime layering (by design — immutable). Users use Flatpak/Distrobox. If you need kernel modules (NVIDIA), build separate sysext images. |
| **User Config Migration** | `steamos-migrate-config` (proprietary) | `rpm-ostree` handles `/etc` via `ostree admin upgrade` | **Custom `migrate-config.sh` + OverlayFS upper dir** | ✅ Arkane's `migrate_files` list is battle-tested. Copy the pattern. |
| **Secure Boot** | Microsoft-signed shim + MOK enrollment | Microsoft-signed shim + `mokutil` | **`sbctl` + self-signed keys enrolled via MOK** | ✅ `sbctl` is Arch-native, works in mkosi.postinst. Document MOK enrollment for users. |
| **Telemetry/Crash Reporting** | Valve internal (opt-out) | Fedora Retrace (opt-in) | **Custom: `telemetry/server/receive.py` + `client-hook/on-crash-report.sh`** | ✅ You own the infra. Keep it opt-in, minimal (coredump + journal snippet + hardware ID hash). |
| **Recovery Environment** | SteamOS recovery partition (custom) | `ostree admin pin 0` + GRUB fallback | **Dedicated `recovery/` partition + `reflashing.sh`** | ✅ Build a minimal UKI (busybox + btrfs + cryptsetup + network) as `recovery-rootfs/`. |
| **CI/CD** | Valve internal Jenkins + hardware lab | Fedora Copr + Koschei + OpenQA | **GitHub Actions (Ubuntu runners, KVM)** | ⚠️ No hardware lab. `test_boot.sh` = QEMU headless + screenshot diff. Accept false negatives; manual hardware test before `promote_to_stable.sh`. |
| **Budget** | Unlimited | Red Hat sponsored | **GitHub Actions free tier (2000 min/mo) + self-hosted runner optional** | ⚠️ Nightly build ~15 min. 30 builds = 450 min. Leave headroom. Cache `mkosi.cache/` and pacman pkg cache aggressively. |

### 5.1 What to Copy Conceptually

1. **UKI + systemd-boot** — both SteamOS 3.5+ and Silverblue 39+ converged here. mkosi makes it trivial.
2. **Read-only `/usr` + OverlayFS `/etc`** — identical threat model (atomic updates + user config survival).
3. **Flatpak as primary app delivery** — SteamOS uses it for non-Steam apps; Silverblue makes it the *only* GUI app path.
4. **Healthcheck/rollback** — Arkane's `arkdep healthcheck` + `cleanup` is the exact logic you need (untracked deployments, hanging cache, GPG key presence).

### 5.2 What Depends on Infrastructure You Don't Have

| Feature | Owner's Infra | Your Alternative |
|---------|---------------|------------------|
| Delta updates (OSTree/Valve CDN) | Red Hat / Valve servers | **Full UKI download** — mitigate with zstd -19, GitHub Releases (2 GB limit), or self-hosted R2/Backblaze B2 ($5/mo for 1 TB). |
| Hardware certification (OpenQA) | Fedora/Valve labs | **QEMU + manual test matrix** — document tested hardware in `docs/HARDWARE.md`. |
| Signed shim (Microsoft) | Microsoft WHQL | **Self-signed + MOK enrollment** — document `mokutil --import MOK.crt` for users. |
| Automated crash aggregation | Retrace / Valve internal | **Your `telemetry/server/`** — deploy on a $5 VPS (Fly.io, Hetzner). |

### 5.3 What to Do Differently (Solo Developer Advantages)

| Area | Corporate Approach | Your Approach |
|------|-------------------|---------------|
| **Package selection** | Conservative, broad hardware support | **Curated for your hardware only** — drop `nouveau`, `amdgpu` firmware you don't need, save 200 MB. |
| **Desktop defaults** | Upstream defaults + distro branding | **Your exact workflow** — `mkosi.extra/etc/skel/` encodes your muscle memory. |
| **Update cadence** | Stable/Testing channels, weeks of QA | **Nightly → you test → promote** — you *are* QA. `manual-release.yml` is a one-click gate. |
| **Recovery** | Dedicated partition + GUI | **Minimal UKI + `reflashing.sh`** — 50 MB, boots in 3 s, pulls last stable from GitHub Releases. |
| **Documentation** | Wiki + man pages | **`docs/RUNBOOK.md` + `docs/DECISIONS.md`** — append-only, searchable, versioned. |

---

## 6. Immediate Next Steps (Checklist)

| # | Task | File(s) to Create/Modify | Dependencies |
|---|------|--------------------------|--------------|
| 1 | Resolve all `{{PLACEHOLDERS}}` in this doc | — | Hardware inventory, desktop choice |
| 2 | Write final `image/mkosi.conf` | `image/mkosi.conf` | §1 |
| 3 | Populate `image/mkosi.extra/` tree | `image/mkosi.extra/**` | §2, §3, §4 |
| 4 | Write `image/mkosi.postinst` | `image/mkosi.postinst` | §2.3 |
| 5 | Define `partitions/layout.sfdisk` | `partitions/layout.sfdisk` | §3.2, target disk size |
| 6 | Implement `scripts/build_image.sh` | `scripts/build_image.sh` | mkosi, sbctl, GitHub Actions secrets |
| 7 | Implement `scripts/test_boot.sh` | `scripts/test_boot.sh` | QEMU, OVMF, screenshot diff tool |
| 8 | Adapt `arkdep` deploy/healthcheck logic | `scripts/promote_to_stable.sh`, `scripts/rollback.sh` | §5, Arkane `arkdep` source |
| 9 | Build recovery UKI | `recovery/recovery-rootfs/` | busybox, btrfs-progs, cryptsetup, curl |
| 10 | Deploy telemetry server | `telemetry/server/` | VPS, domain, TLS cert |
| 11 | Write `docs/RUNBOOK.md` | `docs/RUNBOOK.md` | All above scripts |
| 12 | Write `docs/DECISIONS.md` (first entry) | `docs/DECISIONS.md` | This architecture doc |

---

## 7. Appendix: Minimal `mkosi.conf` for First Successful Build

```ini
# image/mkosi.conf — MINIMAL VALID CONFIG (fill placeholders)
[Distribution]
Distribution=arch
Release=rolling

[Output]
Format=uki
OutputDirectory=mkosi.output
ImageName=arch-{{IMAGE_VERSION}}

[Build]
CacheDirectory=mkosi.cache
Incremental=yes
ToolsTree=yes

[Content]
Packages=
    base
    linux
    linux-firmware
    systemd-ukify
    sbctl
    btrfs-progs
    cryptsetup
    networkmanager
    flatpak
    {{DESKTOP_META_PACKAGE}}
ReadOnly=yes
KernelCommandLine=
    root=LABEL=arch_root
    rootflags=subvol=@
    rw
    quiet
InitrdProfiles=default
RemoveFiles=
    /usr/share/doc
    /usr/share/man
    /usr/share/locale/*
    !/usr/share/locale/en*
    /var/cache/pacman/pkg/*

[Bootloader]
Bootloader=systemd-boot

[Runtime]
RAM=4G
CPU=2
KVM=yes
```

> **Test command** (local, with KVM):
> ```bash
> sudo mkosi -f image/mkosi.conf -o mkosi.output --qemu
> ```
> If it boots to a login prompt in QEMU, the skeleton works. Then layer in `mkosi.extra/`, `mkosi.postinst`, and your custom packages.

---

**End of Architecture Document**  
*Next: resolve placeholders, then implement §6 checklist in order.*
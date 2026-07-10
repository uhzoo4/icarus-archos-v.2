 18_DECISION_OUTPUT.md
# Porting Icarus-ArchOS Installer to arkdep Model

---

## 1. Corrected Layer-by-Layer Porting Table

| Layer | Disposition | Rationale |
|-------|-------------|-----------|
| **01-live-partition.sh** | **REWORK REQUIRED** | Disk wipe/EFI creation logic stays; subvolume scheme replaced entirely with arkdep layout (`/arkdep/deployments/`, `/arkdep/shared/{home,root,flatpak}`). No `@`, `@home`, `@cache`, `@log`. |
| **02-base-install.sh** | **MOVED TO BUILD TIME (mkosi)** | `pacstrap` → mkosi's `Packages=` in CI. `pacman.conf` tuning → mkosi config or image `etc/pacman.conf`. Repository keyring/mirrorlist packages (from file 17) folded in. Repository copy step removed — image is the artifact. |
| **03a-chroot-core.sh** | **UNCHANGED (moves to mkosi.extra)** | Timezone, locale, hostname, systemd-boot setup, NetworkManager enable — all `systemd-firstboot`/`localectl`/`timedatectl`/`bootctl` calls or config drops. **Exception**: "installs stock kernel as fallback" — see kernel section below. |
| **03b-custom-kernel.sh** | **MOVED TO BUILD TIME (dev machine)** | `march=native` compilation happens on dev machine → produces `linux-icarus` package → folded into mkosi `Packages=`. Target never compiles. See §3 for full design. |
| **03c-daemons.sh** | **UNCHANGED (moves to mkosi.extra)** | Service enables (`systemctl enable`), config drops for bluetooth/cups/fstrim/btrfs-scrub/pipewire. All declarative. |
| **04-graphics.sh** | **UNCHANGED (moves to mkosi.extra)** | Intel GPU packages + kernel module params (`/etc/modprobe.d/`) + VA-API config. Purely declarative. |
| **05-ui-winhybrid.sh** | **UNCHANGED (moves to mkosi.extra)** | Hyprland/Waybar/Rofi/Kitty packages + theming Python scripts + user creation (`useradd -m -G wheel,video icarus`). **User creation must happen at build time** (UID/GID fixed in image) — first boot only sets password via `systemd-firstboot` or installer prompt. |
| **06-ai-engineering-perf.sh** | **UNCHANGED (moves to mkosi.extra)** | Packages (intel-gpu-tools, nvtop, docker, mimalloc) + `ai-run` wrapper script drop. Docker group membership for `icarus` user set at build time. |
| **07-native-apps.sh** | **UNCHANGED (moves to mkosi.extra)** | Firefox/VS Code/Rust tools packages + `starship`/`eza`/`bat`/`zoxide` config + `icarus-welcome` (gum-based onboarding). **Onboarding runs on first graphical login**, not install — unchanged. |
| **08-silent-boot.sh** | **UNCHANGED (moves to mkosi.extra)** | Plymouth theme, kernel cmdline `quiet loglevel=0 rd.udev.log_level=0`, SDDM autologin for `icarus`. All config files. |

**Summary**: 7 of 10 layers port mechanically to `mkosi.extra/` + `Packages=`. Only 01, 02, 03b need structural changes.

---

## 2. Redesigned `01-live-partition.sh` for arkdep Model

```bash
#!/usr/bin/env bash
# 01-live-partition.sh — arkdep edition
# Runs on host (live ISO), wipes target disk, creates partitions,
# formats, mounts, and initializes arkdep subvolume tree.
# Idempotent-ish: safe to re-run after failure (sentinel checked by conductor).

set -euo pipefail

TARGET_DISK="${TARGET_DISK:-/dev/nvme0n1}"   # overridden by conductor/Manifest
ESP_SIZE_MIB=1024
RECOVERY_SIZE_MIB=512
DEPLOY_KEEP=3

log() { printf '\033[1;32m[partition]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[partition] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. Wipe & partition ──────────────────────────────────────────────
log "Wiping ${TARGET_DISK}..."
wipefs -a "${TARGET_DISK}"
sgdisk -Z "${TARGET_DISK}"

log "Creating partitions..."
# 1: ESP (systemd-boot + ALL UKIs)
sgdisk -n "1:0:+${ESP_SIZE_MIB}M" -t "1:ef00" -c "1:EFI System Partition" "${TARGET_DISK}"
# 2: Recovery (ext4, fixed 512MiB)
sgdisk -n "2:0:+${RECOVERY_SIZE_MIB}M" -t "2:8300" -c "2:arch_recovery" "${TARGET_DISK}"
# 3: Root (Btrfs, remainder)
sgdisk -n "3:0:0"       -t "3:8300" -c "3:arch_root" "${TARGET_DISK}"

partprobe "${TARGET_DISK}"
sleep 1

ESP_PART="${TARGET_DISK}p1"
RECOVERY_PART="${TARGET_DISK}p2"
ROOT_PART="${TARGET_DISK}p3"

# ── 2. Format ────────────────────────────────────────────────────────
log "Formatting ESP as FAT32..."
mkfs.fat -F32 -n "ESP" "${ESP_PART}"

log "Formatting Recovery as ext4..."
mkfs.ext4 -L "arch_recovery" "${RECOVERY_PART}"

log "Formatting Root as Btrfs..."
mkfs.btrfs -L "arch_root" "${ROOT_PART}"

# ── 3. Mount root & create arkdep subvolume tree ────────────────────
MNT="/mnt"
mkdir -p "${MNT}"
mount -o noatime,compress=zstd:1,space_cache=v2 "${ROOT_PART}" "${MNT}"

log "Creating arkdep subvolume tree..."
btrfs subvolume create "${MNT}/arkdep"
btrfs subvolume create "${MNT}/arkdep/deployments"
btrfs subvolume create "${MNT}/arkdep/shared"
btrfs subvolume create "${MNT}/arkdep/shared/home"
btrfs subvolume create "${MNT}/arkdep/shared/root"
btrfs subvolume create "${MNT}/arkdep/shared/flatpak"

# ── 4. Mount ESP ─────────────────────────────────────────────────────
mkdir -p "${MNT}/efi"
mount "${ESP_PART}" "${MNT}/efi"

# ── 5. Mount Recovery (for later reflash.sh population) ─────────────
mkdir -p "${MNT}/recovery"
mount "${RECOVERY_PART}" "${MNT}/recovery"

# ── 6. Create initial deployment skeleton (empty, populated by installer) ─────
DEPLOY_ID="initial-$(date +%Y%m%d-%H%M%S)"
DEPLOY_ROOT="${MNT}/arkdep/deployments/${DEPLOY_ID}"
btrfs subvolume create "${DEPLOY_ROOT}/rootfs"
btrfs subvolume create "${DEPLOY_ROOT}/rootfs/etc"
btrfs subvolume create "${DEPLOY_ROOT}/rootfs/var"

# ── 7. Bind-mount shared subvolumes into deployment for installer chroot ──────
mkdir -p "${DEPLOY_ROOT}/rootfs/home"
mkdir -p "${DEPLOY_ROOT}/rootfs/root"
mkdir -p "${DEPLOY_ROOT}/rootfs/var/lib/flatpak"
mount --bind "${MNT}/arkdep/shared/home"       "${DEPLOY_ROOT}/rootfs/home"
mount --bind "${MNT}/arkdep/shared/root"       "${DEPLOY_ROOT}/rootfs/root"
mount --bind "${MNT}/arkdep/shared/flatpak"    "${DEPLOY_ROOT}/rootfs/var/lib/flatpak"

# ── 8. Write deployment metadata for arkdep ──────────────────────────
cat >"${DEPLOY_ROOT}/metadata.json" <<EOF
{
  "id": "${DEPLOY_ID}",
  "created": "$(date -Iseconds)",
  "kernel": "linux-icarus",
  "rootfs_subvol": "arkdep/deployments/${DEPLOY_ID}/rootfs",
  "etc_subvol": "arkdep/deployments/${DEPLOY_ID}/rootfs/etc",
  "var_subvol": "arkdep/deployments/${DEPLOY_ID}/rootfs/var",
  "keep": ${DEPLOY_KEEP}
}
EOF

log "Partitioning complete. Root mounted at ${MNT}, deployment at ${DEPLOY_ROOT}"
```

**Key differences from original**:
- No `@`, `@home`, `@cache`, `@log` — replaced by arkdep tree
- Recovery partition created + mounted (for `reflash.sh` later)
- Initial deployment skeleton created with nested `etc`/`var` subvolumes **before** chroot
- Shared subvolumes bind-mounted into deployment so installer chroot sees final paths
- `metadata.json` written for arkdep tooling

---

## 3. Kernel Build Solution: `linux-icarus` Off-Target

### Problem Recap
- Original: `03b-custom-kernel.sh` runs `makepkg` **inside chroot on target** with `march=native` + CachyOS patches
- Conflict: "build once in CI, deploy same image everywhere" vs. `march=native` (target-specific)
- Constraint: Single personal machine (stated from project start) → `march=native` is valid **for that machine only**

### Solution: Dev-Machine Build → Package → mkosi Folds In

#### A. Dev Machine Build Script (`build-kernel.sh`, runs on developer's machine)

```bash
#!/usr/bin/env bash
# build-kernel.sh — runs on dev machine (same CPU as target)
# Produces linux-icarus-<ver>-<rel>-x86_64.pkg.tar.zst

set -euo pipefail

KERNEL_SRC_DIR="${KERNEL_SRC_DIR:-$(pwd)/kernel-src}"
PKGDEST="${PKGDEST:-$(pwd)/pkgout}"
CACHYOS_PATCHES="${CACHYOS_PATCHES:-${KERNEL_SRC_DIR}/cachyos-patches}"

mkdir -p "${PKGDEST}"

# 1. Fetch kernel source (same version as CI's base image)
#    Use archlinux/svntogit or kernel.org tarball — pinned version
KERNEL_VER="6.10.5"   # sync with mkosi's base package version
KERNEL_REL="1"

# 2. Prepare PKGBUILD with march=native + CachyOS patches
cat >"${KERNEL_SRC_DIR}/PKGBUILD" <<'PKGBUILD_EOF'
# Maintainer: Icarus Project
pkgbase=linux-icarus
pkgver=6.10.5
pkgrel=1
arch=(x86_64)
url="https://github.com/icarus-archos/linux-icarus"
license=(GPL2)
makedepends=(xmlto kmod inetutils bc libelf cpio perl tar xz)
options=('!strip')
_srcname="linux-${pkgver}"

source=(
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/${_srcname}.tar.xz"
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/${_srcname}.tar.sign"
  "config.x86_64"           # our base config
  "cachyos-patches.tar.gz"  # CachyOS patchset (pre-downloaded)
)
validpgpkeys=('ABAF11C65A2970B130ABE3C479BE3E4300411886')  # Linus Torvalds
sha256sums=('SKIP' 'SKIP' 'SKIP' 'SKIP')

export KBUILD_BUILD_HOST=icarus-build
export KBUILD_BUILD_USER=icarus
export KBUILD_BUILD_TIMESTAMP="$(date -Ru --date=@${SOURCE_DATE_EPOCH:-$(date +%s)})"

prepare() {
  cd "${_srcname}"
  # Apply CachyOS patches
  for p in ../cachyos-patches/*.patch; do
    patch -Np1 <"$p"
  done
  cp ../config.x86_64 .config
  # Enable march=native
  scripts/config --enable CONFIG_MNATIVE
  # Or manually: sed -i 's/CONFIG_GENERIC_CPU=y/# CONFIG_GENERIC_CPU is not set/' .config
  #             echo 'CONFIG_MNATIVE=y' >> .config
  make olddefconfig
}

build() {
  cd "${_srcname}"
  make -j"$(nproc)" all
  make -j"$(nproc)" htmldocs
}

_package() {
  pkgdesc="The Icarus kernel (march=native + CachyOS patches)"
  depends=(coreutils kmod initramfs)
  optdepends=('wireless-regdb: regulatory database'
              'linux-firmware: firmware blobs')
  provides=(linux)
  conflicts=(linux)
  replaces=(linux)

  cd "${_srcname}"
  local modulesdir="${pkgdir}/usr/lib/modules/$(<version)"
  make INSTALL_MOD_PATH="${pkgdir}/usr" INSTALL_MOD_STRIP=1 modules_install
  # Install kernel image
  install -Dm644 arch/x86/boot/bzImage "${modulesdir}/vmlinuz"
  # Install systemd-boot entry template (arkdep will generate real one)
  install -Dm644 /dev/stdin "${pkgdir}/usr/lib/systemd/boot/entry/linux-icarus.conf" <<'ENTRY_EOF'
title   Icarus Linux (linux-icarus)
linux   /vmlinuz-linux-icarus
initrd  /initramfs-linux-icarus.img
options root=LABEL=arch_root rootflags=subvol=arkdep/deployments/@DEPLOY_ID@/rootfs rw quiet loglevel=0 rd.udev.log_level=0
ENTRY_EOF
  # Clean up
  rm -f "${modulesdir}/build" "${modulesdir}/source"
}

_package-headers() {
  pkgdesc="Headers for linux-icarus"
  provides=(linux-headers)
  conflicts=(linux-headers)
  cd "${_srcname}"
  local builddir="${pkgdir}/usr/lib/modules/$(<version)/build"
  install -Dt "${builddir}" -m644 .config Makefile Module.symvers System.map version vmlinux
  install -Dt "${builddir}/kernel" -m644 kernel/Makefile
  cp -t "${builddir}" -a scripts
  # ... (standard headers install, abbreviated)
}

pkgname=("${pkgbase}" "${pkgbase}-headers")
for _p in "${pkgname[@]}"; do
  eval "package_${_p}() { _package${_p#${pkgbase}}; }"
done
PKGBUILD_EOF

# 3. Build in clean chroot (reproducible)
cd "${KERNEL_SRC_DIR}"
extra-x86_64-build -- -I "${PKGDEST}"

# 4. Sign package (dev machine has pacman key)
gpg --detach-sign --default-key "Icarus Build Key" "${PKGDEST}"/linux-icarus-*.pkg.tar.zst

log "Kernel package(s) in ${PKGDEST}"
```

#### B. CI Integration (mkosi)

```ini
# mkosi.default (or mkosi.local for dev)
[Distribution]
Distribution=arch

[Packages]
# Base packages...
linux-firmware
btrfs-progs
networkmanager
# ... all other packages from layers 03a, 03c, 04, 05, 06, 07, 08
# CUSTOM KERNEL:
linux-icarus
linux-icarus-headers

[Repository]
# Local repo with signed linux-icarus packages
Repository=https://github.com/icarus-archos/pkgrepo/releases/download/kernel/
# OR local path in CI: Repository=file:///pkgout

[Content]
# Ensure stock kernel is ALSO installed as fallback
Packages=linux
```

#### C. Reconciling "Stock Kernel Fallback" vs. "systemd-boot Rollback"

| Mechanism | What It Protects Against | Scope |
|-----------|--------------------------|-------|
| **Stock kernel (`linux` package) as secondary boot entry** | Kernel regression, broken custom kernel build, module mismatch | Single deployment — if `linux-icarus` fails to boot, user selects `linux` from same deployment's loader entries |
| **systemd-boot boot-counting rollback** | Entire deployment broken (userspace, config, initramfs, kernel) | Across deployments — if newest deployment fails 3×, boots previous deployment |

**They are complementary, not redundant.** Keep both:

1. **Each deployment gets TWO loader entries**:
   - Primary: `linux-icarus` (custom kernel)
   - Fallback: `linux` (stock kernel, same deployment's rootfs)

2. **arkdep generates both entries** when creating a deployment:
   ```bash
   # In arkdep's generate-loader-entry.sh
   cat >"${ESP}/loader/entries/${DEPLOY_ID}-icarus.conf" <<EOF
   title   Icarus Linux (${DEPLOY_ID}) — linux-icarus
   linux   /vmlinuz-linux-icarus
   initrd  /initramfs-linux-icarus.img
   options root=LABEL=arch_root rootflags=subvol=${ROOTFS_SUBVOL} rw quiet loglevel=0
   EOF

   cat >"${ESP}/loader/entries/${DEPLOY_ID}-stock.conf" <<EOF
   title   Icarus Linux (${DEPLOY_ID}) — linux (fallback)
   linux   /vmlinuz-linux
   initrd  /initramfs-linux.img
   options root=LABEL=arch_root rootflags=subvol=${ROOTFS_SUBVOL} rw quiet loglevel=0
   EOF
   ```

3. **systemd-boot counts each entry independently** (`bootcount=yes` per entry). If `linux-icarus` fails 3×, it tries `linux` (same deployment). If that fails 3×, it tries previous deployment's `linux-icarus`.

4. **Recovery entry** (from file 06) is never boot-counted, always visible.

**This preserves the original design's intent** (guaranteed bootable fallback) **and adds** the deployment-level rollback.

---

## 4. Conductor Decision: Keep `icarus-assemble.sh` Pattern

**Decision: KEEP the conductor + MANIFEST + sentinel `.done` files for the NEW installer.**

### Why
- Proven working pattern for *this project* — not borrowed, not theoretical
- Installer still has sequential, stateful steps that benefit from resumability:
  1. Partition disk (01)
  2. Write pre-built image to root partition (new step)
  3. Initialize arkdep (create first deployment, populate from image)
  4. Install bootloader (systemd-boot + UKIs + Secure Boot enroll)
  5. First-boot configuration (user password, hostname, MOK enrollment if needed)
  6. Reboot into new deployment

- Sentinel files (`layer-01.done`, `layer-02.done`, ...) allow recovery from power loss, network failure during image download, etc. — same value as original.

### New Conductor Flow (`icarus-install.sh`)

```bash
#!/usr/bin/env bash
# icarus-install.sh — new conductor for arkdep installer
# Reads MANIFEST, executes layers, resumes via .done sentinels

MANIFEST="MANIFEST.install"
LAYERS_DIR="install-layers"
STATE_DIR="/var/lib/icarus-install"

mkdir -p "${STATE_DIR}"

run_layer() {
  local num="$1" name="$2" script="$3"
  local sentinel="${STATE_DIR}/layer-${num}.done"
  
  if [[ -f "${sentinel}" ]]; then
    log "Layer ${num} (${name}) already done, skipping"
    return 0
  fi
  
  log "Running layer ${num}: ${name}"
  bash "${LAYERS_DIR}/${script}"
  touch "${sentinel}"
  log "Layer ${num} complete"
}

# MANIFEST.install format: num|name|script
# 01|partition|01-partition.sh
# 02|write-image|02-write-image.sh
# 03|init-arkdep|03-init-arkdep.sh
# 04|bootloader|04-bootloader.sh
# 05|firstboot|05-firstboot.sh

while IFS='|' read -r num name script; do
  [[ -z "${num}" || "${num}" =~ ^# ]] && continue
  run_layer "${num}" "${name}" "${script}"
done < "${MANIFEST}"

log "Installation complete. Rebooting..."
reboot
```

### New Install Layers (replacing old 01–10)

| New Layer | Script | Purpose |
|-----------|--------|---------|
| 01 | `01-partition.sh` | Redesigned `01-live-partition.sh` from §2 |
| 02 | `02-write-image.sh` | `mkosi` output (raw disk image or UKI + rootfs tarball) written to `ROOT_PART` via `dd`/`btrfs send` |
| 03 | `03-init-arkdep.sh` | Create first deployment subvolume, extract rootfs, run `migrate_files.sh`, set read-only, write metadata |
| 04 | `04-bootloader.sh` | `bootctl install`, generate loader entries for deployment, sign UKIs, `efibootmgr --bootnext` |
| 05 | `05-firstboot.sh` | Prompt for user password, hostname, timezone; enroll MOK if Secure Boot; run `systemd-firstboot` |

**Old layers 02–10 disappear from install-time** — their work is baked into the mkosi image.

---

## 5. Installer Type Decision: Custom Conductor > archiso+Calamares

**Decision: EXTEND THE EXISTING CUSTOM CONDUCTOR. Do not adopt archiso/Calamares.**

### Reasoning

| Factor | Custom Conductor (icarus-assemble.sh lineage) | archiso + Calamares |
|--------|-----------------------------------------------|---------------------|
| **Existing working code** | 10 layers + conductor already written, tested, project-specific | Would require rewriting all layer logic into Calamares modules |
| **arkdep integration** | Native — conductor controls partition → image write → arkdep init → bootloader | Calamares knows nothing of arkdep; would need custom C++/Python module |
| **Resumability** | Sentinel files, proven | Calamares has no resume; failure = full restart |
| **Secure Boot enrollment** | Scripted (`sbctl enroll-key`, `mokutil`) | Calamares has no Secure Boot module |
| **Recovery partition population** | `reflash.sh` logic integrated in layer 03 | Would need custom module |
| **Maintenance burden** | Pure bash, project-owned | Two upstream projects + custom modules |
| **EndeavourOS reference** | Only used for disk-prep mechanics (sgdisk, mkfs) — already in 01-partition.sh | Not needed as primary model |

**The EndeavourOS excerpts remain useful only for:**
- `sgdisk` partition type codes (already used)
- `mkfs` flags (already used)
- `.automated_script.sh` kernel cmdline convention → adopt for **headless install mode**: `script=https://.../icarus-install.sh` passed via kernel cmdline, fetched and run by a minimal initrd service. This is a **feature addition**, not an architecture change.

---

## 6. What Gets Dropped Entirely

| Dropped Item | Reason |
|--------------|--------|
| `02-base-install.sh` (pacstrap, fstab gen, repo copy) | Replaced by mkosi build in CI |
| `03b-custom-kernel.sh` (target-machine compilation) | Moved to dev-machine build (§3) |
| `pacman.conf` optimization in chroot | Done at build time in mkosi config |
| `bootctl install` inside chroot | Done at install time (layer 04) on live system — more reliable |
| `fstab` generation | arkdep uses `rootflags=subvol=...` via kernel cmdline; no fstab needed for root. `/etc/fstab` only for ESP + shared mounts (generated by arkdep). |
| `mkinitcpio` runs in chroot | UKIs built by mkosi in CI (with `uki` addon) — no initramfs on target |
| `grub` / any bootloader other than systemd-boot | Architecture decision (file 03) |
| `btrfs-scrub`/`fstrim` timer setup in chroot | Enabled via `systemctl enable` in mkosi.extra (layer 03c) — timers active on first boot |
| User password setting in chroot | Done at install layer 05 (interactive) or `systemd-firstboot` (unattended) |
| MOK enrollment in chroot | Impossible — requires UEFI firmware interaction at boot. Done at install layer 05 or first boot. |

---

## 7. New Directory Structure Added to Project

```
icarus-archos/
├── build/                          # Dev-machine build scripts (not in image)
│   ├── build-kernel.sh             # §3.A — produces linux-icarus pkg
│   ├── build-image.sh              # Runs mkosi, outputs image/uki
│   └── sign-packages.sh            # GPG signs kernel packages + UKIs
│
├── install/                        # NEW: Installer (replaces old layers/ root)
│   ├── icarus-install.sh           # Conductor (MANIFEST + sentinels)
│   ├── MANIFEST.install            # Layer list
│   ├── install-layers/
│   │   ├── 01-partition.sh         # §2 redesigned partitioner
│   │   ├── 02-write-image.sh       # dd/btrfs-send mkosi output to disk
│   │   ├── 03-init-arkdep.sh       # Create deployment, migrate, set ro
│   │   ├── 04-bootloader.sh        # bootctl, UKI deploy, loader entries
│   │   └── 05-firstboot.sh         # Password, hostname, MOK enroll
│   └── recovery/
│       └── reflash.sh              # From file 06 — copied to recovery partition
│
├── mkosi/                          # mkosi build definition (CI)
│   ├── mkosi.default               # Main config
│   ├── mkosi.extra/                # ← ALL old layers 03a,03c,04,05,06,07,08 content here
│   │   ├── etc/
│   │   │   ├── pacman.conf
│   │   │   ├── locale.conf
│   │   │   ├── hostname
│   │   │   ├── modprobe.d/
│   │   │   ├── systemd/
│   │   │   │   ├── system/
│   │   │   │   │   ├── bluetooth.service.d/
│   │   │   │   │   ├── fstrim.timer.d/
│   │   │   │   │   └── ...
│   │   │   ├── sddm.conf.d/
│   │   │   ├── plymouth/
│   │   │   └── ...
│   │   ├── usr/
│   │   │   ├── bin/
│   │   │   │   ├── ai-run
│   │   │   │   ├── icarus-welcome
│   │   │   │   └── migrate_files.sh
│   │   │   ├── share/
│   │   │   │   ├── hyprland/
│   │   │   │   ├── waybar/
│   │   │   │   └── themes/ (Python theming scripts)
│   │   │   └── lib/
│   │   │       └── systemd/
│   │   │           ├── system/
│   │   │           └── systemd-boot-success.service
│   │   └── var/
│   │       └── lib/flatpak/ (empty, bind-mounted)
│   ├── packages.list               # Explicit package list (all layers)
│   └── kernel/
│       └── linux-icarus/           # Dev-built package staged here for CI
│
├── kernel-src/                     # Kernel build context (dev machine)
│   ├── PKGBUILD                    # Generated by build-kernel.sh
│   ├── config.x86_64               # Base kernel config
│   └── cachyos-patches/            # CachyOS patchset (git submodule or tarball)
│
├── pkgout/                         # Dev machine package output (gitignored)
│
├── arkdep/                         # arkdep tooling (from file 03)
│   ├── deploy.sh
│   ├── migrate_files.sh
│   ├── generate-loader-entry.sh
│   └── prune-deployments.sh
│
├── secure-boot/                    # File 04 material
│   ├── enroll-mok.sh
│   └── keys/ (public certs only)
│
├── telemetry/                      # File 05 material
│
├── recovery/                       # File 06 material (source for install/recovery/)
│
├── repo/                           # File 17 material
│   ├── arch-os-keyring/
│   └── arch-os-mirrorlist/
│
├── 18_PROMPT_NEMOTRON_07_installer_medium.md  # This prompt's source
└── RUNNING_CONTEXT.md              # Architecture decisions (files 03,04,05,06,17)
```

---

## Validation Checklist (Before Trusting)

- [ ] **Kernel build test**: Run `build-kernel.sh` on dev machine → install `linux-icarus` in VM → boot → confirm `march=native` works (check `/proc/cpuinfo` flags, `dmesg` for CachyOS patches)
- [ ] **UKI + systemd-boot test**: Build image with mkosi → write to disk via `02-write-image.sh` → run `04-bootloader.sh` → verify both `linux-icarus` and `linux` entries appear and boot
- [ ] **Rollback test**: Create 2 deployments → corrupt newest → verify systemd-boot falls back after 3 failures
- [ ] **Recovery test**: Boot recovery partition → run `reflash.sh` → verify new deployment created and boots
- [ ] **First-boot test**: Run full installer → verify user password, hostname, MOK enrollment all work

The kernel build is the highest-risk item — test it **before** integrating into CI.
================================================================================
REVISED DOCUMENT 1 (v2) — Partition, Deployment & Rollback Architecture
================================================================================

> **⚠ ONE CORRECTION APPLIED AFTER NEMOTRON'S OUTPUT — see banner details**
> Nemotron's revision (this is the v2 pass) got the deployment model,
> boot-counting integration, and mkosi corrections right. One structural
> detail was still wrong: it treated `rootfs`, `etc`, and `var` as three
> SIBLING subvolumes under each deployment ID. Real arkdep source (verified
> directly — `arkdep-build`'s `btrfs send $workdir/etc` /
> `btrfs send $workdir/var`, and `arkdep`'s matching `btrfs receive
> .../rootfs/` calls) nests `etc` and `var` INSIDE the `rootfs` subvolume,
> not beside it. This matters mechanically: a Btrfs subvolume nested inside
> another is automatically visible once the parent is mounted — that's the
> entire reason arkdep nests them there, so a single
> `rootflags=subvol=.../rootfs` mount pulls in `/etc` and `/var` with no
> extra fstab entry. The sibling layout would have booted to an empty
> `/etc` and `/var`. Every occurrence below has been corrected to the
> nested layout. Nothing else in Nemotron's design was changed.

--------------------------------------------------------------------------------
(a) STATE DIAGRAM — DEPLOYMENT LIFECYCLE (arkdep model + systemd-boot counting)
--------------------------------------------------------------------------------

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DEPLOYMENT STATE MACHINE                             │
└─────────────────────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────────────┐
    │                     SINGLE ROOT PARTITION                            │
    │                    (LABEL=arch_root, Btrfs)                          │
    │                                                                       │
    │  /arkdep/deployments/                                                │
    │  ├─ 2024.01.15-abc123/  ← deployment                                │
    │  │   └─ rootfs/           ← mounted as / (btrfs ro=true)             │
    │  │        ├─ etc/         ← NESTED subvolume, auto-included, ro=true│
    │  │        └─ var/         ← NESTED subvolume, auto-included, ro=true│
    │  ├─ 2024.01.10-def456/  ← previous deployment (kept)               │
    │  ├─ 2024.01.05-ghi789/  ← older deployment (kept)                   │
    │  └─ ...                  ← up to deploy_keep=3 (configurable)       │
    │                                                                       │
    │  /arkdep/shared/           ← ALWAYS writable, persist across deploys │
    │  ├─ home/                  ← user data (subvolume)                  │
    │  ├─ root/                  ← curated state (see migrate_files)      │
    │  └─ flatpak/               ← system Flatpaks                        │
    └────────────────────────────┬─────────────────────────────────────────┘
                                 │
                                 ▼
    ┌──────────────────────────────────────────────────────────────────────┐
    │                        BOOT ATTEMPT (systemd-boot)                   │
    │  1. Read loader.conf: bootcount=yes, bootcount-limit=3              │
    │  2. Menu shows ONE entry per kept deployment (newest first)         │
    │  3. User selects entry OR 'default' (newest) OR 'next' (efibootmgr) │
    │  4. Increment EFI var: LoaderEntrySelected-<machine-id>-<entry-id>  │
    │  5. Launch UKI (kernel + initrd + cmdline with deployment-specific  │
    │     rootflags=subvol=/arkdep/deployments/<id>/rootfs — mounting     │
    │     this single subvolume brings /etc and /var with it, since they │
    │     are nested subvolumes underneath it, not siblings)             │
    └────────────────────────────┬─────────────────────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    ▼                         ▼
           ┌───────────────┐           ┌───────────────┐
           │  BOOT SUCCESS │           │  BOOT FAILURE │
           │  (reaches     │           │  (kernel panic,│
           │   graphical   │           │   emergency   │
           │   target)     │           │   shell,      │
           └───────┬───────┘           │   watchdog)   │
                   │                   └───────┬───────┘
                   │                           │
                   ▼                           ▼
    ┌─────────────────────────┐    ┌─────────────────────────┐
    │ systemd-boot-success    │    │ Counter increments      │
    │ .service runs           │    │ (persisted in EFI var)  │
    │ → resets counter to 0   │    │                         │
    │ → marks entry HEALTHY   │    │ If counter < 3:         │
    │ → clears 'next' entry   │    │   → reboot, retry SAME  │
    └───────────┬─────────────┘    │   → user sees menu      │
                │                  │ If counter == 3:        │
                │                  │   → entry marked BAD    │
                │                  │   → systemd-boot skips  │
                │                  │   → tries NEXT entry    │
                │                  │     (older deployment)  │
                │                  └───────────┬─────────────┘
                │                              │
                │                              ▼
                │                     ┌─────────────────────────┐
                │                     │ AUTOMATIC FALLBACK      │
                │                     │ (systemd-boot native)   │
                │                     │                         │
                │                     │ Oldest non-BAD entry    │
                │                     │ becomes default boot    │
                │                     │ bootcount reset to 0    │
                │                     └───────────┬─────────────┘
                │                                 │
                └─────────────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │   STEADY STATE          │
                    │   One deployment ACTIVE │
                    │   N-1 deployments KEPT  │
                    │   (up to deploy_keep)   │
                    │   Recovery always avail │
                    └─────────────────────────┘


UPDATE TRANSITION (initiated from RUNNING OS via arkdep):
┌─────────────────────────────────────────────────────────────────────────────┐
│  CURRENT STATE: Deployment "2024.01.15-abc123" = ACTIVE                     │
│                 Deployments "2024.01.10-def456", "2024.01.05-ghi789" KEPT  │
└─────────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. CI builds new UKI → writes to /efi/EFI/Linux/arch-<ver>-<id>.efi       │
│  2. arkdep deploy (or local script):                                        │
│     a) Create NEW subvolume, then nest etc/var INSIDE it (not beside it):  │
│        btrfs subvolume create /arkdep/deployments/2024.01.20-newid/rootfs  │
│        btrfs subvolume create /arkdep/deployments/2024.01.20-newid/rootfs/etc │
│        btrfs subvolume create /arkdep/deployments/2024.01.20-newid/rootfs/var │
│     b) Extract rootfs content into the new subvolume (content destined   │
│        for /etc and /var lands inside their own nested subvolumes        │
│        automatically, since those paths ARE separate subvolumes already) │
│     c) Run migrate_files: copy allow-listed paths from CURRENT deployment │
│        rootfs (read-only) → NEW deployment rootfs (temporarily ro=false)  │
│     d) Set NEW deployment read-only, nested order (rootfs, then etc/var  │
│        which live INSIDE it):                                             │
│        btrfs property set -ts /arkdep/deployments/2024.01.20-newid/rootfs ro true │
│        btrfs property set -ts .../rootfs/etc ro true                      │
│        btrfs property set -ts .../rootfs/var ro true                      │
│     e) Create loader entry for new deployment:                              │
│        title   Autonomous Arch OS (2024.01.20-newid)                        │
│        linux   /EFI/Linux/arch-2024.01.20-newid.efi                         │
│        options root=LABEL=arch_root rootflags=subvol=                      │
│                  /arkdep/deployments/2024.01.20-newid/rootfs ...            │
│        id      arch-deploy-2024.01.20-newid                                 │
│     f) Prune oldest deployment if count > deploy_keep (default 3)          │
│     g) Set 'next' boot to new deployment (efibootmgr --bootnext)           │
│     h) Reboot                                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  BOOT SEQUENCE ON NEW DEPLOYMENT (first attempt, bootcount=1):             │
│  - If SUCCESS (reaches graphical.target):                                   │
│      → systemd-boot-success resets counter                                  │
│      → New deployment becomes ACTIVE                                        │
│      → CI promotes build to stable repo                                     │
│  - If FAILURE (3 consecutive):                                              │
│      → Entry marked BAD by systemd-boot                                     │
│      → Falls back to PREVIOUS deployment (next in menu)                     │
│      → CI marks build FAILED, no promotion                                  │
│      → Old deployment remains read-only, untouched                          │
└─────────────────────────────────────────────────────────────────────────────┘


MANUAL ROLLBACK (from BOOT MENU, no OS required):
┌─────────────────────────────────────────────────────────────────────────────┐
│  User at systemd-boot menu (10s timeout):                                   │
│  1. Menu shows:                                                             │
│     ▸ Autonomous Arch OS (2024.01.20-newid)    [newest, bootcount=0]       │
│       Autonomous Arch OS (2024.01.15-abc123)   [previous, bootcount=0]     │
│       Autonomous Arch OS (2024.01.10-def456)   [older, bootcount=0]        │
│       Autonomous Arch OS (Recovery)            [recovery-2024.06.15]       │
│  2. Select any deployment entry → boots that exact subvolume               │
│  3. If that deployment boots → becomes ACTIVE (counter reset)              │
│  4. If that deployment fails 3× → systemd-boot tries NEXT older entry      │
│  5. Recovery entry always available as last resort                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

--------------------------------------------------------------------------------
(b) PARTITION LAYOUT — `partitions/layout.sfdisk`
--------------------------------------------------------------------------------

```sfdisk
label: gpt
unit: sectors

# 1. ESP — 1 GiB (shared, holds ALL UKIs + loader entries)
/dev/disk/by-partlabel/esp : start=2048, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"

# 2. Root — single partition, ALL deployments live here as Btrfs subvolumes
#    Label: arch_root (chosen for project branding; arkdep uses arkane_root)
#    Size: remaining disk minus recovery (see below)
/dev/disk/by-partlabel/root : size=+, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"

# 3. Recovery — 512 MiB ext4 (dedicated partition, Document 2 design preserved)
/dev/disk/by-partlabel/recovery : size=1048576, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="recovery"
```

**Why `arch_root` not `arkane_root`?**
Project is "Autonomous Arch OS" — label matches branding. Functionally identical to arkdep's `arkane_root`; only the string in kernel cmdline and `mkosi.conf` changes.

**Btrfs Subvolume Tree** (created at install by `scripts/install.sh`) —
**CORRECTED: `etc` and `var` are nested inside `rootfs`, not siblings of it**
(verified against arkdep's own `btrfs send $workdir/etc` / `$workdir/var` and
matching `btrfs receive .../rootfs/` calls):

```
/ (root partition, Btrfs, labeled arch_root)
├─ arkdep/
│  ├─ deployments/              ← ONE directory per OS deployment
│  │  ├─ 2024.01.20-newid/
│  │  │  └─ rootfs/            ← THE subvolume mounted as / when active
│  │  │       ├─ etc/          ← NESTED subvolume — auto-included when
│  │  │       │                  rootfs is mounted, no separate fstab entry
│  │  │       └─ var/          ← NESTED subvolume — same as above
│  │  ├─ 2024.01.15-abc123/
│  │  │  └─ rootfs/
│  │  │       ├─ etc/
│  │  │       └─ var/
│  │  └─ ...                   ← up to deploy_keep=3
│  └─ shared/                  ← ONLY THREE unconditionally shared subvolumes
│     ├─ home/                 ← /home (user data, always writable)
│     ├─ root/                 ← curated persistent state (see migrate_files)
│     └─ flatpak/              ← /var/lib/flatpak (system Flatpaks)
│
└─ (no @var, @home, @_a, @_b, @snapshots — arkdep model replaces all)
```

**Kernel Command Line** (baked into each UKI, deployment-specific):

```
# Deployment 2024.01.20-newid UKI
root=LABEL=arch_root rootflags=subvol=/arkdep/deployments/2024.01.20-newid/rootfs rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0 bootcount
```

> This line did NOT need correcting — it already pointed at `rootfs` only,
> which is correct: mounting `rootfs` brings its nested `etc`/`var`
> subvolumes with it automatically.

> **Critical**: `bootcount` kernel parameter is added by systemd-boot when `bootcount=yes` in loader.conf. This enables `systemd-boot-success.service`.

--------------------------------------------------------------------------------
(c) SYSTEMD-BOOT BOOT COUNTING CONFIGURATION
--------------------------------------------------------------------------------

**Systemd Version**: Boot counting introduced in **systemd 250** (2023-03-07). Not independently re-verified against source in this pass — flagged previously as worth confirming yourself against the systemd changelog.
**Mechanism**: Native EFI variable counters per boot entry — **not** a userspace watchdog.
**Interaction with arkdep**: arkdep manages deployments (create, migrate, prune, loader entries). systemd-boot manages per-entry boot counting and automatic fallback. They are **orthogonal layers** — see §(e) for explicit interaction model.

### 1. `/efi/loader/loader.conf` (Global)

```ini
# /efi/loader/loader.conf
# SPDX-License-Identifier: MIT

# Enable boot attempt counting per entry
bootcount=yes

# Maximum consecutive failures before entry is skipped (default: 3)
# JUSTIFICATION FOR 3:
# - 1: Too fragile — transient hardware glitch or first-boot race triggers fallback
# - 2: Better, but still vulnerable to correlated transient failures
# - 3: Industry standard (Chrome OS, Fedora Silverblue, SteamOS all use 3)
#      Balances "fail fast" vs "don't flip on fluke"
# - >3: Delays recovery, user sees broken boot longer
bootcount-limit=3

# Show menu for 10s — allows manual rollback selection
timeout=10

# No default entry — use 'saved' behavior via efibootmgr --bootnext
# On first boot, systemd-boot picks first entry alphabetically (newest deploy)
default=

# Console mode for consistent rendering
console-mode=keep

# Editor=1 allows 'e' to edit kernel cmdline at boot (recovery aid)
editor=yes

# Auto-firmware=1 enables fwupd UEFI capsule updates via boot menu
auto-firmware=yes
```

### 2. Boot Entries — `/efi/loader/entries/arch-deploy-<id>.conf`

**Generated by arkdep/deploy script for EACH kept deployment** (newest first in menu):

```ini
# /efi/loader/entries/arch-deploy-2024.01.20-newid.conf
title   Autonomous Arch OS (2024.01.20-newid)
version 2024.01.20-newid
linux   /EFI/Linux/arch-2024.01.20-newid.efi
options root=LABEL=arch_root rootflags=subvol=/arkdep/deployments/2024.01.20-newid/rootfs rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0
id      arch-deploy-2024.01.20-newid
```

```ini
# /efi/loader/entries/arch-deploy-2024.01.15-abc123.conf
title   Autonomous Arch OS (2024.01.15-abc123)
version 2024.01.15-abc123
linux   /EFI/Linux/arch-2024.01.15-abc123.efi
options root=LABEL=arch_root rootflags=subvol=/arkdep/deployments/2024.01.15-abc123/rootfs rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0
id      arch-deploy-2024.01.15-abc123
```

**Recovery Entry** (from Document 2, unchanged):

```ini
# /efi/loader/entries/arch-recovery.conf
title   Autonomous Arch OS (Recovery)
version recovery-2024.06.15
linux   /EFI/Linux/arch-recovery.efi
options root=LABEL=arch_recovery rootflags=rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0 systemd.unit=emergency.target
id      arch-recovery-<STATIC_UUID_RECOVERY>
```

> **Critical**: The `id` field **must be stable** across image rebuilds.
> Format: `arch-deploy-<deployment-id>` where deployment-id is the subvolume name (timestamp + short hash).
> Generated at deploy time, stored in `/etc/machine-id-arch-deploy-<id>`, baked into UKI via `mkosi.extra/etc/machine-id-arch-deploy-*`.

### 3. Boot Success Service — `/usr/lib/systemd/system/systemd-boot-success.service`

```ini
# /usr/lib/systemd/system/systemd-boot-success.service
# SPDX-License-Identifier: LGPL-2.1-or-later
# Part of systemd 250+ — resets boot counter on successful boot

[Unit]
Description=Mark boot as successful for systemd-boot
Documentation=man:systemd-boot(7)
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target
ConditionPathExists=/sys/firmware/efi
ConditionKernelCommandLine=|bootcount

[Service]
Type=oneshot
ExecStart=/usr/lib/systemd/systemd-boot-success
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
```

> **Provided by systemd 250+** — no custom script needed.
> Triggers when `bootcount` kernel parameter is present (added by systemd-boot when `bootcount=yes`).
> Resets the EFI variable counter for the current entry to 0.

### 4. Update Flow — Setting `next` Boot (from Running OS via arkdep)
**CORRECTED: subvolume creation and property-set calls now nest etc/var
inside rootfs; migrate_files now points at the rootfs path, not the bare
deployment directory.**

```bash
# scripts/deploy_new_image.sh (runs after new UKI built and verified)
#!/usr/bin/env bash
set -euo pipefail

NEW_DEPLOY_ID="2024.01.20-$(git rev-parse --short=6 HEAD)"
NEW_UKI="/efi/EFI/Linux/arch-${NEW_DEPLOY_ID}.efi"
NEW_ROOTFS="/arkdep/deployments/${NEW_DEPLOY_ID}/rootfs"

# 1. Create new deployment subvolume, then nest etc/var INSIDE it
btrfs subvolume create "$NEW_ROOTFS"
btrfs subvolume create "$NEW_ROOTFS/etc"
btrfs subvolume create "$NEW_ROOTFS/var"

# 2. Extract rootfs into new deployment (from UKI or image tarball)
#    Content destined for /etc and /var lands inside the nested subvolumes
#    automatically, since those paths already ARE separate subvolumes.
extract_rootfs "$NEW_UKI" "$NEW_ROOTFS"

# 3. Migrate curated files from CURRENT deployment's rootfs (arkdep's migrate_files)
CURRENT_DEPLOY=$(findmnt -no SOURCE / | sed 's/.*deployments\///' | cut -d'/' -f1)
CURRENT_ROOTFS="/arkdep/deployments/${CURRENT_DEPLOY}/rootfs"
migrate_files "$CURRENT_ROOTFS" "$NEW_ROOTFS"

# 4. Set new deployment read-only (nested order: rootfs, then etc/var inside it)
btrfs property set -ts "$NEW_ROOTFS" ro true
btrfs property set -ts "$NEW_ROOTFS/etc" ro true
btrfs property set -ts "$NEW_ROOTFS/var" ro true

# 5. Create loader entry for new deployment
cat > "/efi/loader/entries/arch-deploy-${NEW_DEPLOY_ID}.conf" <<EOF
title   Autonomous Arch OS (${NEW_DEPLOY_ID})
version ${NEW_DEPLOY_ID}
linux   /EFI/Linux/arch-${NEW_DEPLOY_ID}.efi
options root=LABEL=arch_root rootflags=subvol=/arkdep/deployments/${NEW_DEPLOY_ID}/rootfs rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0
id      arch-deploy-${NEW_DEPLOY_ID}
EOF

# 6. Prune oldest deployment if over deploy_keep (default 3)
DEPLOY_COUNT=$(ls -1 /arkdep/deployments | wc -l)
if [[ $DEPLOY_COUNT -gt 3 ]]; then
    OLDEST=$(ls -1 /arkdep/deployments | head -n1)
    btrfs subvolume delete "/arkdep/deployments/${OLDEST}/rootfs/etc"
    btrfs subvolume delete "/arkdep/deployments/${OLDEST}/rootfs/var"
    btrfs subvolume delete "/arkdep/deployments/${OLDEST}/rootfs"
    rm -f "/efi/loader/entries/arch-deploy-${OLDEST}.conf"
    rm -f "/efi/EFI/Linux/arch-${OLDEST}.efi"
fi

# 7. Set next boot to new deployment
efibootmgr --bootnext "$(efibootmgr | grep "arch-deploy-${NEW_DEPLOY_ID}" | sed 's/^Boot\([0-9]*\).*/\1/')"

# 8. Reboot to test
systemctl reboot
```

> **Also corrected in step 6**: nested Btrfs subvolumes must be deleted
> before their parent — `btrfs subvolume delete` on `rootfs` while `etc`/
> `var` still exist nested inside it will fail. Delete children first.

### 5. `migrate_files` Implementation (arkdep's curated allow-list + project extensions)

```bash
# scripts/migrate_files.sh
#!/usr/bin/env bash
set -euo pipefail

SRC_ROOTFS="$1"   # e.g. /arkdep/deployments/2024.01.15-abc123/rootfs
DST_ROOTFS="$2"   # e.g. /arkdep/deployments/2024.01.20-newid/rootfs

# Temporarily make destination writable (rootfs, then its nested etc/var)
btrfs property set -ts "$DST_ROOTFS" ro false
btrfs property set -ts "$DST_ROOTFS/etc" ro false
btrfs property set -ts "$DST_ROOTFS/var" ro false

# arkdep DEFAULT migrate_files (from verified source):
MIGRATE_FILES=(
    'var/usrlocal' 'var/opt' 'var/srv' 'var/lib/AccountsService'
    'var/lib/bluetooth' 'var/lib/NetworkManager' 'var/lib/arkane'
    'var/lib/power-profiles-daemon' 'var/db' 'etc/localtime' 'etc/locale.gen'
    'etc/locale.conf' 'etc/NetworkManager/system-connections' 'etc/ssh'
    'etc/fstab' 'etc/crypttab' 'etc/luks-keys' 'etc/passwd' 'etc/shadow'
    'etc/group' 'etc/subuid' 'etc/subgid'
)

# PROJECT EXTENSIONS (explicitly added beyond arkdep default):
# Rationale: Autonomous Arch OS specific persistent state
MIGRATE_FILES+=(
    'etc/hostname' 'etc/machine-id' 'etc/hosts'
    'etc/systemd/network' 'etc/systemd/resolved.conf'
    'var/lib/systemd/timesync' 'var/lib/systemd/clock'
    'etc/pacman.d/gnupg' 'etc/pacman.conf'
    'etc/sbctl' 'etc/secureboot'
)

for rel_path in "${MIGRATE_FILES[@]}"; do
    src="${SRC_ROOTFS}/${rel_path}"
    dst="${DST_ROOTFS}/${rel_path}"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
done

# Re-enable read-only on destination (etc/var first, then their parent rootfs)
btrfs property set -ts "$DST_ROOTFS/etc" ro true
btrfs property set -ts "$DST_ROOTFS/var" ro true
btrfs property set -ts "$DST_ROOTFS" ro true
```

--------------------------------------------------------------------------------
(d) GUARANTEES & NON-GUARANTEES — PLAIN LANGUAGE
--------------------------------------------------------------------------------

### ✅ WHAT THIS DESIGN PROTECTS AGAINST

| Threat | Protection Mechanism |
|--------|---------------------|
| **Bad OS update breaks boot** | New deployment written to **new subvolume only**. Active deployment untouched. If new deployment fails 3×, systemd-boot **automatically falls back** to previous deployment (next in menu). |
| **Kernel panic / initrd failure / driver regression** | Boot counting catches any failure before `graphical.target`. 3 strikes → fallback to older deployment. |
| **User forced to fix via live USB** | **Manual rollback from boot menu** — press arrow keys at 10s timeout, select any kept deployment. Works even if newest deployment doesn't reach login. |
| **Bitrot / silent corruption on old deployment** | Old deployments verified on **next boot attempt** (not at write time). Corruption detected before it becomes active. |
| **Bootloader config corruption** | `loader.conf` and entries on **shared ESP** — single source of truth. All deployments reference same ESP. |
| **Power loss during update** | Update creates **new** subvolume only. Active deployment never modified mid-write. Pruning happens after new deployment is ready. |
| **Firmware/UEFI variable loss** | Boot counting uses EFI vars, but fallback logic is in **systemd-boot binary** — if vars lost, counters reset to 0 (safe default, newest deployment tried first). |
| **Accidental config drift in `/etc`** | `/etc` is **part of each deployment** (read-only, nested subvolume). Only curated `migrate_files` copied forward. No OverlayFS upper dir to accumulate drift. |

### ❌ WHAT THIS DESIGN DOES **NOT** PROTECT AGAINST

| Threat | Why Not Protected | Mitigation (Out of Scope) |
|--------|-------------------|---------------------------|
| **Silent data corruption in `/home`** | `/home` is **shared** (`arkdep/shared/home` subvolume). All deployments mount same `/home`. A bug that corrupts user files affects all deployments. | **User responsibility**: Backups (borg, restic, timeshift on `@home`), RAID/ZFS on separate disk, cloud sync. |
| **Silent data corruption in curated `/var` paths** | Only `migrate_files` paths persist across deployments. Flatpak data, NetworkManager state, etc. — shared via migration. Corruption in migrated files affects new deployment. | Same as above. Critical state (SSH keys, machine-id) migrated but not versioned per-deployment. |
| **Malicious/buggy config in `/etc` that survives rollback** | `migrate_files` **copies forward** curated paths. A bad config in `etc/NetworkManager/system-connections` **survives rollback** to new deployment. | Admin must manually clean migrated files. `migrate_files` only copies; does not validate. |
| **Hardware failure (disk death, RAM, CPU)** | Single disk = single point of failure. All deployments on same device. | **Out of scope**: Use separate physical disks, RAID, or cloud backup. |
| **Firmware/BIOS boot order corruption** | systemd-boot entries stored in ESP. If UEFI vars wiped, boot order lost but entries remain. | `efibootmgr` backup/restore, or UEFI shell `bcfg` dump. |
| **Evil maid / physical attacker** | No full-disk encryption in this design (LUKS optional but not mandated). | Add LUKS2 + TPM2 + PCR binding (future work). |
| **Kernel exploit persisting in memory** | Reboot clears RAM. But if exploit writes to `/home` or migrated `/var`, persists. | Immutable `/usr` + signed UKI + Secure Boot raises bar. |
| **Supply chain compromise (upstream Arch package)** | Packages pulled from Arch Linux Archive at build time. No runtime verification beyond sbctl. | Reproducible builds, sigstore/cosign on custom packages (future work). |
| **Boot counting false positive (3 transient fails)** | Cosmic ray, thermal throttle, marginal RAM could cause 3 fails → fallback to **also-broken** deployment if both have same bug. | Probability extremely low. Hardware health monitoring (smartd, mcelog) recommended. |
| **Deployment count exceeded (pruning loses known-good)** | `deploy_keep=3` default. If 4 bad deployments pushed, oldest good one pruned. | Increase `deploy_keep` in config. Monitor disk space. |

### ⚠️ KEY ASSUMPTIONS & TRADE-OFFS

1. **`bootcount-limit=3` is a heuristic** — not mathematically derived.
   - Chrome OS: 3
   - Fedora Silverblue: 3 (via `grub2-set-bootflag boot_success=0` + `boot_indeterminate=3`)
   - SteamOS: 3 (custom `steamos-bootcount`)
   - **Rationale**: Transient failures are usually single-event. Correlated triple-failure implies systemic bug.

2. **`deploy_keep=3` default** — balances disk usage vs rollback depth.
   - Each deployment ~2-4 GiB (compressed Btrfs).
   - 3 deployments = 6-12 GiB + shared subvolumes.
   - Configurable via `arkdep.conf` or deploy script.

3. **Only THREE unconditionally shared subvolumes** — `home`, `root`, `flatpak`.
   - Everything else in `/var` and `/etc` is **per-deployment** (read-only, nested subvolume).
   - Persistence across updates **only** via explicit `migrate_files` allow-list.
   - This is arkdep's core design — no OverlayFS, no shared `/var` mount.

4. **No automatic "promote after 1 success"** — CI must explicitly promote.
   - Prevents "flaky pass" becoming permanent.
   - Human gate (`manual-release.yml`) is the final arbiter.

5. **Recovery entry is minimal** — busybox + btrfs + cryptsetup + curl + `reflashing.sh`.
   - Does NOT include desktop, browser, or GUI tools.
   - Purpose: Pull last-known-good UKI from GitHub Releases / repo-hosting, create NEW deployment, reboot.

6. **Secure Boot keys self-signed + MOK enrollment** — not Microsoft-signed shim.
   - User must run `mokutil --import MOK.crt` once.
   - If MOK not enrolled, UKI signature verification fails → boot fails → counts toward limit.

7. **systemd-boot counting is an ENHANCEMENT layered on arkdep** — see §(e).
   - arkdep alone: manual rollback only (user picks entry from menu).
   - With bootcount: automatic fallback after 3 failures per entry.
   - They compose cleanly: one loader entry per deployment, each with independent counter.

--------------------------------------------------------------------------------
(e) ARKDEP + SYSTEMD-BOOT COUNTING: EXPLICIT INTERACTION MODEL
--------------------------------------------------------------------------------

**Decision: YES, layer systemd-boot native boot-counting on top of arkdep.**

### Why This Composition Works

| Layer | Responsibility | Knows About Other Layer? |
|-------|----------------|--------------------------|
| **arkdep** | Deployment lifecycle: create subvolume, extract rootfs, run `migrate_files`, set ro=true, generate loader entry, prune old deployments | **No** — only ensures each deployment gets a loader entry with stable `id` |
| **systemd-boot** | Boot menu, per-entry boot counting, automatic fallback to next entry on 3 failures | **No** — only sees loader entries; treats each deployment entry as independent boot target |

### Interaction Rules (Must Be Enforced)

1. **One loader entry per kept deployment** — arkdep deploy script creates entry; prune script deletes entry.
2. **Stable `id` per deployment** — `arch-deploy-<deployment-id>` where deployment-id = subvolume name. Never changes for that deployment.
3. **Newest deployment = first in menu** — arkdep names entries so alphabetical sort = newest first (timestamp prefix).
4. **Boot counting applies per entry** — systemd-boot tracks `LoaderEntrySelected-<machine-id>-arch-deploy-<id>` independently.
5. **Automatic fallback = next entry in menu** — systemd-boot skips BAD entry, tries next (older deployment). This is **exactly** manual rollback automated.
6. **Recovery entry excluded from counting** — `arch-recovery` entry has no `bootcount` logic (not a primary OS). It never gets marked BAD.

### Failure Scenario Walkthrough

```
Deployments kept: [2024.01.20-newid] [2024.01.15-abc123] [2024.01.10-def456]
Menu order (newest first):
  1. Autonomous Arch OS (2024.01.20-newid)    ← bootcount=0
  2. Autonomous Arch OS (2024.01.15-abc123)   ← bootcount=0
  3. Autonomous Arch OS (2024.01.10-def456)   ← bootcount=0
  4. Autonomous Arch OS (Recovery)

Boot 1: User boots #1 (newest). Fails (kernel panic). Counter=1.
Boot 2: systemd-boot retries #1 (counter=1). Fails. Counter=2.
Boot 3: systemd-boot retries #1 (counter=2). Fails. Counter=3 → entry marked BAD.
Boot 4: systemd-boot SKIPS #1, boots #2 (2024.01.15-abc123). Counter=1 for #2.
        If #2 succeeds → counter reset to 0, #2 becomes active.
        If #2 fails 3× → marked BAD, tries #3.
```

### What This Does NOT Do

- **No cross-deployment health sharing** — each deployment's counter is independent. A bug in v20 doesn't affect v19's counter.
- **No "mark deployment bad permanently"** — systemd-boot only marks the *loader entry* bad for this boot session. On next reboot, counters reset (EFI vars persist but systemd-boot re-evaluates). If user manually selects a BAD entry, it boots again with counter=0.
- **No arkdep awareness of boot failures** — arkdep CLI (`arkdep list`, `arkdep healthcheck`) doesn't read EFI vars. Healthcheck is housekeeping only.

--------------------------------------------------------------------------------
(f) CORRECTED MKOSI.CONF SNIPPET (Signing + Immutability Notes)
--------------------------------------------------------------------------------

```ini
# image/mkosi.conf — relevant sections only
# SPDX-License-Identifier: MIT

[Distribution]
Distribution=arch
Release=latest

[Output]
Format=uki
Output=arch-{{VERSION_ID}}.efi
# UKI filename pattern: arch-<deployment-id>.efi (set at build time)

[Security]
# CORRECTED: Real mkosi SecureBoot option names (verified from mkosi man page/config.py)
SecureBoot=yes                    # Enable UEFI SecureBoot signing
SecureBootKey=/path/to/db.key     # Private key (PEM) — replaces "SbsignKey="
SecureBootCertificate=/path/to/db.crt  # Certificate (PEM) — replaces "SbsignCertificate="
SecureBootSignTool=sbsign         # or "pesign" — tool to sign the UKI
SecureBootAutoEnroll=no           # Do NOT auto-enroll MOK; user runs mokutil manually

# REMOVED: ReadOnly=yes — THIS KEY DOES NOT EXIST IN MKOSI
# Immutability is enforced POST-BUILD by deploy script:
#   btrfs property set -ts /arkdep/deployments/<id>/rootfs ro true
#   btrfs property set -ts /arkdep/deployments/<id>/rootfs/etc ro true
#   btrfs property set -ts /arkdep/deployments/<id>/rootfs/var ro true
# Applied AFTER migrate_files copy-in, BEFORE deployment is considered live.

[Initrd]
InitrdProfiles=default            # Confirmed real option
# Adds systemd, network, btrfs, cryptsetup modules to initrd

[Root]
# ReadOnly=yes  ← DOES NOT EXIST — removed
# mkosi builds a standard read-write rootfs; arkdep makes it read-only post-extract
```

> **Verified against mkosi source**: `ReadOnly=` does not exist in mkosi's config schema (config.py). The only `read_only` reference is an unrelated `ConsoleMode` enum value. Real immutability is applied by arkdep via `btrfs property set -ts <path> ro true` on the deployment's rootfs subvolume and its nested etc/var subvolumes — that's the deploy script's job, not mkosi's.

--------------------------------------------------------------------------------
(g) IMPLEMENTATION CHECKLIST
--------------------------------------------------------------------------------

| Component | File / Location | Status |
|-----------|-----------------|--------|
| `loader.conf` with bootcount | `/efi/loader/loader.conf` (via `mkosi.extra`) | ☐ |
| Deployment entry template | `scripts/deploy_entry.conf.tmpl` | ☐ |
| Recovery entry | `/efi/loader/entries/arch-recovery.conf` | ☐ |
| `systemd-boot-success.service` | Provided by systemd 250+ | ✅ |
| Stable `id` generation at deploy | `scripts/deploy_new_image.sh` → `arch-deploy-<id>` | ☐ |
| UKI build includes `id` in cmdline | `image/mkosi.conf` → `KernelCommandLine` | ☐ |
| Partition labels match cmdline | `partitions/layout.sfdisk` → `arch_root`, `arch_recovery` | ☐ |
| Btrfs subvolume tree at install (rootfs, then nested etc/var) | `scripts/install.sh` → `arkdep/{deployments,shared/{home,root,flatpak}}` | ☐ |
| `migrate_files.sh` with allow-list (rootfs-relative paths) | `scripts/migrate_files.sh` | ☐ |
| Deploy script (create nested, migrate, ro nested order, entry, prune) | `scripts/deploy_new_image.sh` | ☐ |
| Prune logic deletes nested subvolumes before parent | `scripts/deploy_new_image.sh` | ☐ |
| Recovery UKI build | `recovery/recovery-rootfs/` | ☐ |
| `reflashing.sh` creates NEW deployment (nested layout) | `recovery/reflashing.sh` | ☐ |
| Corrected `mkosi.conf` signing section | `image/mkosi.conf` | ☐ |

--------------------------------------------------------------------------------
END OF REVISED DOCUMENT 1 (v2)
================================================================================

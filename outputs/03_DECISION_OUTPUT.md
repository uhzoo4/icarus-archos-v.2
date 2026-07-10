================================================================================
A/B PARTITION & ROLLBACK ARCHITECTURE
================================================================================

--------------------------------------------------------------------------------
(a) STATE DIAGRAM — BOOT SLOT LIFECYCLE
--------------------------------------------------------------------------------

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BOOT SLOT STATE MACHINE                           │
└─────────────────────────────────────────────────────────────────────────────┘

    ┌──────────────┐         ┌──────────────┐         ┌──────────────┐
    │   SLOT A     │         │   SLOT B     │         │  RECOVERY    │
    │  (ACTIVE)    │         │  (STANDBY)   │         │  (FALLBACK)  │
    └──────┬───────┘         └──────┬───────┘         └──────┬───────┘
           │                        │                        │
           │  bootcount=0           │  bootcount=0           │  bootcount=0
           │  (healthy)             │  (untested)            │  (manual only)
           ▼                        ▼                        ▼
    ┌──────────────────────────────────────────────────────────────────────┐
    │                        BOOT ATTEMPT (systemd-boot)                   │
    │  1. Read loader.conf: bootcount=yes, bootcount-limit=3              │
    │  2. Select entry per 'default' / 'next' / menu selection            │
    │  3. Increment EFI var: LoaderEntrySelected-<machine-id>-<entry-id>  │
    │  4. Launch UKI (kernel + initrd + cmdline)                          │
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
    │ → marks slot HEALTHY    │    │ If counter < 3:         │
    │ → clears 'next' entry   │    │   → reboot, retry SAME  │
    └───────────┬─────────────┘    │   → user sees menu      │
                │                  │ If counter == 3:        │
                │                  │   → entry marked BAD    │
                │                  │   → systemd-boot skips  │
                │                  │   → tries NEXT entry    │
                │                  └───────────┬─────────────┘
                │                              │
                │                              ▼
                │                     ┌─────────────────────────┐
                │                     │ FALLBACK TO OTHER SLOT  │
                │                     │ (automatic on 3rd fail) │
                │                     │                         │
                │                     │ Slot B becomes ACTIVE   │
                │                     │ Slot A marked STALE     │
                │                     │ bootcount reset to 0    │
                │                     └───────────┬─────────────┘
                │                                 │
                └─────────────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │   STEADY STATE          │
                    │   One slot ACTIVE       │
                    │   One slot STANDBY      │
                    │   (or RECOVERY if both  │
                    │    exhausted)           │
                    └─────────────────────────┘


UPDATE TRANSITION (initiated from RUNNING OS):
┌─────────────────────────────────────────────────────────────────────────────┐
│  CURRENT STATE: Slot A = ACTIVE (bootcount=0), Slot B = STANDBY            │
└─────────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. CI builds new UKI → writes to /efi/EFI/Linux/arch-<ver>-B.efi          │
│     (targets INACTIVE slot B partition)                                     │
│  2. Update loader entry for Slot B:                                         │
│     - linux /EFI/Linux/arch-<ver>-B.efi                                     │
│     - options root=LABEL=arch_root_b ...                                    │
│  3. Set 'next' boot to Slot B entry (efibootmgr --bootnext)                │
│  4. Reboot                                                                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  BOOT SEQUENCE ON SLOT B (first attempt, bootcount=1):                     │
│  - If SUCCESS (reaches graphical.target):                                   │
│      → systemd-boot-success resets counter                                  │
│      → Slot B promoted to ACTIVE                                            │
│      → Slot A becomes STANDBY                                               │
│      → CI promotes build to stable repo                                     │
│  - If FAILURE (3 consecutive):                                              │
│      → Slot B marked BAD                                                    │
│      → Falls back to Slot A (still ACTIVE)                                  │
│      → CI marks build FAILED, no promotion                                  │
└─────────────────────────────────────────────────────────────────────────────┘


MANUAL ROLLBACK (from BOOT MENU, no OS required):
┌─────────────────────────────────────────────────────────────────────────────┐
│  User at systemd-boot menu (10s timeout):                                   │
│  1. Select "Autonomous Arch OS (Slot A)" or "Slot B"                       │
│  2. Boot proceeds on SELECTED slot                                          │
│  3. If that slot boots → becomes ACTIVE                                     │
│  4. If that slot fails 3× → falls back to other slot                        │
│  5. Recovery entry always available as last resort                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

--------------------------------------------------------------------------------
(b) SYSTEMD-BOOT BOOT COUNTING CONFIGURATION
--------------------------------------------------------------------------------

**Systemd Version**: Boot counting introduced in **systemd 250** (released 2023-03-07).  
**Mechanism**: Native EFI variable counters per boot entry — **not** a userspace watchdog.

### 1. `/efi/loader/loader.conf` (Global)

```ini
# /efi/loader/loader.conf
# SPDX-License-Identifier: MIT

# Enable boot attempt counting per entry
bootcount=yes

# Maximum consecutive failures before entry is skipped (default: 3)
# JUSTIFICATION FOR 3:
# - 1: Too fragile — transient hardware glitch (cosmic ray, thermal throttle)
#      or first-boot service race would trigger fallback unnecessarily
# - 2: Better, but still vulnerable to correlated transient failures
# - 3: Industry standard (Chrome OS, Fedora Silverblue, SteamOS all use 3)
#      Balances "fail fast" vs "don't flip on fluke"
# - >3: Delays recovery, user sees broken boot longer
bootcount-limit=3

# Show menu for 10s — allows manual rollback selection
timeout=10

# No default entry — use 'saved' behavior via efibootmgr --bootnext
# On first boot, systemd-boot picks first entry alphabetically
default=

# Console mode for consistent rendering
console-mode=keep

# Editor=1 allows 'e' to edit kernel cmdline at boot (recovery aid)
editor=yes

# Auto-firmware=1 enables fwupd UEFI capsule updates via boot menu
auto-firmware=yes
```

### 2. Boot Entries — `/efi/loader/entries/arch-<slot>.conf`

**Slot A Entry** (`arch-a.conf`):
```ini
# /efi/loader/entries/arch-a.conf
title   Autonomous Arch OS (Slot A)
version <IMAGE_VERSION_A>
linux   /EFI/Linux/arch-<IMAGE_VERSION_A>.efi
options root=LABEL=arch_root_a rootflags=subvol=@ rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0
# Unique ID for boot counting — MUST be stable across rebuilds
# Format: <distro>-<slot>-<static-uuid>
# Generate once at install: uuidgen → store in /etc/machine-id-arch-a
id      arch-a-<STATIC_UUID_A>
```

**Slot B Entry** (`arch-b.conf`):
```ini
# /efi/loader/entries/arch-b.conf
title   Autonomous Arch OS (Slot B)
version <IMAGE_VERSION_B>
linux   /EFI/Linux/arch-<IMAGE_VERSION_B>.efi
options root=LABEL=arch_root_b rootflags=subvol=@ rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0
id      arch-b-<STATIC_UUID_B>
```

**Recovery Entry** (`arch-recovery.conf`):
```ini
# /efi/loader/entries/arch-recovery.conf
title   Autonomous Arch OS (Recovery)
version recovery
linux   /EFI/Linux/arch-recovery.efi
options root=LABEL=arch_root_a rootflags=subvol=@ rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0 systemd.unit=emergency.target
id      arch-recovery-<STATIC_UUID_RECOVERY>
```

> **Critical**: The `id` field **must be stable** across image rebuilds.  
> If `id` changes, boot counting resets (new EFI variable).  
> Generate once at install time, store in `/etc/machine-id-arch-{a,b,recovery}`, bake into UKI via `mkosi.extra/etc/machine-id-arch-*`.

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

### 4. Update Flow — Setting `next` Boot (from Running OS)

```bash
# scripts/promote_to_stable.sh (runs on ACTIVE slot after validation)
#!/usr/bin/env bash
set -euo pipefail

# Determine INACTIVE slot
CURRENT_ROOT=$(findmnt -no SOURCE / | sed 's/\[.*//')
if [[ "$CURRENT_ROOT" == *root_a* ]]; then
    NEXT_SLOT="arch-b-<STATIC_UUID_B>"
    NEXT_LABEL="arch_root_b"
else
    NEXT_SLOT="arch-a-<STATIC_UUID_A>"
    NEXT_LABEL="arch_root_a"
fi

# Set next boot to INACTIVE slot (one-shot)
efibootmgr --bootnext "$(efibootmgr | grep "$NEXT_SLOT" | sed 's/^Boot\([0-9]*\).*/\1/')"

# Optional: set default to inactive slot for subsequent boots
# efibootmgr --bootorder "$(efibootmgr | grep "$NEXT_SLOT" | sed 's/^Boot\([0-9]*\).*/\1/'),..."

# Reboot to test new slot
systemctl reboot
```

### 5. Partition Layout — `partitions/layout.sfdisk`

```sfdisk
label: gpt
unit: sectors

# 1. ESP — 1 GiB (shared, holds ALL UKIs + loader entries)
/dev/disk/by-partlabel/esp : start=2048, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"

# 2. Root A — 50 GiB (Btrfs, labeled arch_root_a)
/dev/disk/by-partlabel/root_a : size=104857600, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root_a"

# 3. Root B — 50 GiB (Btrfs, labeled arch_root_b)
/dev/disk/by-partlabel/root_b : size=104857600, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root_b"

# 4. Var — remaining (Btrfs, shared, labeled arch_var)
/dev/disk/by-partlabel/var : type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="var"

# 5. Home — optional separate, or subvolume under var
# /dev/disk/by-partlabel/home : type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="home"
```

**Btrfs Subvolumes** (created at install, persist across swaps):
```
@_a          ← rootfs for Slot A (read-only when active)
@_b          ← rootfs for Slot B (read-only when active)
@var         ← /var (persistent, shared)
  ├─ overlay/etc/upper   ← OverlayFS upper for /etc
  ├─ overlay/etc/work    ← OverlayFS work dir
  ├─ lib/flatpak         ← System Flatpaks
  ├─ lib/NetworkManager  ← Network state
  └─ ...
@home        ← /home (persistent, user data only)
@snapshots   ← Optional: timeshift/btrfs snapshots
```

**Kernel Command Line** (baked into each UKI):
```
# Slot A UKI
root=LABEL=arch_root_a rootflags=subvol=@_a rw quiet ...

# Slot B UKI
root=LABEL=arch_root_b rootflags=subvol=@_b rw quiet ...
```

--------------------------------------------------------------------------------
(c) GUARANTEES & NON-GUARANTEES — PLAIN LANGUAGE
--------------------------------------------------------------------------------

### ✅ WHAT THIS DESIGN PROTECTS AGAINST

| Threat | Protection Mechanism |
|--------|---------------------|
| **Bad OS update breaks boot** | New image written to **inactive** slot only. Active slot untouched. If new slot fails 3×, systemd-boot **automatically falls back** to known-good slot. |
| **Kernel panic / initrd failure / driver regression** | Boot counting catches any failure before `graphical.target`. 3 strikes → fallback. |
| **User forced to fix via live USB** | **Manual rollback from boot menu** — press arrow keys at 10s timeout, select other slot. Works even if active slot doesn't reach login. |
| **Bitrot / silent corruption on inactive slot** | Inactive slot verified on **next boot attempt** (not at write time). Corruption detected before it becomes active. |
| **Bootloader config corruption** | `loader.conf` and entries on **shared ESP** — single source of truth. Both slots reference same ESP. |
| **Power loss during update** | Update writes to **inactive** partition only. Active partition never modified mid-write. |
| **Firmware/UEFI variable loss** | Boot counting uses EFI vars, but fallback logic is in **systemd-boot binary** — if vars lost, counters reset to 0 (safe default). |

### ❌ WHAT THIS DESIGN DOES **NOT** PROTECT AGAINST

| Threat | Why Not Protected | Mitigation (Out of Scope) |
|--------|-------------------|---------------------------|
| **Silent data corruption in `/home`** | `/home` is **shared** (single `@home` subvolume). Both slots mount same `/home`. A bug that corrupts user files affects both slots. | **User responsibility**: Backups (borg, restic, timeshift on `@home`), RAID/ZFS on separate disk, cloud sync. |
| **Silent data corruption in `/var`** | `/var` is **shared** (`@var` subvolume). Flatpak data, NetworkManager state, logs, caches — all shared. | Same as above. Critical state (SSH keys, machine-id) migrated via `migrate-config.sh` but not versioned. |
| **Malicious/buggy config in `/etc` that survives rollback** | `/etc` uses **OverlayFS** (lower=image, upper=`/var/overlay/etc`). Upper dir persists across swaps. A bad config written to upper dir **survives rollback**. | `migrate-config.sh` only copies **missing** files. Does not overwrite. Admin must manually clean `/var/overlay/etc/upper`. |
| **Hardware failure (disk death, RAM, CPU)** | Single disk = single point of failure. A/B partitions on same device. | **Out of scope**: Use separate physical disks, RAID, or cloud backup. |
| **Firmware/BIOS boot order corruption** | systemd-boot entries stored in ESP. If UEFI vars wiped, boot order lost but entries remain. | `efibootmgr` backup/restore, or UEFI shell `bcfg` dump. |
| **Evil maid / physical attacker** | No full-disk encryption in this design (LUKS optional but not mandated). | Add LUKS2 + TPM2 + PCR binding (future work). |
| **Kernel exploit persisting in memory** | Reboot clears RAM. But if exploit writes to `/var` or `/home`, persists. | Immutable `/usr` + signed UKI + Secure Boot raises bar. |
| **Supply chain compromise (upstream Arch package)** | Packages pulled from Arch Linux Archive at build time. No runtime verification beyond sbctl. | Reproducible builds, sigstore/cosign on custom packages (future work). |
| **Boot counting false positive (3 transient fails)** | Cosmic ray, thermal throttle, marginal RAM could cause 3 fails → fallback to **also-broken** slot if both have same bug. | Probability extremely low. Hardware health monitoring (smartd, mcelog) recommended. |

### ⚠️ KEY ASSUMPTIONS & TRADE-OFFS

1. **`bootcount-limit=3` is a heuristic** — not mathematically derived.  
   - Chrome OS: 3  
   - Fedora Silverblue: 3 (via `grub2-set-bootflag boot_success=0` + `boot_indeterminate=3`)  
   - SteamOS: 3 (custom `steamos-bootcount`)  
   - **Rationale**: Transient failures are usually single-event. Correlated triple-failure implies systemic bug.

2. **Shared `/var` and `/home` are intentional** — enables Flatpak, user data, network state persistence.  
   - Cost: Config drift in `/etc` upper dir, no per-slot `/var` snapshots.  
   - Alternative (per-slot `/var`): Doubles disk usage, breaks Flatpak deduplication, complicates migration.

3. **No automatic "promote after 1 success"** — CI must explicitly promote.  
   - Prevents "flaky pass" becoming permanent.  
   - Human gate (`manual-release.yml`) is the final arbiter.

4. **Recovery entry is minimal** — busybox + btrfs + cryptsetup + curl + `reflashing.sh`.  
   - Does NOT include desktop, browser, or GUI tools.  
   - Purpose: Pull last-known-good UKI from GitHub Releases / repo-hosting, write to broken slot, reboot.

5. **Secure Boot keys self-signed + MOK enrollment** — not Microsoft-signed shim.  
   - User must run `mokutil --import MOK.crt` once.  
   - If MOK not enrolled, UKI signature verification fails → boot fails → counts toward limit.

--------------------------------------------------------------------------------
IMPLEMENTATION CHECKLIST (FROM STATE DIAGRAM)
--------------------------------------------------------------------------------

| Component | File / Location | Status |
|-----------|-----------------|--------|
| `loader.conf` with bootcount | `/efi/loader/loader.conf` (via `mkosi.extra`) | ☐ |
| Slot A entry (stable `id`) | `/efi/loader/entries/arch-a.conf` | ☐ |
| Slot B entry (stable `id`) | `/efi/loader/entries/arch-b.conf` | ☐ |
| Recovery entry | `/efi/loader/entries/arch-recovery.conf` | ☐ |
| `systemd-boot-success.service` | Provided by systemd 250+ | ✅ |
| Stable `id` generation at install | `scripts/install.sh` → `/etc/machine-id-arch-*` | ☐ |
| UKI build includes `id` in cmdline | `image/mkosi.conf` → `KernelCommandLine` | ☐ |
| Update script sets `--bootnext` | `scripts/promote_to_stable.sh` | ☐ |
| Partition labels match cmdline | `partitions/layout.sfdisk` → `arch_root_a/b` | ☐ |
| Btrfs subvolumes `@_a`, `@_b` | `scripts/build_image.sh` + `mkosi.postinst` | ☐ |
| OverlayFS `/etc` upper in `@var` | `image/mkosi.extra/etc/fstab.overlay` | ☐ |
| `migrate-config.sh` for `/etc` drift | `repository/packages/system-hooks/` | ☐ |
| Recovery UKI build | `recovery/recovery-rootfs/` | ☐ |
| `reflashing.sh` pulls from stable | `recovery/reflashing.sh` | ☐ |

--------------------------------------------------------------------------------
END OF ARCHITECTURE
================================================================================
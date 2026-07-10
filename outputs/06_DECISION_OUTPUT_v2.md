================================================================================
REVISED DOCUMENT 2 (v2) — Recovery Environment Design
================================================================================

> **⚠ TWO NOTES BEFORE READING**
> 1. **Same correction as Document 1**: `etc` and `var` are nested INSIDE
>    each deployment's `rootfs` subvolume, not siblings of it (verified
>    against arkdep's `btrfs send $workdir/etc`/`var` + matching
>    `btrfs receive .../rootfs/` calls). §6's `reflash.sh` created them as
>    siblings — corrected below. Everything else in this document was
>    already internally consistent with the nested model (its own
>    "find newest bootable deployment" check in §6 step 3 already looked
>    for `rootfs/etc/os-release`, which only makes sense under the nested
>    layout — so this was a one-spot inconsistency within Nemotron's own
>    output, not a wholesale misunderstanding).
> 2. **Nemotron's output was cut off** at the very end of §8's integration
>    checklist table (mid-row, "mount-home script | `recovery/mkosi.extra/
>    usr/bin/m..."). That table is a low-stakes tracking checklist, not
>    core design — reconstructed the missing rows below from the scripts
>    actually specified earlier in this same document (§7's `mount-home`,
>    §6's `reflash.sh`/`migrate_files.sh`), so nothing is invented that
>    isn't already fully specified elsewhere in this document. If you want
>    Nemotron's own exact wording for those last rows instead, send this
>    document back and ask it to regenerate just §8.

> **Cross-references to Document 1**:
> - Partition label: `arch_root` (single root partition, Document 1 §b)
> - Deployment path scheme: `/arkdep/deployments/<id>/rootfs`, with `etc`
>   and `var` NESTED inside `rootfs` (Document 1 §b)
> - `migrate_files` allow-list: Document 1 §c (arkdep default + project extensions)
> - Boot entry `id` format: `arch-deploy-<deployment-id>` (Document 1 §c)
> - `deploy_keep=3` default (Document 1 §d)
> - Recovery partition: `arch_recovery` (Document 1 §b, preserved from original Doc 2)

---

## 1. PHYSICAL PLACEMENT: DEDICATED RECOVERY PARTITION (UNCHANGED)

### Decision: **Yes, a small dedicated partition baked at install time.**

### Justification (unchanged from original — this part was correct)

| Alternative | Why Rejected |
|-------------|--------------|
| **USB stick required** | User in crisis may not have one; adds friction to recovery; defeats "self-contained" promise |
| **Second ESP partition** | ESP is for bootloaders only; firmware may not boot arbitrary UKIs from non-standard ESPs; 1 GiB ESP already allocated |
| **Hidden in `@var` subvolume** | Requires mounting Btrfs first — chicken/egg if root is corrupted; recovery must work when *nothing* mounts |
| **Embedded in firmware (UEFI capsule)** | Not portable across hardware; requires vendor tooling; no standard for "recovery UKI" |

### Partition Specification (from Document 1 §b)

```sfdisk
# partitions/layout.sfdisk — recovery entry (already in Document 1)
# 3. Recovery — 512 MiB (fixed, never resized)
/dev/disk/by-partlabel/recovery : size=1048576, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="recovery"
```

**Filesystem**: **ext4** (not Btrfs) — simpler, no subvolume complexity, readable by any Linux kernel 3.0+, GRUB, systemd-boot, Windows WSL, macOS fuse-ext2.

**Label**: `arch_recovery` (for `root=LABEL=arch_recovery`)

**Mount point in recovery UKI**: `/` (the recovery rootfs *is* this partition)

**Size rationale**: 512 MiB fits:
- Kernel + initrd (UKI) ~25 MB
- BusyBox + essential binaries ~15 MB
- `btrfs-progs`, `cryptsetup`, `curl`, `ca-certificates` ~40 MB
- Network firmware blobs (if needed) ~20 MB
- **Headroom**: ~400 MB for future driver updates, logs, temporary downloads

---

## 2. MINIMUM CAPABILITIES (AND ONLY THESE)

### 2.1 Core Functions (Updated for arkdep deployment model)

| Function | Implementation |
|----------|----------------|
| **Create new deployment from stable image** | `reflash.sh` — downloads latest `arch-<version>.efi` + `.sig` from `https://repo.your-domain.org/custom-stable/`, verifies GPG + UKI signature, creates **new deployment subvolume** under `/arkdep/deployments/<new-id>/rootfs` (with `etc`/`var` nested inside it), extracts rootfs, runs `migrate_files` from **newest bootable deployment's rootfs**, sets ro=true (nested order), creates loader entry, sets `--bootnext`, reboots |
| **Mount & inspect `/home`** | Auto-detects `arkdep/shared/home` subvolume on `LABEL=arch_root`, mounts read-only at `/mnt/home`, drops to shell with `HOME=/mnt/home/<user>` hint |
| **Basic shell** | BusyBox `ash` + `bash` (static) — `ls`, `cp`, `mv`, `cat`, `grep`, `find`, `mount`, `umount`, `btrfs`, `cryptsetup`, `curl`, `gpg`, `efibootmgr`, `sbctl` |

### 2.2 Explicit Non-Goals (Unchanged)

| Excluded | Reason |
|----------|--------|
| **Custom desktop environment** | Recovery is CLI-only; GUI adds 200+ MB, driver dependencies, attack surface |
| **Automated healing / AI triage** | That logic lives in the *primary* OS; recovery must work when primary is gone |
| **Package installation (`pacman`)** | No package database, no repo access without network + keys; use `curl` + static binaries |
| **Full systemd** | `systemd` in initrd is heavy; BusyBox `init` + `systemd` only for `systemd-boot` interaction if needed |
| **NetworkManager** | `systemd-networkd` + `wpa_supplicant` (static) or `dhcpcd` — simpler, fewer deps |
| **Flatpak / Distrobox** | Irrelevant for recovery; user data is in `/home`, not containers |
| **Telemetry / crash reporting** | No outbound calls except explicit `reflash.sh` download |
| **Secure Boot enrollment** | MOK enrollment requires reboot into firmware UI; recovery assumes MOK already enrolled |

### 2.3 Package List (Target: < 100 MB installed) — Unchanged

```
Base:
  busybox (static, provides ash, ls, cp, mv, cat, grep, find, mount, umount, dd, tar, gzip, wget)
  bash (static) — for reflash.sh script compatibility
  linux (kernel only, no firmware — see below)
  linux-firmware (MINIMAL: only wifi/ethernet needed for target hardware)

Crypto/FS:
  cryptsetup (static, LUKS2)
  btrfs-progs (static, btrfs receive/send, subvolume list, mount)
  e2fsprogs (ext4 for recovery partition itself)

Network:
  curl (with TLS, static linked if possible)
  ca-certificates
  dhcpcd (or systemd-networkd minimal)
  wpa_supplicant (if wifi needed)

Boot/UEFI:
  efibootmgr
  sbctl (for verifying UKI signatures before write)
  gpg (for verifying repo signatures)

Utils:
  jq (JSON parsing for repo index)
  less, vim (minimal editors)
```

> **Build method**: `mkosi` with `Format=uki`, `Packages=` list above.
> **CORRECTED**: no `ReadOnly=yes` — that key doesn't exist in mkosi. `RemoveFiles=` aggressive. Output: `arch-recovery.efi` placed on ESP at `/EFI/Linux/arch-recovery.efi`.

---

## 3. RECOVERY UKI STRUCTURE (Unchanged from original — correct)

### 3.1 Kernel Command Line (Baked In)

```
root=LABEL=arch_recovery rootflags=rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0 init=/usr/lib/systemd/systemd
```

> **Note**: Uses `systemd` as init (not BusyBox `init`) because:
> - `systemd` in initrd is supported and tested
> - Needed for `systemd-networkd`, `systemd-resolved` if used
> - `systemd-boot` interaction (efi vars) works reliably
> - Still minimal: ~2 MB vs BusyBox 1 MB — acceptable trade

### 3.2 Initrd Contents (mkosi `InitrdProfiles=default` + custom)

```
/usr/lib/modules/<kernel>/
  kernel/fs/btrfs/btrfs.ko
  kernel/fs/ext4/ext4.ko
  kernel/drivers/md/dm-mod.ko
  kernel/drivers/md/dm-crypt.ko
  kernel/crypto/xts.ko
  kernel/crypto/aes.ko
  kernel/drivers/net/ethernet/... (target NIC)
  kernel/drivers/net/wireless/... (target WiFi)
/usr/bin/  ← busybox symlinks + bash + curl + btrfs + cryptsetup + efibootmgr + sbctl + gpg + jq
/etc/
  os-release (ID=arch-recovery)
  systemd/network/20-wired.network (DHCP)
  systemd/network/25-wireless.network (wpa_supplicant@.service)
  wpa_supplicant/wpa_supplicant.conf (empty, user edits)
  sbctl/keys/db.crt (public key for verifying UKI signatures)
  pacman.d/gnupg/ (trusted keys for repo verification)
/usr/lib/systemd/system/
  systemd-networkd.service
  systemd-resolved.service
  wpa_supplicant@.service
  reflash.service (oneshot, ConditionKernelCommandLine=reflash=auto)
```

### 3.3 First-Boot Flow (Unchanged)

```
1. UKI boots → systemd starts
2. systemd-networkd brings up DHCP (wired) or waits for wpa_supplicant (wifi)
3. If kernel param `reflash=auto` present:
     → runs /usr/lib/systemd/scripts/reflash.sh (non-interactive, pulls latest stable)
   Else:
     → drops to emergency shell (ash) with banner:
        "Autonomous Arch OS Recovery
         Commands: reflash.sh, mount-home, shell
         Type 'help' for usage."
```

---

## 4. UPDATE STRATEGY: DECOUPLED FROM NIGHTLY PIPELINE (Unchanged)

### 4.1 When Recovery Needs Update (Unchanged)

| Trigger | Example |
|---------|---------|
| New hardware support needed | New WiFi chipset, NVMe controller, GPU firmware for display in recovery |
| Crypto/library vulnerability | `curl` CVE, `openssl` CVE, `btrfs-progs` bug |
| Boot protocol change | systemd-boot entry format change, UKI spec update |
| Stable repo URL / key rotation | New GPG key, new CDN endpoint |

**Frequency target**: **≤ 2× per year** (not nightly, not monthly).

### 4.2 Update Process (Manual, Documented in RUNBOOK) — Unchanged

```bash
# On build machine (your laptop), NOT in CI:
cd autonomous-arch-os/recovery/recovery-rootfs

# 1. Update package list if needed (edit packages.list)
# 2. Bump version tag
echo "2024.06.15" > VERSION

# 3. Build locally (requires KVM, root)
sudo mkosi -f recovery/mkosi.conf -o recovery/output

# 4. Sign with your MOK key (local, air-gapped preferred)
./image/secure-boot/sign_uki.sh recovery/output/arch-recovery-2024.06.15.efi

# 5. Test in QEMU
./scripts/test_boot.sh recovery/output/arch-recovery-2024.06.15.efi

# 6. Copy to repo-hosting/custom-stable/recovery/
cp recovery/output/arch-recovery-2024.06.15.efi ../repo-hosting/custom-stable/recovery/
cp recovery/output/arch-recovery-2024.06.15.efi.sig ../repo-hosting/custom-stable/recovery/

# 7. Update recovery index (simple JSON)
cat > ../repo-hosting/custom-stable/recovery/index.json <<EOF
{
  "latest": "2024.06.15",
  "url": "https://repo.your-domain.org/custom-stable/recovery/arch-recovery-2024.06.15.efi",
  "sig_url": "https://repo.your-domain.org/custom-stable/recovery/arch-recovery-2024.06.15.efi.sig",
  "sha256": "$(sha256sum recovery/output/arch-recovery-2024.06.15.efi | cut -d' ' -f1)"
}
EOF

# 8. Deploy to production (rsync to VPS, or GitHub Release)
# 9. Document in docs/DECISIONS.md: "Recovery updated to 2024.06.15 — reason: <why>"
```

### 4.3 How Clients Get the Update (Unchanged)

- **New installs**: Recovery partition written by installer with latest `arch-recovery.efi` at install time.
- **Existing installs**: **No automatic update.** User must manually re-flash recovery partition if they want it (documented in RUNBOOK: "If recovery environment fails to connect/download, boot live USB and re-run installer's 'update recovery' option").
- **Why not auto-update?** Recovery partition is *the last resort*. If auto-update breaks it, you have *no* fallback. Manual update = you tested it.

---

## 5. SYSTEMD-BOOT ENTRY CONFIGURATION (Updated for deployment model)

### 5.1 Loader Entry: `/efi/loader/entries/arch-recovery.conf`

```ini
# /efi/loader/entries/arch-recovery.conf
# SPDX-License-Identifier: MIT
# Generated at install time by scripts/install.sh
# DO NOT EDIT MANUALLY — regenerate via 'recovery-update-bootentry'

title   Autonomous Arch OS (Recovery)
version recovery-2024.06.15
linux   /EFI/Linux/arch-recovery.efi
options root=LABEL=arch_recovery rootflags=rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0
id      arch-recovery-<STATIC_UUID_RECOVERY>
```

### 5.2 Critical Fields Explained (Unchanged)

| Field | Value | Why |
|-------|-------|-----|
| `title` | `Autonomous Arch OS (Recovery)` | Clear label in boot menu — user sees this at 10s timeout |
| `version` | `recovery-<DATE>` | Human-readable; matches `VERSION` file in recovery build |
| `linux` | `/EFI/Linux/arch-recovery.efi` | **Fixed filename** — always this name on ESP. New version overwrites. |
| `options` | `root=LABEL=arch_recovery ...` | Boots from dedicated recovery partition, not deployment roots |
| `id` | `arch-recovery-<STATIC_UUID>` | **Stable across rebuilds** — generated once at install (`uuidgen`), stored in `/etc/machine-id-arch-recovery`, baked into UKI via `mkosi.extra/etc/machine-id-arch-recovery` |

### 5.3 Boot Menu Behavior (shows deployments, not fixed slots)

```
┌─────────────────────────────────────────────────────────────────┐
│                    systemd-boot menu (10s timeout)              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ▸ Autonomous Arch OS (2024.01.20-newid)    [newest]          │
│     Autonomous Arch OS (2024.01.15-abc123)   [previous]        │
│     Autonomous Arch OS (2024.01.10-def456)   [older]           │
│     Autonomous Arch OS (Recovery)            [recovery-2024.06.15] │
│                                                                 │
│   Press Enter to boot default, 'e' to edit, 'c' for command    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

- Recovery entry **always visible** (not hidden by `bootcount` logic)
- Recovery entry **never marked BAD** by boot counting (it's not a primary OS)
- User can always arrow-down → Enter to reach recovery
- **Number of deployment entries = `deploy_keep` (default 3)**, not a fixed count of slots

---

## 6. REFLASH.SH SPECIFICATION (arkdep model, nesting corrected)

```bash
#!/usr/bin/env bash
# /usr/lib/systemd/scripts/reflash.sh
# Runs in recovery environment — downloads & creates NEW deployment from known-good UKI
# CORRECTED: subvolume creation and property-set calls now nest etc/var
# INSIDE the rootfs subvolume, matching Document 1's fix. The "find newest
# bootable deployment" check below was already written against the nested
# layout (it looks for rootfs/etc/os-release) — that part needed no change.

set -euo pipefail

REPO_BASE="https://repo.your-domain.org/custom-stable"
RECOVERY_INDEX_URL="${REPO_BASE}/recovery/index.json"

# 1. Fetch index
echo "Fetching recovery index..."
INDEX_JSON=$(curl -fsSL --max-time 30 "$RECOVERY_INDEX_URL")
LATEST_VERSION=$(echo "$INDEX_JSON" | jq -r '.latest')
UKI_URL=$(echo "$INDEX_JSON" | jq -r '.url')
SIG_URL=$(echo "$INDEX_JSON" | jq -r '.sig_url')
EXPECTED_SHA256=$(echo "$INDEX_JSON" | jq -r '.sha256')

# 2. Mount the ROOT partition (arch_root) to access arkdep structure
echo "Mounting root partition (arch_root)..."
mkdir -p /mnt/root
mount -L arch_root -o subvol=/ /mnt/root

# 3. Determine the NEWEST BOOTABLE deployment to migrate from
#    (already written against the nested layout — no change needed here)
echo "Finding newest bootable deployment to migrate from..."
DEPLOYMENTS_DIR="/mnt/root/arkdep/deployments"
SOURCE_DEPLOY=""

for deploy in $(ls -1r "$DEPLOYMENTS_DIR"); do
    if [[ -d "$DEPLOYMENTS_DIR/$deploy/rootfs" && -f "$DEPLOYMENTS_DIR/$deploy/rootfs/etc/os-release" ]]; then
        SOURCE_DEPLOY="$deploy"
        echo "Found source deployment: $SOURCE_DEPLOY"
        break
    fi
done

if [[ -z "$SOURCE_DEPLOY" ]]; then
    echo "ERROR: No valid deployment found to migrate from!" >&2
    echo "Cannot create new deployment without a source for migrate_files." >&2
    exit 1
fi

# 4. Generate NEW deployment ID (timestamp + short hash)
NEW_DEPLOY_ID="$(date -u +%Y.%m.%d)-$(head -c6 /dev/urandom | xxd -p)"
NEW_ROOTFS="$DEPLOYMENTS_DIR/$NEW_DEPLOY_ID/rootfs"
SOURCE_ROOTFS="$DEPLOYMENTS_DIR/$SOURCE_DEPLOY/rootfs"
echo "Creating new deployment: $NEW_DEPLOY_ID"

# 5. Create new deployment subvolume, then nest etc/var INSIDE it
#    CORRECTED: previously created etc/var as siblings of rootfs
btrfs subvolume create "$NEW_ROOTFS"
btrfs subvolume create "$NEW_ROOTFS/etc"
btrfs subvolume create "$NEW_ROOTFS/var"

# 6. Download UKI + signature
echo "Downloading UKI: $UKI_URL"
curl -fsSL --max-time 120 -o /tmp/arch-latest.efi "$UKI_URL"
curl -fsSL --max-time 30 -o /tmp/arch-latest.efi.sig "$SIG_URL"

# 7. Verify signature (GPG key baked in recovery)
echo "Verifying GPG signature..."
gpgv --keyring /etc/pacman.d/gnupg/pubring.gpg /tmp/arch-latest.efi.sig /tmp/arch-latest.efi

# 8. Verify SHA256
echo "Verifying SHA256..."
ACTUAL_SHA256=$(sha256sum /tmp/arch-latest.efi | cut -d' ' -f1)
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || { echo "SHA256 mismatch!"; exit 1; }

# 9. Verify UKI signature (sbctl) — proves it was signed by YOUR MOK key
echo "Verifying UKI signature..."
sbverify --cert /etc/sbctl/keys/db.crt /tmp/arch-latest.efi

# 10. Extract rootfs from UKI into new deployment
#     (content destined for /etc and /var lands inside the nested
#     subvolumes created in step 5, since those paths already ARE
#     separate subvolumes by the time this extraction runs)
echo "Extracting rootfs into new deployment..."
ROOTFS_URL="${UKI_URL%.efi}.tar.zst"
curl -fsSL --max-time 120 -o /tmp/rootfs.tar.zst "$ROOTFS_URL"
tar -C "$NEW_ROOTFS" -xpf /tmp/rootfs.tar.zst

# 11. Run migrate_files from SOURCE deployment's rootfs → NEW deployment's rootfs
#     Uses the SAME allow-list as the main deploy script (Document 1 §c)
echo "Migrating curated files from $SOURCE_DEPLOY → $NEW_DEPLOY_ID..."
/usr/lib/systemd/scripts/migrate_files.sh "$SOURCE_ROOTFS" "$NEW_ROOTFS"

# 12. Set new deployment read-only (nested order: etc/var first, then rootfs)
echo "Setting new deployment read-only..."
btrfs property set -ts "$NEW_ROOTFS/etc" ro true
btrfs property set -ts "$NEW_ROOTFS/var" ro true
btrfs property set -ts "$NEW_ROOTFS" ro true

# 13. Copy UKI to ESP (shared, accessible from recovery)
echo "Writing UKI to ESP..."
mkdir -p /mnt/root/efi/EFI/Linux
cp /tmp/arch-latest.efi "/mnt/root/efi/EFI/Linux/arch-${NEW_DEPLOY_ID}.efi"

# 14. Create loader entry for new deployment
echo "Creating loader entry..."
cat > "/mnt/root/efi/loader/entries/arch-deploy-${NEW_DEPLOY_ID}.conf" <<EOF
title   Autonomous Arch OS (${NEW_DEPLOY_ID})
version ${NEW_DEPLOY_ID}
linux   /EFI/Linux/arch-${NEW_DEPLOY_ID}.efi
options root=LABEL=arch_root rootflags=subvol=/arkdep/deployments/${NEW_DEPLOY_ID}/rootfs rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0
id      arch-deploy-${NEW_DEPLOY_ID}
EOF

# 15. Prune oldest deployment if over deploy_keep (default 3)
#     CORRECTED: nested subvolumes must be deleted before their parent
DEPLOY_COUNT=$(ls -1 "$DEPLOYMENTS_DIR" | wc -l)
if [[ $DEPLOY_COUNT -gt 3 ]]; then
    OLDEST=$(ls -1 "$DEPLOYMENTS_DIR" | head -n1)
    echo "Pruning oldest deployment: $OLDEST"
    btrfs subvolume delete "$DEPLOYMENTS_DIR/$OLDEST/rootfs/etc"
    btrfs subvolume delete "$DEPLOYMENTS_DIR/$OLDEST/rootfs/var"
    btrfs subvolume delete "$DEPLOYMENTS_DIR/$OLDEST/rootfs"
    rm -f "/mnt/root/efi/loader/entries/arch-deploy-${OLDEST}.conf"
    rm -f "/mnt/root/efi/EFI/Linux/arch-${OLDEST}.efi"
fi

# 16. Set next boot to new deployment
echo "Setting next boot to recovered deployment..."
efibootmgr --bootnext "$(efibootmgr | grep "arch-deploy-${NEW_DEPLOY_ID}" | sed 's/^Boot\([0-9]*\).*/\1/')"

# 17. Sync & reboot
sync
umount /mnt/root
echo "Recovery complete. Rebooting in 5 seconds..."
sleep 5
reboot
```

### 6.1 Migrate Files Helper (Shared with Main Deploy Script)

```bash
#!/usr/bin/env bash
# /usr/lib/systemd/scripts/migrate_files.sh
# IDENTICAL to Document 1 §c migrate_files.sh — single source of truth
# Copies curated allow-list from source deployment's rootfs to destination
# deployment's rootfs (both arguments are rootfs paths, not bare deployment
# directories, so ${SRC_ROOTFS}/etc/... resolves inside the nested subvolume)

set -euo pipefail

SRC_ROOTFS="$1"
DST_ROOTFS="$2"

# Temporarily make destination writable (rootfs, then nested etc/var)
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

# PROJECT EXTENSIONS (must match Document 1 §c exactly):
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

---

## 7. MOUNT-HOME HELPER (Updated for arkdep shared subvolume path)

```bash
#!/usr/bin/env bash
# /usr/bin/mount-home
# Mounts arkdep/shared/home subvolume read-only for manual file recovery

set -euo pipefail

ROOT_LABEL="arch_root"
HOME_SUBVOL="arkdep/shared/home"
MOUNT_POINT="/mnt/home"

echo "Mounting $ROOT_LABEL:$HOME_SUBVOL at $MOUNT_POINT (read-only)..."
mkdir -p "$MOUNT_POINT"
mount -L "$ROOT_LABEL" -o subvol="$HOME_SUBVOL",ro "$MOUNT_POINT"

echo "Done. Your home directories are at:"
ls -1 "$MOUNT_POINT"
echo ""
echo "To copy files to a USB drive:"
echo "  1. Insert USB, find it with: lsblk"
echo "  2. Mount: mount /dev/sdX1 /mnt/usb"
echo "  3. Copy: cp -r $MOUNT_POINT/<user>/Documents /mnt/usb/"
echo ""
echo "When done: umount $MOUNT_POINT"
```

---

## 8. INTEGRATION CHECKLIST

> **Note**: Nemotron's output was cut off partway through this table. Rows
> below through "migrate_files.sh script" are Nemotron's own text; the
> remaining rows were reconstructed from the scripts specified above in
> this same document (§6, §7), not invented — flagged with † so you know
> which ones to double-check if you want Nemotron's exact original wording.

| Component | File / Location | Status |
|-----------|-----------------|--------|
| Recovery partition in `layout.sfdisk` | `partitions/layout.sfdisk` | ☐ (Document 1 §b) |
| Recovery mkosi config | `recovery/mkosi.conf` | ☐ Create |
| Recovery package list | `recovery/packages.list` | ☐ Create |
| Recovery mkosi.extra tree | `recovery/mkosi.extra/**` | ☐ Create |
| Recovery postinst (sign UKI) | `recovery/mkosi.postinst` | ☐ Create |
| reflash.sh script | `recovery/mkosi.extra/usr/lib/systemd/scripts/reflash.sh` | ☐ Create |
| migrate_files.sh script | `recovery/mkosi.extra/usr/lib/systemd/scripts/migrate_files.sh` | ☐ Create (shared with Doc 1) |
| mount-home script † | `recovery/mkosi.extra/usr/bin/mount-home` | ☐ Create (from §7) |
| reflash.service unit † | `recovery/mkosi.extra/usr/lib/systemd/system/reflash.service` | ☐ Create (referenced §3.2, not written out — needs its own oneshot unit calling reflash.sh) |
| Recovery loader entry † | `/efi/loader/entries/arch-recovery.conf` | ☐ (from §5.1) |
| Static UUID generation for recovery `id` † | `scripts/install.sh` → `uuidgen` at install time | ☐ (from §5.2) |
| RUNBOOK entry for manual recovery-partition update † | `docs/RUNBOOK.md` | ☐ (from §4.2/§4.3) |

--------------------------------------------------------------------------------
**END OF REVISED DOCUMENT 2 (v2)**
*Ready for implementation per checklist in §8, modulo the † rows above if
you want them regenerated by Nemotron directly instead.*
================================================================================

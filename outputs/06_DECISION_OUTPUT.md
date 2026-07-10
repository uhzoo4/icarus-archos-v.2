# RECOVERY ENVIRONMENT DESIGN DOCUMENT
## Autonomous Arch OS — Minimal Rescue Runtime

---

## 1. PHYSICAL PLACEMENT: DEDICATED RECOVERY PARTITION

### Decision: **Yes, a small dedicated partition baked at install time.**

### Justification

| Alternative | Why Rejected |
|-------------|--------------|
| **USB stick required** | User in crisis may not have one; adds friction to recovery; defeats "self-contained" promise |
| **Second ESP partition** | ESP is for bootloaders only; firmware may not boot arbitrary UKIs from non-standard ESPs; 1 GiB ESP already allocated |
| **Hidden in `@var` subvolume** | Requires mounting Btrfs first — chicken/egg if root is corrupted; recovery must work when *nothing* mounts |
| **Embedded in firmware (UEFI capsule)** | Not portable across hardware; requires vendor tooling; no standard for "recovery UKI" |

### Partition Specification

```sfdisk
# partitions/layout.sfdisk — ADDITION to existing layout
label: gpt
unit: sectors

# ... existing entries (esp, root_a, root_b, var, home) ...

# 5. Recovery — 512 MiB (fixed, never resized)
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

### 2.1 Core Functions

| Function | Implementation |
|----------|----------------|
| **Re-flash stable image** | `reflash.sh` — downloads latest `arch-<version>.efi` + `.sig` from `https://repo.your-domain.org/custom-stable/`, verifies GPG, writes to inactive slot via `btrfs receive` or `dd`, updates loader entry |
| **Mount & inspect `/home`** | Auto-detects `@home` subvolume on `LABEL=arch_var`, mounts read-only at `/mnt/home`, drops to shell with `HOME=/mnt/home/<user>` hint |
| **Basic shell** | BusyBox `ash` + `bash` (static) — `ls`, `cp`, `mv`, `cat`, `grep`, `find`, `mount`, `umount`, `btrfs`, `cryptsetup`, `curl`, `gpg`, `efibootmgr`, `sbctl` |

### 2.2 Explicit Non-Goals (What It Does NOT Do)

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

### 2.3 Package List (Target: < 100 MB installed)

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

> **Build method**: `mkosi` with `Format=uki`, `Packages=` list above, `ReadOnly=yes`, `RemoveFiles=` aggressive. Output: `arch-recovery.efi` placed on ESP at `/EFI/Linux/arch-recovery.efi`.

---

## 3. RECOVERY UKI STRUCTURE

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

### 3.3 First-Boot Flow

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

## 4. UPDATE STRATEGY: DECOUPLED FROM NIGHTLY PIPELINE

### Principle: **Recovery updates are manual, infrequent, and version-pinned.**

### 4.1 When Recovery Needs Update

| Trigger | Example |
|---------|---------|
| New hardware support needed | New WiFi chipset, NVMe controller, GPU firmware for display in recovery |
| Crypto/library vulnerability | `curl` CVE, `openssl` CVE, `btrfs-progs` bug |
| Boot protocol change | systemd-boot entry format change, UKI spec update |
| Stable repo URL / key rotation | New GPG key, new CDN endpoint |

**Frequency target**: **≤ 2× per year** (not nightly, not monthly).

### 4.2 Update Process (Manual, Documented in RUNBOOK)

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

### 4.3 How Clients Get the Update

- **New installs**: Recovery partition written by installer with latest `arch-recovery.efi` at install time.
- **Existing installs**: **No automatic update.** User must manually re-flash recovery partition if they want it (documented in RUNBOOK: "If recovery environment fails to connect/download, boot live USB and re-run installer's 'update recovery' option").
- **Why not auto-update?** Recovery partition is *the last resort*. If auto-update breaks it, you have *no* fallback. Manual update = you tested it.

---

## 5. SYSTEMD-BOOT ENTRY CONFIGURATION

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

### 5.2 Critical Fields Explained

| Field | Value | Why |
|-------|-------|-----|
| `title` | `Autonomous Arch OS (Recovery)` | Clear label in boot menu — user sees this at 10s timeout |
| `version` | `recovery-<DATE>` | Human-readable; matches `VERSION` file in recovery build |
| `linux` | `/EFI/Linux/arch-recovery.efi` | **Fixed filename** — always this name on ESP. New version overwrites. |
| `options` | `root=LABEL=arch_recovery ...` | Boots from dedicated recovery partition, not A/B roots |
| `id` | `arch-recovery-<STATIC_UUID>` | **Stable across rebuilds** — generated once at install (`uuidgen`), stored in `/etc/machine-id-arch-recovery`, baked into UKI via `mkosi.extra/etc/machine-id-arch-recovery` |

### 5.3 Boot Menu Behavior

```
┌─────────────────────────────────────────────────────────────────┐
│                    systemd-boot menu (10s timeout)              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ▸ Autonomous Arch OS (Slot A)        [default, bootcount=0]  │
│     Autonomous Arch OS (Slot B)        [standby, bootcount=0]  │
│     Autonomous Arch OS (Recovery)      [recovery-2024.06.15]   │
│                                                                 │
│   Press Enter to boot default, 'e' to edit, 'c' for command    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

- Recovery entry **always visible** (not hidden by `bootcount` logic)
- Recovery entry **never marked BAD** by boot counting (it's not a primary OS)
- User can always arrow-down → Enter to reach recovery

---

## 6. REFLASH.SH SPECIFICATION (Core Recovery Logic)

```bash
#!/usr/bin/env bash
# /usr/lib/systemd/scripts/reflash.sh
# Runs in recovery environment — downloads & writes known-good UKI to inactive slot

set -euo pipefail

REPO_BASE="https://repo.your-domain.org/custom-stable"
RECOVERY_INDEX_URL="${REPO_BASE}/recovery/index.json"
TARGET_SLOT=""  # auto-detect: the one NOT currently booted

# 1. Fetch index
echo "Fetching recovery index..."
INDEX_JSON=$(curl -fsSL --max-time 30 "$RECOVERY_INDEX_URL")
LATEST_VERSION=$(echo "$INDEX_JSON" | jq -r '.latest')
UKI_URL=$(echo "$INDEX_JSON" | jq -r '.url')
SIG_URL=$(echo "$INDEX_JSON" | jq -r '.sig_url')
EXPECTED_SHA256=$(echo "$INDEX_JSON" | jq -r '.sha256')

# 2. Determine inactive slot
CURRENT_ROOT=$(findmnt -no SOURCE / | sed 's/\[.*//')
if [[ "$CURRENT_ROOT" == *root_a* ]]; then
    TARGET_LABEL="arch_root_b"
    TARGET_SUBVOL="@_b"
    TARGET_ENTRY_ID="arch-b-<STATIC_UUID_B>"
else
    TARGET_LABEL="arch_root_a"
    TARGET_SUBVOL="@_a"
    TARGET_ENTRY_ID="arch-a-<STATIC_UUID_A>"
fi

echo "Target slot: $TARGET_LABEL ($TARGET_SUBVOL)"

# 3. Download UKI + signature
echo "Downloading UKI: $UKI_URL"
curl -fsSL --max-time 120 -o /tmp/arch-latest.efi "$UKI_URL"
curl -fsSL --max-time 30 -o /tmp/arch-latest.efi.sig "$SIG_URL"

# 4. Verify signature (GPG key baked in recovery)
echo "Verifying GPG signature..."
gpgv --keyring /etc/pacman.d/gnupg/pubring.gpg /tmp/arch-latest.efi.sig /tmp/arch-latest.efi

# 5. Verify SHA256
echo "Verifying SHA256..."
ACTUAL_SHA256=$(sha256sum /tmp/arch-latest.efi | cut -d' ' -f1)
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || { echo "SHA256 mismatch!"; exit 1; }

# 6. Verify UKI signature (sbctl) — proves it was signed by YOUR MOK key
echo "Verifying UKI signature..."
sbverify --cert /etc/sbctl/keys/db.crt /tmp/arch-latest.efi

# 7. Mount target root partition
echo "Mounting target partition..."
mkdir -p /mnt/target
mount -L "$TARGET_LABEL" -o subvol=/ /mnt/target

# 8. Write UKI to ESP (shared, so accessible from recovery)
echo "Writing UKI to ESP..."
mkdir -p /mnt/target/efi/EFI/Linux
cp /tmp/arch-latest.efi /mnt/target/efi/EFI/Linux/arch-${LATEST_VERSION}.efi

# 9. Update loader entry for target slot
echo "Updating loader entry..."
cat > /mnt/target/efi/loader/entries/${TARGET_ENTRY_ID}.conf <<EOF
title   Autonomous Arch OS (Slot ${TARGET_LABEL##*_})
version ${LATEST_VERSION}
linux   /EFI/Linux/arch-${LATEST_VERSION}.efi
options root=LABEL=${TARGET_LABEL} rootflags=subvol=${TARGET_SUBVOL} rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 enforcing=0
id      ${TARGET_ENTRY_ID}
EOF

# 10. Set next boot to target slot
echo "Setting next boot to recovered slot..."
efibootmgr --bootnext "$(efibootmgr | grep "$TARGET_ENTRY_ID" | sed 's/^Boot\([0-9]*\).*/\1/')"

# 11. Sync & reboot
sync
umount /mnt/target
echo "Recovery complete. Rebooting in 5 seconds..."
sleep 5
reboot
```

---

## 7. MOUNT-HOME HELPER (Data Recovery)

```bash
#!/usr/bin/env bash
# /usr/bin/mount-home
# Mounts @home subvolume read-only for manual file recovery

set -euo pipefail

VAR_LABEL="arch_var"
HOME_SUBVOL="@home"
MOUNT_POINT="/mnt/home"

echo "Mounting $VAR_LABEL:$HOME_SUBVOL at $MOUNT_POINT (read-only)..."
mkdir -p "$MOUNT_POINT"
mount -L "$VAR_LABEL" -o subvol="$HOME_SUBVOL",ro "$MOUNT_POINT"

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

| Component | File / Location | Status |
|-----------|-----------------|--------|
| Recovery partition in `layout.sfdisk` | `partitions/layout.sfdisk` | ☐ Add |
| Recovery mkosi config | `recovery/mkosi.conf` | ☐ Create |
| Recovery package list | `recovery/packages.list` | ☐ Create |
| Recovery mkosi.extra tree | `recovery/mkosi.extra/**` | ☐ Create |
| Recovery postinst (sign UKI) | `recovery/mkosi.postinst` | ☐ Create |
| reflash.sh script | `recovery/mkosi.extra/usr/lib/systemd/scripts/reflash.sh` | ☐ Create |
| mount-home script | `recovery/mkosi.extra/usr/bin/mount-home` | ☐ Create |
| Recovery boot entry template | `recovery/boot-entry.conf` | ☐ Create |
| Installer integration | `scripts/install.sh` → writes recovery partition + boot entry | ☐ Modify |
| RUNBOOK recovery section | `docs/RUNBOOK.md` | ☐ Write |
| Manual update procedure | `docs/RUNBOOK.md` | ☐ Write |

---

## 9. SUMMARY: DESIGN PROPERTIES

| Property | Value |
|----------|-------|
| **Partition** | Dedicated 512 MiB ext4, label `arch_recovery` |
| **Format** | UKI (kernel + initrd + cmdline), signed with MOK key |
| **Init** | systemd (minimal initrd profile) |
| **Shell** | BusyBox `ash` + static `bash` |
| **Network** | `systemd-networkd` (DHCP) + `wpa_supplicant` (optional WiFi) |
| **Core tools** | `btrfs-progs`, `cryptsetup`, `curl`, `gpg`, `efibootmgr`, `sbctl`, `jq` |
| **Size target** | < 100 MB installed, < 50 MB UKI |
| **Update cadence** | Manual, ≤ 2×/year, documented in RUNBOOK |
| **Boot entry** | Always visible in systemd-boot menu, stable `id` |
| **Auto-reflash** | Kernel param `reflash=auto` (for headless/remote recovery) |
| **Data recovery** | `mount-home` helper mounts `@home` read-only |

---

**END OF RECOVERY ENVIRONMENT DESIGN**  
*Ready for implementation per checklist in §8.*
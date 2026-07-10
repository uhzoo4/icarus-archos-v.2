# CRYPTOGRAPHIC BLUEPRINT: AUTOMATED UKI SIGNING WITH CUSTOM MOK
## Autonomous Arch OS — Secure Boot Signing Architecture

---

## 1. MOK vs MICROSOFT CHAIN OF TRUST — REALITY CHECK

### 1.1 What MOK Actually Means Here

| Aspect | Microsoft-Signed Shim (shimx64.efi) | Custom MOK (This Project) |
|--------|-------------------------------------|---------------------------|
| **Trust Anchor** | Microsoft UEFI CA (built into every firmware) | Your self-signed CA cert enrolled in firmware NVRAM |
| **User Action Required** | None — works out of box | **One-time manual enrollment at first boot** |
| **Revocation** | Microsoft can revoke via dbx updates | You control revocation via MOK list management |
| **Cost/Process** | $99/yr + legal entity + audit + 6-month wait | **Free, immediate, solo-developer feasible** |
| **Firmware Compatibility** | Universal (Microsoft cert in all db) | Universal (MOK facility mandated by UEFI spec) |
| **Bootloader** | shim → grub → kernel (or shim → UKI) | **systemd-boot → UKI directly** (no shim, no grub) |

### 1.2 The Honest User-Facing Step

**Your users WILL see this exact sequence on first boot:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    UEFI FIRMWARE SCREEN                         │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Shim UEFI Key Management                               │   │
│  │                                                         │   │
│  │  The system has detected a new Machine Owner Key (MOK)  │   │
│  │  that is not enrolled in the firmware.                  │   │
│  │                                                         │   │
│  │  Enroll MOK?                                            │   │
│  │                                                         │   │
│  │  [Continue]  [Cancel]                                   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  If [Continue]:                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Enroll MOK                                             │   │
│  │                                                         │   │
│  │  View key?  [Yes]  [No]                                 │   │
│  │                                                         │   │
│  │  Enroll the key?                                        │   │
│  │  [Yes]  [No]                                            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  If [Yes] to enroll:                                            │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Enter password to confirm enrollment                   │   │
│  │                                                         │   │
│  │  Password: [____________]                               │   │
│  │                                                         │   │
│  │  [OK]                                                   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  System reboots automatically → boots your UKI                  │
└─────────────────────────────────────────────────────────────────┘
```

**Password**: A one-time password **you generate at build time** and communicate to users via your installation docs (e.g., "First boot MOK password: `arch-mok-2024`"). This is **not** their user password.

> **Firmware Variance**: The exact UI text differs between vendors (AMI, Insyde, Phoenix, Dell, Lenovo, ASUS all customize the MOK manager). The *flow* is mandated by UEFI spec; the *wording* is not. Test on 3+ firmware types before shipping.

---

## 2. KEY GENERATION — EXACT COMMANDS

### 2.1 One-Time Air-Gapped CA + Signing Key Generation

```bash
#!/usr/bin/env bash
# Run ONCE on an air-gapped machine (or at least offline VM)
# Output: mok-ca.key, mok-ca.crt, mok-db.key, mok-db.crt
# NEVER commit .key files. Only .crt files go to repo (public).

set -euo pipefail

WORKDIR="$(mktemp -d)"
cd "$WORKDIR"

# 1. Generate CA (valid 10 years, RSA-4096)
openssl req -new -x509 -newkey rsa:4096 -sha256 \
    -keyout mok-ca.key -out mok-ca.crt \
    -days 3650 -nodes \
    -subj "/CN=Autonomous Arch OS MOK CA/OU=Secure Boot/O=Autonomous Arch OS"

# 2. Generate DB (signing) key (valid 2 years, RSA-4096)
openssl req -new -newkey rsa:4096 -sha256 \
    -keyout mok-db.key -out mok-db.csr \
    -days 730 -nodes \
    -subj "/CN=Autonomous Arch OS DB Key/OU=Secure Boot/O=Autonomous Arch OS"

# 3. Sign DB key with CA
openssl x509 -req -in mok-db.csr -CA mok-ca.crt -CAkey mok-ca.key \
    -CAcreateserial -out mok-db.crt -days 730 -sha256 \
    -extfile <(cat <<'EOF'
[ext]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning,1.3.6.1.4.1.311.10.3.1
basicConstraints = critical,CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
) -extensions ext

# 4. Convert to DER for sbctl/sbsign (they accept PEM but DER is canonical)
openssl x509 -in mok-ca.crt -outform DER -out mok-ca.der
openssl x509 -in mok-db.crt -outform DER -out mok-db.der
openssl rsa -in mok-db.key -outform DER -out mok-db.der.key

# 5. Verify chain
openssl verify -CAfile mok-ca.crt mok-db.crt
sbverify --cert mok-db.crt --key mok-db.key /usr/lib/systemd/boot/efi/linuxx64.efi.stub 2>&1 | head -5

# 6. Output summary
echo "=== COPY THESE TO YOUR REPO (public) ==="
ls -la mok-ca.crt mok-ca.der mok-db.crt mok-db.der
echo ""
echo "=== STORE THESE IN GITHUB ACTIONS SECRETS (NEVER IN REPO) ==="
echo "MOK_DB_KEY_PEM=$(cat mok-db.key | base64 -w0)"
echo "MOK_DB_CRT_PEM=$(cat mok-db.crt | base64 -w0)"
echo "MOK_CA_CRT_PEM=$(cat mok-ca.crt | base64 -w0)"
echo ""
echo "=== MOK ENROLLMENT PASSWORD (communicate to users in docs) ==="
MOK_PASSWORD="arch-mok-$(date +%Y%m%d)"
echo "MOK_PASSWORD=$MOK_PASSWORD"
echo ""
echo "=== SECURELY BACKUP THESE OFFLINE ==="
echo "mok-ca.key, mok-db.key, mok-ca.srl"
```

### 2.2 Key File Placement in Repository

```
image/secure-boot/
├── MOK.crt              ← mok-ca.crt (public CA cert, users enroll this)
├── MOK.der              ← mok-ca.der (DER form for sbctl)
├── DB.crt               ← mok-db.crt (public signing cert)
├── DB.der               ← mok-db.der (DER form)
├── sign_uki.sh          ← signing script (uses secrets at runtime)
└── README.md            ← documents key rotation procedure
```

> **Never commit**: `mok-ca.key`, `mok-db.key`, `mok-ca.srl`, any `.der.key` files.

---

## 3. AUTOMATED PIPELINE INTEGRATION

### 3.1 GitHub Actions Secrets Configuration

| Secret Name | Value | Scope |
|-------------|-------|-------|
| `MOK_DB_KEY_PEM` | Base64-encoded `mok-db.key` (PEM) | `nightly-build.yml`, `manual-release.yml` |
| `MOK_DB_CRT_PEM` | Base64-encoded `mok-db.crt` (PEM) | Same |
| `MOK_CA_CRT_PEM` | Base64-encoded `mok-ca.crt` (PEM) | Same |
| `MOK_PASSWORD` | `arch-mok-20240115` (rotation date) | Same |

> **Never log secrets**: Use `env:` block with `mask-value` in workflow.

### 3.2 Signing Step in `nightly-build.yml`

```yaml
# .github/workflows/nightly-build.yml
jobs:
  build-and-sign:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      id-token: write  # for OIDC if publishing to GitHub Releases
    steps:
      - uses: actions/checkout@v4
      
      - name: Install mkosi, sbctl, sbsigntools
        run: |
          sudo apt-get update
          sudo apt-get install -y mkosi sbctl sbsigntools
      
      - name: Restore signing keys from secrets
        env:
          MOK_DB_KEY_PEM: ${{ secrets.MOK_DB_KEY_PEM }}
          MOK_DB_CRT_PEM: ${{ secrets.MOK_DB_CRT_PEM }}
          MOK_CA_CRT_PEM: ${{ secrets.MOK_CA_CRT_PEM }}
        run: |
          mkdir -p image/secure-boot/keys
          echo "$MOK_DB_KEY_PEM" | base64 -d > image/secure-boot/keys/db.key
          echo "$MOK_DB_CRT_PEM" | base64 -d > image/secure-boot/keys/db.crt
          echo "$MOK_CA_CRT_PEM" | base64 -d > image/secure-boot/keys/ca.crt
          chmod 600 image/secure-boot/keys/db.key
      
      - name: Build UKI with mkosi
        run: |
          # ... your existing build steps ...
          mkosi -f image/mkosi.conf
      
      - name: Sign UKI with sbctl
        run: |
          # sbctl expects keys in /etc/sbctl/keys/ — copy there
          sudo mkdir -p /etc/sbctl/keys
          sudo cp image/secure-boot/keys/db.key /etc/sbctl/keys/
          sudo cp image/secure-boot/keys/db.crt /etc/sbctl/keys/
          sudo cp image/secure-boot/keys/ca.crt /etc/sbctl/keys/
          
          # Sign the UKI (mkosi outputs to mkosi.output/)
          UKI_FILE=$(ls mkosi.output/arch-*.efi)
          sbctl sign -s "$UKI_FILE"
          
          # Verify signature
          sbverify --cert /etc/sbctl/keys/db.crt "$UKI_FILE"
      
      - name: Upload signed UKI as artifact
        uses: actions/upload-artifact@v4
        with:
          name: signed-uki-${{ steps.version.outputs.version }}
          path: mkosi.output/arch-*.efi
          retention-days: 30
      
      - name: Clean up keys from runner filesystem
        if: always()
        run: |
          sudo shred -vfz -n 3 image/secure-boot/keys/db.key 2>/dev/null || true
          sudo rm -rf image/secure-boot/keys/
          sudo rm -rf /etc/sbctl/keys/
```

### 3.3 `image/secure-boot/sign_uki.sh` (Standalone, for Local Testing)

```bash
#!/usr/bin/env bash
# image/secure-boot/sign_uki.sh
# Usage: ./sign_uki.sh <uki-file> [--verify-only]
# Requires: MOK_DB_KEY_PEM, MOK_DB_CRT_PEM env vars (base64 PEM)

set -euo pipefail

UKI_FILE="${1:?Usage: $0 <uki-file> [--verify-only]}"
VERIFY_ONLY="${2:-}"

if [[ ! -f "$UKI_FILE" ]]; then
    echo "UKI not found: $UKI_FILE" >&2
    exit 1
fi

# Restore keys from env (CI) or local files (dev)
KEY_DIR="/tmp/sbctl-keys-$$"
mkdir -p "$KEY_DIR"
trap 'shred -vfz -n 3 "$KEY_DIR"/db.key 2>/dev/null; rm -rf "$KEY_DIR"' EXIT

if [[ -n "${MOK_DB_KEY_PEM:-}" ]]; then
    echo "$MOK_DB_KEY_PEM" | base64 -d > "$KEY_DIR/db.key"
    echo "$MOK_DB_CRT_PEM" | base64 -d > "$KEY_DIR/db.crt"
    chmod 600 "$KEY_DIR/db.key"
else
    # Local dev: use image/secure-boot/keys/
    cp image/secure-boot/keys/db.key "$KEY_DIR/"
    cp image/secure-boot/keys/db.crt "$KEY_DIR/"
fi

if [[ "$VERIFY_ONLY" == "--verify-only" ]]; then
    sbverify --cert "$KEY_DIR/db.crt" "$UKI_FILE"
    exit $?
fi

# Sign
sbctl sign --key "$KEY_DIR/db.key" --cert "$KEY_DIR/db.crt" "$UKI_FILE"

# Verify
sbverify --cert "$KEY_DIR/db.crt" "$UKI_FILE"
```

---

## 4. USER FIRST-BOOT EXPERIENCE — EXACT DOCUMENTATION

### 4.1 What You Must Publish in Your Install Guide

```markdown
# First Boot: Secure Boot Enrollment

When you boot the Autonomous Arch OS USB/installer for the first time on a
machine with Secure Boot enabled (the default on almost all hardware since 2020),
you will see a blue/black screen titled **"Shim UEFI Key Management"** or
**"MOK Manager"** (exact wording varies by manufacturer).

## Step-by-Step

1. **Screen appears**: "The system has detected a new Machine Owner Key (MOK) that is not enrolled in the firmware. Enroll MOK?"
   - Select **[Continue]** (press Enter)

2. **Optional**: "View key?" — Select **[No]** unless you want to verify the fingerprint matches:
   ```
   SHA256 Fingerprint: AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99
   ```
   (Published at: https://your-domain.org/mok-fingerprint.txt)

3. **Confirm enrollment**: "Enroll the key?" — Select **[Yes]**

4. **Password prompt**: "Enter password to confirm enrollment"
   - Type: **`arch-mok-20240115`** (case-sensitive, changes with key rotation — check docs for current)
   - Press **[OK]**

5. **System reboots automatically** — you'll see the Autonomous Arch OS boot menu.

## If You Accidentally Select [Cancel] or [No]

- The OS will **not boot** (signature verification fails).
- Reboot and try again — the MOK prompt will reappear.
- If you've cleared the MOK request, re-run the installer or use the recovery entry.

## If You're Installing in a VM (QEMU/KVM, VirtualBox, VMware)

- **Enable Secure Boot in VM settings** (UEFI firmware + Secure Boot toggle).
- Use OVMF with Microsoft keys enrolled (edk2-ovmf package on Arch).
- The same MOK enrollment flow applies.

## Verifying You're Running a Signed Kernel

After boot, run:
```bash
$ mokutil --list-enrolled
# Should show your MOK cert

$ dmesg | grep -i secure
# [    0.000000] Secure boot enabled
```
```

### 4.2 MOK Password Rotation Policy

| Event | New password generated at each key rotation (every 2 years max).  
 Published in `docs/SECURE_BOOT.md` and release notes.  
 Format: `arch-mok-YYYYMMDD` (date of key generation).

---

## 5. KEY COMPROMISE — REVOCATION & ROTATION PLAN

### 5.1 Threat Model

| Scenario | Impact | Detection |
|----------|--------|-----------|
| `mok-db.key` leaked (CI breach, laptop theft) | Attacker can sign malicious UKIs that boot on enrolled machines | Audit logs, anomalous builds |
| `mok-ca.key` leaked (air-gap breach) | Attacker can issue new DB keys, enroll new MOKs | Catastrophic — full PKI compromise |
| User enrolls attacker's key (social engineering) | Single machine compromised | User reports, telemetry |

### 5.2 Rotation Procedure (DB Key — Every 2 Years)

```bash
#!/usr/bin/env bash
# scripts/rotate-db-key.sh
# Run on air-gapped machine with mok-ca.key available

set -euo pipefail

# 1. Generate new DB key pair
openssl req -new -newkey rsa:4096 -sha256 \
    -keyout mok-db-new.key -out mok-db-new.csr \
    -days 730 -nodes \
    -subj "/CN=Autonomous Arch OS DB Key $(date +%Y)/OU=Secure Boot/O=Autonomous Arch OS"

# 2. Sign with existing CA
openssl x509 -req -in mok-db-new.csr -CA mok-ca.crt -CAkey mok-ca.key \
    -CAcreateserial -out mok-db-new.crt -days 730 -sha256 \
    -extfile <(cat <<'EOF'
[ext]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning,1.3.6.1.4.1.311.10.3.1
basicConstraints = critical,CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
) -extensions ext

# 3. Convert to DER
openssl x509 -in mok-db-new.crt -outform DER -out mok-db-new.der
openssl rsa -in mok-db-new.key -outform DER -out mok-db-new.der.key

# 4. Output new secrets for GitHub Actions
echo "=== UPDATE THESE GITHUB SECRETS ==="
echo "MOK_DB_KEY_PEM=$(cat mok-db-new.key | base64 -w0)"
echo "MOK_DB_CRT_PEM=$(cat mok-db-new.crt | base64 -w0)"
echo ""
echo "=== NEW MOK PASSWORD (update docs) ==="
echo "MOK_PASSWORD=arch-mok-$(date +%Y%m%d)"
echo ""
echo "=== REPLACE IN REPO (public) ==="
echo "cp mok-db-new.crt image/secure-boot/DB.crt"
echo "cp mok-db-new.der image/secure-boot/DB.der"
echo ""
echo "=== ARCHIVE OLD KEYS OFFLINE ==="
echo "mv mok-db.key mok-db.key.$(date +%Y%m%d).retired"
echo "mv mok-db.crt mok-db.crt.$(date +%Y%m%d).retired"
```

**Deployment**: 
1. Update GitHub secrets with new `MOK_DB_KEY_PEM` / `MOK_DB_CRT_PEM`
2. Push new `DB.crt` / `DB.der` to repo
3. Next nightly build signs with new key
4. Users boot new UKI → **MOK prompt appears again** (new cert = new enrollment)
5. Document new password in release notes

> **No revocation list needed for DB key** — old key simply stops being used. Firmware trusts CA; new cert signed by same CA = trusted after enrollment.

### 5.3 CA Key Compromise — Nuclear Option

If `mok-ca.key` is compromised:

1. **Generate new CA** (new `mok-ca.key`, `mok-ca.crt`)
2. **Generate new DB key** signed by new CA
3. **Publish new `MOK.crt` / `MOK.der`** to repo
4. **All existing users must re-enroll** (old MOK no longer trusted)
5. **Communicate widely**: "Security update: re-enroll MOK on next boot"
6. **Consider**: Push a "re-enrollment helper" UKI signed by old key that only runs `mokutil --import new-MOK.crt` (but old key is compromised, so this is risky)

> **Mitigation**: Keep `mok-ca.key` on **encrypted USB drive in physical safe**. Never on networked machine. Use `age` or `gpg` to encrypt the backup.

### 5.4 Firmware-Level Revocation (dbx) — Not Feasible for Solo Dev

Microsoft's `dbx` (forbidden signatures database) requires Microsoft signing. You cannot push revocations to firmware dbx. Your only lever is **key rotation + user re-enrollment**.

---

## 6. FIRMWARE VARIANCE — WHERE YOU WILL GET BURNED

| Behavior | Spec Mandate | Vendor Reality | Your Mitigation |
|----------|--------------|----------------|-----------------|
| MOK manager UI text | Flow only | AMI: "Shim UEFI Key Management", Insyde: "MOK Manager", Dell: "Secure Boot Key Management" | Document with screenshots from 3+ vendors |
| MOK password complexity | None | Some firmware rejects >16 chars, special chars, non-ASCII | Use alphanumeric only, ≤16 chars: `arch-mok-20240115` |
| MOK enrollment persistence | Persistent NVRAM | Some firmware clears MOK on BIOS update, CMOS clear | Document: "Re-enroll after BIOS update" |
| Multiple MOKs | Supported | Some firmware only shows first MOK, hides others | Only ever enroll ONE MOK (your CA) |
| Secure Boot + custom keys | Standard | Some OEMs lock Secure Boot to "Standard Mode" only (no custom keys) | Test on target hardware; document known-incompatible models |
| `sbctl` / `sbsign` signature format | PE/COFF Authenticode | All modern firmware accept it | Use `sbctl` (validates signature before writing) |
| UKI size limit | None | Some firmware rejects >32MB EFI executables | Keep UKI < 25MB (strip docs, locales, unused drivers) |

### 6.1 Minimum Hardware Test Matrix

| Firmware Vendor | Tested? | Notes |
|-----------------|---------|-------|
| AMI Aptio V (most DIY motherboards) | ☐ | Reference implementation |
| Insyde H2O (most laptops) | ☐ | Common MOK UI quirks |
| Dell/HP/Lenovo OEM | ☐ | Often lock "Custom Mode" behind BIOS password |
| ASUS ROG / TUF | ☐ | Good MOK support |
| Apple Mac (T2/ARM) | ☐ | **Not supported** — different Secure Boot architecture |
| VMware / QEMU OVMF | ☐ | CI test target |

---

## 7. INTEGRATION CHECKLIST — REPO FILES TO CREATE/MODIFY

| File | Purpose | Status |
|------|---------|--------|
| `image/secure-boot/MOK.crt` | CA cert (DER) for user enrollment | ☐ Create from `mok-ca.der` |
| `image/secure-boot/MOK.der` | Same, explicit DER | ☐ Symlink or copy |
| `image/secure-boot/DB.crt` | DB cert (DER) for signature verification | ☐ Create from `mok-db.der` |
| `image/secure-boot/DB.der` | Same | ☐ Symlink or copy |
| `image/secure-boot/sign_uki.sh` | Standalone signing script | ☐ Create (see §3.3) |
| `image/secure-boot/README.md` | Key rotation procedure | ☐ Create |
| `image/mkosi.conf` | Add `SbsignKey=`, `SbsignCertificate=` | ☐ Modify |
| `image/mkosi.postinst` | Call `sbctl sign` after UKI build | ☐ Modify |
| `.github/workflows/nightly-build.yml` | Restore keys from secrets, sign UKI | ☐ Modify |
| `.github/workflows/manual-release.yml` | Same signing step | ☐ Modify |
| `docs/SECURE_BOOT.md` | User-facing enrollment guide | ☐ Create |
| `docs/RUNBOOK.md` | Add "Key Rotation" section | ☐ Modify |
| `scripts/rotate-db-key.sh` | Automated rotation helper | ☐ Create |

---

## 8. MKOSI.CONF ADDITIONS FOR NATIVE SIGNING

```ini
# image/mkosi.conf — add to [Content] section

# sbctl/sbsign integration (mkosi 22+)
# These tell mkosi to sign the UKI automatically after assembly
# Keys must be in /etc/sbctl/keys/ at build time (CI restores them there)
SbsignKey=/etc/sbctl/keys/db.key
SbsignCertificate=/etc/sbctl/keys/db.crt

# Optional: also sign the kernel stub separately (belt-and-suspenders)
# KernelCommandLineAdd=sbverify=1  # not a real param, just documentation
```

> **mkosi 22+** handles UKI signing natively if `SbsignKey`/`SbsignCertificate` are set. Your `mkosi.postinst` can also call `sbctl sign` explicitly for verification.

---

## 9. SUMMARY: WHAT YOU SHIP TO USERS

| Artifact | Contains | User Action |
|----------|----------|-------------|
| `arch-20240115-abc123.efi` (UKI) | Kernel + initrd + cmdline + **your DB signature** | Boot it |
| `MOK.crt` (on ESP at `/EFI/AutonomousArch/MOK.crt`) | Your CA public cert | Firmware reads it during enrollment |
| Installation ISO/USB | `MOK.crt` embedded + `mokutil --import` pre-staged | Runs enrollment automatically if you pre-stage |

**Pre-staging enrollment** (advanced, reduces user steps):
```bash
# In your installer image (not the UKI), run:
mokutil --import /path/to/MOK.crt --root-pw "arch-mok-20240115"
# This queues the enrollment; user only sees "Confirm enrollment" prompt
```

---

**END OF CRYPTOGRAPHIC BLUEPRINT**  
*Next: Implement §7 checklist, test on 3+ firmware types, then enable nightly signing.*
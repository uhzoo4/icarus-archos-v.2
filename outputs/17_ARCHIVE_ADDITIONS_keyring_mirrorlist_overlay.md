# Additions from reference repos: keyring, mirrorlist, boot-time overlay

Three additions pulled from the six zips, at three different confidence
levels. Read the confidence note on each before using it — the first two
are copied from a real, working, unmodified pattern. The third is a
translation I did myself between two different subsystems (dracut →
systemd-initrd) and has NOT been verified against a working example the
way everything else in this pack has been. Test it before trusting it.

---

## 1. Keyring package — VERIFIED, ready to use as-is

Source: `CachyOS-PKGBUILDS-master/cachyos-keyring/` (real, working, in
production on CachyOS today). This directly fixes the `SigLevel = Optional
TrustAll` problem flagged all the way back at the start of this project —
that setting means pacman accepts unsigned packages from your repo, which
is a real MITM risk. This is the actual fix, copied faithfully with only
names changed.

```
repository/packages/arch-os-keyring/
├── PKGBUILD
├── arch-os-keyring.install
├── arch-os.gpg          # your actual public signing key, exported
├── arch-os-trusted      # <your key fingerprint>:4:
└── arch-os-revoked      # empty until you ever need to revoke a key
```

**`PKGBUILD`:**
```bash
# Maintainer: <you>
pkgname=arch-os-keyring
pkgver=1
pkgrel=1
pkgdesc="Autonomous Arch OS package signing keyring"
arch=(any)
url="https://your-domain.org"
license=('GPL-3.0-or-later')
install=$pkgname.install
source=("arch-os.gpg"
        "arch-os-revoked"
        "arch-os-trusted"
        "$install")
sha512sums=('SKIP' 'SKIP' 'SKIP' 'SKIP')  # fill in with updpkgsums once files are final

package() {
    install -D -m0644 -t "${pkgdir}"/usr/share/pacman/keyrings/ 'arch-os'{.gpg,-trusted,-revoked}
}
```

**`arch-os-keyring.install`** (verbatim from source — this pattern is
exactly right, no changes needed):
```bash
post_upgrade() {
	if usr/bin/pacman-key -l >/dev/null 2>&1; then
		usr/bin/pacman-key --populate arch-os
	else
		echo " >>> Run \`pacman-key --init\` to set up your pacman keyring."
		echo " >>> Then run \`pacman-key --populate arch-os\` to install the Autonomous Arch OS keyring."
	fi
}

post_install() {
	if [ -x usr/bin/pacman-key ]; then
		post_upgrade
	fi
}
```

**`arch-os-trusted`** format is `<fingerprint>:4:` — the `4` is GPG's
"ultimate trust" level. Generate your actual line with:
```bash
gpg --list-keys --with-colons YOUR_KEY_ID | awk -F: '/^fpr:/ {print $10 ":4:"}'
```

**`arch-os-revoked`** stays empty (just needs to exist) until a key is
ever compromised and needs revoking — then the revoked fingerprint goes here.

---

## 2. Mirrorlist package — VERIFIED, ready to use as-is

Source: same repo, `cachyos-mirrorlist/`. The `backup=()` line matters —
without it, a user who's re-ranked their mirrors (via `reflector` or
similar) gets silently overwritten on every update.

```
repository/packages/arch-os-mirrorlist/
├── PKGBUILD
└── arch-os-mirrorlist   # plain text, one Server= line per mirror
```

**`PKGBUILD`:**
```bash
# Maintainer: <you>
pkgname=arch-os-mirrorlist
pkgver=1
pkgrel=1
pkgdesc="Autonomous Arch OS repository mirrorlist"
url='https://your-domain.org'
arch=('any')
license=(GPL-3.0-or-later)
source=(arch-os-mirrorlist)
sha512sums=('SKIP')  # fill in with updpkgsums

package() {
    backup=("etc/pacman.d/$pkgname")  # preserves any user re-ranking on update
    install -Dm644 "$srcdir/$pkgname" "$pkgdir/etc/pacman.d/$pkgname"
}
```

**`arch-os-mirrorlist`** (content):
```
## Autonomous Arch OS mirrorlist
Server = https://repo.your-domain.org/custom-stable/$repo/$arch
```

### Corrected `pacman.conf` section (replaces the old `TrustAll` line)

```ini
[arch-os]
Include = /etc/pacman.d/arch-os-mirrorlist
SigLevel = Required DatabaseOptional
```

`Required` means pacman refuses any package or database not signed by a
key in your keyring. `DatabaseOptional` allows the repo database itself
to be unsigned if you haven't set up database signing yet (packages still
must be signed either way) — tighten to `Required` once database signing
is in place. This replaces `SigLevel = Optional TrustAll` entirely; nothing
from the old setting should remain.

---

## 3. Boot-time read-only overlay — ⚠ BEST-EFFORT, NOT VERIFIED, TEST THIS

Source concept: `CachyOS-PKGBUILDS-master/dracut-cachyos/snapshot-overlay.sh`
(real, working — but it's a **dracut** module, and mkosi builds its own
initrd via a separate tool called `mkosi-initrd`, confirmed against mkosi's
own man page — dracut is not part of that toolchain at all). What follows
is *my own translation* of the same logic into a systemd-initrd service,
based on general systemd initrd target ordering conventions
(`sysroot.mount` → `initrd-fs.target` → `initrd-switch-root.service`) —
**not** verified against a working example the way the dracut original or
the keyring/mirrorlist patterns above were. Treat this as a draft to test
in QEMU (file 09), not a confirmed fix.

**What it's for**: an extra safety net on top of arkdep's
`btrfs property set ro true`. Even if something manages to get a stray
write through to what should be an immutable deployment, this makes sure
that write lands in a RAM-backed overlay instead of the real subvolume —
gone on next reboot, deployment untouched either way.

**The original dracut logic, preserved exactly** (this is the part that's
actually verified — only the packaging around it is a translation):
```bash
function mount_snapshot_overlay() {
    local root_mnt="$NEWROOT"
    local UUID FSTYPE
    IFS=" " read -r UUID FSTYPE < <(findmnt --mountpoint "$root_mnt" -o UUID,FSTYPE -n)
    if [[ "$FSTYPE" = "btrfs" ]] && [[ "$(btrfs property get "${root_mnt}" ro)" == "ro=true" ]]; then
        local ram_dir=$(mktemp -d -p /)

        # Mount the top-level btrfs volume and remount rw explicitly —
        # avoids all subvolumes being seen as RO. Preserved as-is from the
        # original; the exact reason this specific mount/remount/unmount
        # sequence is needed isn't explained in the source comments, so
        # it's kept verbatim rather than "simplified" based on a guess.
        mount -t btrfs "UUID=${UUID}" "${ram_dir}"
        mount -o remount,rw "${ram_dir}"
        umount "${ram_dir}"

        mount -t tmpfs cowspace ${ram_dir}
        mkdir -p ${ram_dir}/{upper,work}
        mount -t overlay -o lowerdir=${root_mnt},upperdir=${ram_dir}/upper,workdir=${ram_dir}/work rootfs ${root_mnt}
    fi
}
```

**Draft systemd-initrd translation** (replace dracut's `$NEWROOT` with the
literal `/sysroot` systemd uses; hook in after the real root is mounted,
before switch-root happens):

`image/mkosi.extra/usr/lib/systemd/system/arch-os-ro-overlay.service`:
```ini
[Unit]
Description=Mount RAM-backed overlay over read-only deployment root
DefaultDependencies=no
After=sysroot.mount
Before=initrd-switch-root.service
ConditionPathIsMountPoint=/sysroot

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/systemd/scripts/arch-os-ro-overlay.sh

[Install]
WantedBy=initrd-fs.target
```

`image/mkosi.extra/usr/lib/systemd/scripts/arch-os-ro-overlay.sh`:
```bash
#!/bin/bash
set -euo pipefail

root_mnt="/sysroot"
read -r UUID FSTYPE < <(findmnt --mountpoint "$root_mnt" -o UUID,FSTYPE -n)

if [[ "$FSTYPE" = "btrfs" ]] && [[ "$(btrfs property get "${root_mnt}" ro)" == "ro=true" ]]; then
    ram_dir=$(mktemp -d -p /run)

    mount -t btrfs "UUID=${UUID}" "${ram_dir}"
    mount -o remount,rw "${ram_dir}"
    umount "${ram_dir}"

    mount -t tmpfs cowspace "${ram_dir}"
    mkdir -p "${ram_dir}"/{upper,work}
    mount -t overlay -o lowerdir="${root_mnt}",upperdir="${ram_dir}/upper",workdir="${ram_dir}/work" rootfs "${root_mnt}"
fi
```

**Before you trust this**:
- Confirm `sysroot.mount` and `initrd-fs.target` are the actual unit names
  in the initrd mkosi builds for you (`systemctl list-units` inside a test
  boot, or inspect the generated initrd directly) — I'm working from
  general systemd initrd conventions here, not a verified example.
- Test explicitly: boot a deployment, write a file inside it (e.g.
  `touch /testfile`), reboot, confirm it's gone and the underlying
  subvolume shows no trace via `btrfs subvolume show` from another
  deployment's chroot.
- If `sysroot.mount`/`initrd-fs.target` aren't the right hook points for
  mkosi's actual generated initrd, this needs `journalctl` from a failed
  boot to diagnose the correct ordering — don't guess a second time,
  inspect the real unit dependency graph (`systemd-analyze dump` works
  inside an initrd shell if boot fails and drops to one).

# Running Context — Finalized Decisions (from Nemotron files 02–06)

Paste this whole file at the top of any DeepSeek prompt (files 07–12) that
needs to know the real architecture instead of the `{{PLACEHOLDER}}` version.
Update it if you change a decision later — this file, not the original
Nemotron outputs, is the thing that should stay current.

**Resolved** (verified against real mkosi/arkdep source — see
`16_VERIFIED_CORRECTIONS_mkosi_and_arkdep.md`): `ReadOnly=` does not exist
as a mkosi key (real immutability is post-build via `btrfs property set`);
`SbsignKey=`/`SbsignCertificate=` were wrong, real names are
`SecureBootKey=`/`SecureBootCertificate=`; `InitrdProfiles=` was correct.

**Still unverified**: `mokutil --import --root-pw` (not in the arkdep/mkosi
source, still looks fabricated — check `man mokutil` yourself), and the
exact systemd version for boot counting (claimed: systemd 250).

**RESOLVED via file 15** (`03_DECISION_OUTPUT_v2.md` /
`06_DECISION_OUTPUT_v2.md`): Partition layout and Rollback mechanism below
are now the real arkdep multi-deployment model, reconciled with Document
2 (recovery) in the same pass. One more correction was needed on top of
Nemotron's revision and has already been applied to both v2 documents:
`etc` and `var` must be Btrfs subvolumes **nested inside** each
deployment's `rootfs` subvolume, not siblings of it — verified directly
against arkdep's `btrfs send $workdir/etc`/`var` and matching
`btrfs receive .../rootfs/` calls. Files 03 and 06 (original) are now
fully superseded; use the sections below and the `_v2.md` documents.

---

## Image format (file 02)
- mkosi → UKI (Unified Kernel Image), `Format=uki`
- Bootloader: systemd-boot, no GRUB, no separate shim
- Root filesystem: Btrfs. Immutability is NOT an mkosi setting — mkosi
  builds a normal read-write tree; read-only enforcement happens post-build
  via `btrfs property set -ts <path> ro true` on the deployment's `rootfs`
  subvolume and its nested `etc`/`var` subvolumes (see Partition layout below)
- Static branding/config → `image/mkosi.extra/` (baked into image at build time)
- Optional/conditional layers (e.g. NVIDIA userspace) → `systemd-sysext`
- Apps: Flatpak/Flathub, installed at first boot, never baked into the UKI
- Version string format: `{DATE}-{git short commit}`, injected by CI via sed
  before the mkosi build (mkosi.conf itself has no native version variable)
- Signing: `SecureBoot=yes`, `SecureBootKey=`, `SecureBootCertificate=`,
  `SecureBootSignTool=sbsign` (real mkosi keys — see Secure Boot section)

## Partition layout & deployment model (file 03, v2 — RESOLVED)
```
esp        1 GiB   — shared, holds ALL UKIs + systemd-boot loader entries
root       remainder — Btrfs, label arch_root, ONE partition (not A/B)
recovery   512 MiB — ext4 (not Btrfs), label arch_recovery, fixed size (file 06)
```
Btrfs subvolume tree inside `root`:
```
/arkdep/deployments/<id>/rootfs/     ← mounted as / via rootflags=subvol=.../rootfs
/arkdep/deployments/<id>/rootfs/etc  ← NESTED subvolume (auto-included, no fstab needed)
/arkdep/deployments/<id>/rootfs/var  ← NESTED subvolume (auto-included, no fstab needed)
/arkdep/shared/home                  ← ALWAYS writable, shared across every deployment
/arkdep/shared/root                  ← curated persistent state (see migrate_files)
/arkdep/shared/flatpak               ← system Flatpaks, shared
```
- `deploy_keep=3` (default): up to 3 deployments kept as subvolumes, oldest pruned
- Only `home`, `root`, `flatpak` are unconditionally shared. Everything else
  in `/etc`/`/var` persists across an update **only** if it's in the
  `migrate_files` allow-list (arkdep's default list + project extensions —
  see `03_DECISION_OUTPUT_v2.md` §c.5 for the full list)
- **Critical ordering**: nested subvolumes (`etc`, `var`) must be created
  *after* `rootfs` and deleted *before* it — `btrfs subvolume delete` on a
  parent while children still exist inside it fails

## Rollback mechanism (file 03, v2 — RESOLVED)
- **arkdep model + systemd-boot boot-counting, layered together** (Nemotron's
  explicit recommendation, not a hedge): arkdep owns deployment lifecycle
  (create/migrate/prune/loader-entry-generation); systemd-boot owns per-entry
  boot counting and automatic fallback. Neither is aware of the other.
- One systemd-boot loader entry per kept deployment (up to `deploy_keep`),
  each with its own independent EFI-variable boot counter
- `bootcount=yes`, `bootcount-limit=3` in `loader.conf` — 3 consecutive
  failures marks that entry BAD; systemd-boot automatically tries the next
  (older) entry. `systemd-boot-success.service` (native, systemd 250+)
  resets the counter to 0 on reaching `graphical.target`
- New builds always go to a **new deployment subvolume**; no existing
  deployment is ever overwritten. Update flow: create new subvolume → extract
  → migrate_files → set read-only → generate loader entry → prune oldest if
  over `deploy_keep` → `efibootmgr --bootnext` → reboot to test
- CI only promotes to `custom-stable` after the new deployment boots
  successfully at least once
- Manual rollback: select any older deployment directly from the systemd-boot
  menu (10s timeout) — works even if the newest deployment never reaches login
- **Not protected**: shared `home`/`root`/`flatpak` subvolumes, and anything
  in the `migrate_files` allow-list — a bug that corrupts data there, or a
  bad config that gets migrated forward, affects every deployment including
  future ones. Deployment swapping is a boot-integrity mechanism, not a
  data-integrity one.
- Full detail, ASCII state diagrams, and the corrected scripts:
  `03_DECISION_OUTPUT_v2.md`

## Secure Boot (file 04)
- Self-signed 2-tier: root CA (`mok-ca.key/crt`) signs a DB key
  (`mok-db.key/crt`) used for actual UKI signing
- Public certs (`.crt`/`.der`) live in `image/secure-boot/`, committed
- Private keys (`.key`) NEVER committed — GitHub Actions secrets only:
  `MOK_DB_KEY_PEM`, `MOK_DB_CRT_PEM`, `MOK_CA_CRT_PEM` (all base64-encoded PEM)
- User does a **one-time manual MOK enrollment** at first boot (UEFI firmware
  prompt, not something you can fully silence without Microsoft signing)
- DB key rotates every 2 years; rotation forces re-enrollment on next boot
- CA key compromise = nuclear option, all users must re-enroll from scratch
- Tool: `sbctl`/`sbsign` for signing, `sbverify` to check

## Telemetry (file 05)
- Opt-in only: gated on `/etc/telemetry/opt-in` containing `"1"`, checked
  first thing, exits silently (no telemetry) if absent
- Trigger: `systemd-coredump@.service` hook →
  `telemetry/client-hook/on-crash-report.sh`
- Collects ONLY: PCI hardware IDs, kernel ring buffer errors (`dmesg`,
  err/crit/alert/emerg only, last 50 lines), package versions for the
  crashed binary + kernel/mesa/driver packages, kernel version, arch, and a
  hashed boot ID (not the raw machine-id)
- Explicit never-collect list: anything under `/home`, `/root`, `/run/user`;
  network config/IPs/MACs/hostname; environment variables; full coredump
  binaries; userspace journal logs; USB serials; disk serials; sub-second
  timestamps
- Endpoint: simple HTTPS POST to a receiver you run yourself (see file 11)

## Repository signing (file 17 — RESOLVED)
- `SigLevel = Optional TrustAll` (the original insecure placeholder) is
  replaced entirely by a real keyring + mirrorlist package pair, following
  CachyOS's verified real convention:
  - `arch-os-keyring` package installs `arch-os.gpg`/`-trusted`/`-revoked`
    to `/usr/share/pacman/keyrings/`, with a `.install` script running
    `pacman-key --populate arch-os` on install/upgrade
  - `arch-os-mirrorlist` package installs to `/etc/pacman.d/arch-os-mirrorlist`
    with `backup=()` so user mirror re-ranking survives updates
  - `pacman.conf`: `SigLevel = Required DatabaseOptional` (EndeavourOS's
    real convention, `PackageRequired`, is an equivalent alternative)
- Full PKGBUILDs: `17_ARCHIVE_ADDITIONS_keyring_mirrorlist_overlay.md`

## Boot-time read-only overlay (file 17 — ⚠ DRAFT, UNVERIFIED)
- Defense-in-depth on top of arkdep's `btrfs property set ro true`: a
  systemd-initrd service that overlays a tmpfs-backed OverlayFS on top of
  the deployment root if it's detected as read-only Btrfs, so any stray
  write during a session vanishes on reboot rather than touching the real
  subvolume
- Adapted from a real, working **dracut** module (CachyOS) — but mkosi uses
  its own `mkosi-initrd` tool, not dracut, so the packaging (systemd
  service + script, hooked at `sysroot.mount`→`initrd-fs.target`) is my own
  translation and has **not** been verified against a working example.
  Test explicitly in QEMU before trusting it.
- Full draft: `17_ARCHIVE_ADDITIONS_keyring_mirrorlist_overlay.md`

## Installer / live-boot medium (file 18 — ⚠ NOT A BLANK GAP ANYMORE, PORTING an existing installer)
- **Not designing from nothing**: a real, working, stateful installer
  already exists for this project — `icarus-assemble.sh` (conductor,
  reads a `MANIFEST`, runs layers sequentially, resumable via
  `layer-X.done` sentinel files) + `layers/01`–`08` (partition → pacstrap →
  chroot/core → custom kernel → daemons → graphics → desktop UI →
  AI/perf tools → native apps → silent boot). File 18 was rewritten around
  this real material — see `18_PROMPT_NEMOTRON_07_installer_medium.md`.
  Not yet run through Nemotron as of this writing.
- Preliminary read (Nemotron's job to confirm/correct): 7 of 10 layers
  (`03a`, `03c`, `04`, `05`, `06`, `07`, `08`) port almost mechanically into
  mkosi's `Packages=`/`mkosi.extra/` — they're just "install packages + drop
  config files." `02-base-install.sh` (pacstrap) disappears entirely — that
  becomes what mkosi does in CI, not an install-day step.
- **The one real problem**: `03b-custom-kernel.sh` compiles `linux-icarus`
  with `march=native` **on the target machine** — incompatible with
  "build once in CI, deploy the same image everywhere." Likely fix: keep
  `march=native` (single personal machine, always has been), just move
  *when* it compiles — a build step on the dev machine producing a package
  mkosi folds in, not a target-machine compile during install.
- Open question Nemotron still needs to resolve: the original design used
  a stock kernel as a "guaranteed bootable fallback" — that may now be
  redundant with (or need reconciling against) the already-decided
  systemd-boot automatic rollback mechanism, which solves a similar
  problem a different way.
- Also still open: whether to keep `icarus-assemble.sh`'s conductor pattern
  for the new installer (writing the image + initializing arkdep + first
  boot) — likely yes, since it's a proven working pattern for this project,
  not borrowed from elsewhere.
- Secondary reference material (EndeavourOS's real archiso profile) is
  still in the prompt for the disk-prep mechanics and the
  `.automated_script.sh`/`script=` unattended-install convention, but it's
  no longer the primary input — the real `layers/` content is.

## Recovery environment (file 06, v2 — RESOLVED)
- Dedicated, fixed-size, ext4 partition — NOT Btrfs, NOT a USB requirement,
  NOT hidden inside any subvolume (must work when nothing else mounts)
- Label: `arch_recovery`, target size under 100MB installed, 512MiB partition
- Capabilities ONLY: re-flash from stable image (`reflash.sh`), mount
  `arkdep/shared/home` read-only for manual recovery, basic BusyBox/bash
  shell with btrfs/cryptsetup/curl/gpg/efibootmgr/sbctl available
- Explicitly excludes: any desktop environment, any AI/healing logic,
  pacman/package installation, NetworkManager, Flatpak, telemetry, and MOK
  enrollment (assumes MOK is already enrolled — recovery doesn't handle
  first-time Secure Boot setup)
- `reflash.sh` creates a **brand-new deployment subvolume** (does not
  overwrite anything) — finds the newest bootable deployment to migrate
  curated files from, downloads + verifies (GPG + SHA256 + sbctl signature)
  the latest stable UKI, creates `rootfs` then nests `etc`/`var` inside it,
  extracts, runs the same `migrate_files.sh` as the main deploy path, sets
  read-only (nested order: etc/var first, then rootfs), writes a new loader
  entry, prunes oldest deployment if over `deploy_keep`, sets next-boot, reboots
- Boot menu shows one entry per kept deployment (up to `deploy_keep`) plus
  the always-visible, never-boot-counted Recovery entry — not a fixed
  two-slot menu
- Full corrected script: `06_DECISION_OUTPUT_v2.md` §6 (note: its final
  integration checklist table was cut off by Nemotron mid-response and the
  last few rows were reconstructed rather than Nemotron's own wording —
  flagged with † in that file if you want it regenerated exactly)

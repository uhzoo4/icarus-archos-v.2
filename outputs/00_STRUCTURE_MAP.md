# Project Structure Map

This is the complete repo/host layout for the autonomous Arch-based OS project.
It merges and corrects the structure sketched earlier in planning — a few
things were missing (secure boot keys, the `/var` overlay layer, the
Flatpak/Distrobox manifest, the recovery environment, docs) and one or two
paths were inconsistent. Treat this file as the source of truth going
forward; update it whenever you add a real directory.

```
autonomous-arch-os/
├── README.md
├── docs/
│   ├── ARCHITECTURE.md            # human-readable version of the design decisions
│   ├── RUNBOOK.md                 # what YOU do when the pipeline halts itself
│   └── DECISIONS.md               # append-only log: date, decision, why, model used
│
├── .github/
│   └── workflows/
│       ├── nightly-build.yml      # scheduled: sync → build → test → stage
│       └── manual-release.yml     # human-triggered: promote staging → stable
│
├── ai-engine/
│   ├── pkgbuild_healer.py         # DeepSeek call: fix a failed PKGBUILD
│   ├── buildlog_triage.py         # DeepSeek call: classify a failure before healing
│   ├── telemetry_analyzer.py      # Nemotron call: cluster/summarize crash reports
│   ├── schemas/
│   │   ├── pkgbuild_fix.schema.json
│   │   ├── triage.schema.json
│   │   └── telemetry_cluster.schema.json
│   └── prompts/                   # the actual prompt text, versioned separately
│       ├── pkgbuild_healer.prompt.md
│       ├── buildlog_triage.prompt.md
│       └── telemetry_analyzer.prompt.md
│
├── repository/
│   ├── core-configs/              # your branding, dotfiles, theme defaults
│   ├── packages/
│   │   ├── custom-desktop-meta/PKGBUILD
│   │   ├── system-hooks/PKGBUILD
│   │   ├── arch-os-keyring/       # NEW (file 17) — fixes SigLevel=TrustAll
│   │   │   ├── PKGBUILD           #   from the original insecure plan
│   │   │   ├── arch-os-keyring.install
│   │   │   ├── arch-os.gpg
│   │   │   ├── arch-os-trusted
│   │   │   └── arch-os-revoked
│   │   └── arch-os-mirrorlist/    # NEW (file 17)
│   │       ├── PKGBUILD
│   │       └── arch-os-mirrorlist
│   └── flatpak-manifest.txt       # curated Flathub app IDs preinstalled by default
│
├── image/
│   ├── mkosi.conf                 # top-level mkosi build definition
│   ├── mkosi.rootpw                # (gitignored) local build-only root password
│   ├── mkosi.extra/               # files copied verbatim into the image
│   │   ├── etc/fstab.overlay
│   │   ├── etc/systemd/sysext/
│   │   ├── usr/lib/systemd/system/arch-os-ro-overlay.service  # NEW (file 17)
│   │   └── usr/lib/systemd/scripts/arch-os-ro-overlay.sh      #   ⚠ unverified, test in QEMU
│   └── secure-boot/
│       ├── MOK.key                # (gitignored, never commit) signing private key
│       ├── MOK.crt                # public cert enrolled into firmware
│       └── sign_uki.sh
│
├── installer/                     # ⚠ PENDING — did not exist before file 18;
│   │                               #   see 18_PROMPT_NEMOTRON_07_installer_medium.md
│   │                               #   for the live-boot/disk-provisioning design
│   └── (structure TBD by file 18's output — likely archiso profile and/or
│        a minimal custom disk-prep script, per its explicit decision)
│
├── partitions/                    # RESOLVED (file 15 / v2 docs) — single
│   │                               #   root partition, deployments as Btrfs
│   │                               #   subvolumes, arkdep model
│   ├── layout.sfdisk              # esp + ONE root partition + recovery
│   ├── deploy_new_image.sh        # creates new deployment subvolume, migrates
│   │                               #   curated files, sets ro, writes loader
│   │                               #   entry, prunes oldest beyond deploy_keep
│   ├── migrate_files.sh           # curated allow-list copy, shared by
│   │                               #   deploy_new_image.sh and recovery's reflash.sh
│   └── systemd-boot/
│       └── loader-entries/        # one entry per kept deployment (deploy_keep=3
│                                   #   default), plus the always-visible recovery entry
│
├── scripts/
│   ├── sync_upstream.sh           # pulls a pinned Arch Linux Archive snapshot
│   ├── build_packages.sh          # chroot build loop over repository/packages/*
│   ├── build_image.sh             # calls mkosi, produces the rootfs image
│   ├── test_boot.sh               # QEMU headless boot + screenshot capture
│   ├── promote_to_stable.sh       # copies validated build from testing → stable
│   └── rollback.sh                # local emergency rollback helper (for you, not users)
│
├── recovery/
│   ├── recovery-rootfs/           # minimal rescue environment baked into the bootloader
│   ├── reflash.sh                 # re-pull last-known-good image from stable channel
│   └── boot-menu-entry.conf
│
├── telemetry/
│   ├── server/
│   │   ├── receive.py             # ingestion endpoint (runs on YOUR infra)
│   │   ├── models.py              # DB schema for crash reports
│   │   └── privacy_policy.md      # what you collect, published to users
│   └── client-hook/
│       └── on-crash-report.sh     # installed on user systems, opt-in only
│
├── repo-hosting/
│   ├── custom-testing/            # AI-touched builds land here first, always
│   └── custom-stable/             # public repo, only human-promoted builds
│
└── storage/                       # gitignored — build artifacts, not source
    ├── build.log
    ├── boot_screen.png
    └── test-os-disk.qcow2
```

## Notes on the pieces that were missing before

- **`image/secure-boot/`** — this didn't exist in the earlier plan at all, and
  without it your image is unbootable on any machine with Secure Boot on
  (which is most machines by default in 2026). See file `04`.
- **`image/mkosi.extra/etc/systemd/sysext/`** — this is how you keep `/usr`
  read-only while still layering your branding/config on top at boot. Skipped
  entirely before; see file `03`.
- **`repository/flatpak-manifest.txt`** — a plain list, not a package. Once the
  root filesystem is read-only, this is your actual app-install mechanism for
  daily-driver use, not `pacman -S`.
- **`docs/RUNBOOK.md` and `docs/DECISIONS.md`** — these exist because you are
  the human in the loop, even in a "self-healing" system. When the pipeline
  halts (and it will), you need a written procedure, not a memory of a chat
  from three months ago.
- **`ai-engine/prompts/` is separate from `ai-engine/*.py`** — keep the prompt
  text in version control on its own. When you improve a prompt, you want a
  diff of the prompt, not a diff buried inside a Python string.

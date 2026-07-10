# Task: Design the mkosi-based immutable image architecture

**Model:** Nemotron 3 Ultra
**Access:** OpenRouter (`nvidia/nemotron-3-ultra-550b-a55b:free`) or NVIDIA NIM
**Stage in pipeline:** Foundational — everything else in the repo depends on
this decision being made once, correctly, before you write any automation.

**Why Nemotron and not DeepSeek:** this task requires reading and reconciling
three different prior-art systems (SteamOS's Btrfs/A-B layout, Fedora
Silverblue's `rpm-ostree` immutability model, and Arkane Linux's native
`systemd-sysupdate` approach on Arch) into one coherent, Arch-native design.
That's a wide-context synthesis job, not a code-generation job — exactly what
Nemotron's 1M-token context and orchestration training are for. Do this once
with the model that can hold all three references in its head at the same
time; don't split it across five small DeepSeek calls and hope the pieces fit
together.

## Before you prompt: gather these inputs

- Your target desktop environment (KDE / GNOME / Hyprland / other)
- Whether you need dual-boot support or a single-OS wipe of the target machine
- Approximate disk size you're designing for (affects A/B partition sizing)
- List of your `custom-*` packages so far (from `repository/packages/`)

## System / Role Prompt

```
You are a principal Linux systems architect specializing in immutable,
atomic operating system design. You have deep, accurate knowledge of:
- mkosi (systemd project's OS image builder) and its configuration format
- Arch Linux packaging (PKGBUILD, pacman, makepkg, devtools/chroot builds)
- systemd-sysext, systemd-sysupdate, and systemd-boot
- Btrfs subvolumes and OverlayFS as used by SteamOS and Fedora Silverblue
- Arkane Linux, an existing Arch-native immutable distribution

Ground every recommendation in real, current tooling behavior. If a detail
depends on a version or a config flag you are not certain is correct, say so
explicitly rather than presenting a guess as fact. Do not use marketing
language like "flawless" or "guaranteed" — describe real trade-offs and
failure modes alongside every recommendation.
```

## Task Prompt

```
I am a solo developer building a personal, immutable, Arch Linux-based
operating system to replace Windows as my daily driver, with an automated
nightly build pipeline. I need you to produce a concrete mkosi-based image
architecture. My constraints:

- Desktop environment: {{KDE / GNOME / Hyprland}}
- Target: {{single-OS wipe / dual-boot alongside Windows}}
- Approximate target disk size: {{e.g. 512GB}}
- Existing custom packages: {{list your repository/packages/* names}}

I need you to specify, concretely:

1. The top-level mkosi.conf structure — what sections I need (Distribution,
   Output, Content, Bootloader) and what values are appropriate for an
   Arch-based, systemd-boot, UKI (Unified Kernel Image) target.
2. How /usr should be mounted read-only while still allowing my custom
   branding/theme files and desktop config defaults to apply — specifically,
   whether to use systemd-sysext layers or mkosi.extra/ file injection for
   this, and why one is more appropriate than the other for my case.
3. How /var and /home should be laid out so they survive an image swap
   without becoming a config-drift problem (i.e. so upstream .pacnew-style
   config changes don't get silently lost or silently override my branding).
4. Where Flatpak/Flathub fits into this — confirm that user-installed apps
   should live entirely outside the immutable image, and specify the mkosi
   config needed to preinstall Flatpak itself and enable Flathub by default.
5. A gap analysis against SteamOS and Fedora Silverblue specifically: what do
   they do that I should copy conceptually, what do they do that depends on
   infrastructure I don't have (Valve's CDN, Red Hat's OSTree servers), and
   what should I do differently because I'm running this alone on GitHub
   Actions with a small budget.

Output as a structured document with headed sections matching the 5 points
above. Include example mkosi.conf snippets, but flag clearly wherever a value
needs to be filled in based on my actual hardware/testing rather than copied
verbatim.
```

## What good output looks like

A document that: (a) gives you an actual mkosi.conf skeleton you can commit
to `image/mkosi.conf`, (b) makes an explicit, justified choice between
systemd-sysext and file injection rather than hedging, (c) explicitly names
which of SteamOS/Silverblue's mechanisms you should *not* copy because they
depend on infrastructure you don't have.

## Validation before you trust it

- Cross-check the mkosi config keys it gives you against `man mkosi.conf` (or
  `mkosi --help` / the upstream systemd/mkosi docs) — config formats change
  between mkosi versions and a hallucinated key will just get silently
  ignored, not error out, which is worse than a crash.
- Actually build a minimal image from the generated config in a VM before
  committing to the full architecture. Don't move to file 03 until this boots.

## Common failure modes for this task

- The model may recommend OSTree-style content-addressed storage because it's
  well-represented in training data from Silverblue — that's a much bigger
  infrastructure commitment than a solo dev needs. Push back and ask for the
  simpler squashfs/dm-verity-less version if it suggests this unprompted.
- Watch for it blending mkosi syntax from different major versions. Ask it to
  flag which mkosi version its syntax targets.

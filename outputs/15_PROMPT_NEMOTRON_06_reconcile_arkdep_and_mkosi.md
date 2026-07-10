# Task: Reconcile rollback architecture with arkdep's REAL mechanism + fix mkosi option names

**Model:** Nemotron 3 Ultra
**Supersedes:** File 03 in full. Corrects the signing-related mkosi snippets in
files 02 and 04.
**Why this exists:** File 03 was written by pattern-matching "SteamOS/Fedora/
arkdep all do 3-strikes rollback" from training data. That's not what arkdep
actually does — the real source (pulled directly from the arkdep and mkosi
repos, not from memory) contradicts it in three concrete ways. This prompt
feeds Nemotron the verified ground truth and asks it to redesign around
reality instead of the folklore version.

**Why Nemotron again, not DeepSeek:** this is the same wide-context
reconciliation job as the original file 02/03 — holding the old (wrong)
design, the new verified source, and the downstream implications
(partition layout, boot entries, migration logic) in one pass. Don't split
this into narrow DeepSeek calls; there's nothing to code yet until the
design itself is settled.

## What's actually being corrected (for your own tracking)

| Claim in old output | Reality (verified from source) |
|---|---|
| Two physical partitions, `root_a` + `root_b`, swapped via systemd-boot | arkdep uses **one** root partition (`LABEL=arkane_root`); each update is a **new Btrfs subvolume** at `/arkdep/deployments/<id>/rootfs`. Old ones are kept (`deploy_keep=3` by default) and pruned, not overwritten. |
| "arkdep's healthcheck is the exact 3-strikes rollback logic you need" | arkdep's `healthcheck()` function does **housekeeping only** — orphaned deployments, stale cache files, missing GPG keys. It has nothing to do with boot success/failure counting. |
| `/var` as one shared subvolume, `/etc` via OverlayFS upper dir | arkdep shares only three subvolumes outright — `home`, `root`, `flatpak`. Everything else in `/var` and `/etc` is part of each deployment's own snapshot; a **curated allow-list of specific files** (`migrate_files`) is explicitly copied forward at deploy time. No OverlayFS involved. |
| `mkosi.conf`: `ReadOnly=yes` makes `/usr` read-only | **This key doesn't exist in mkosi.** Confirmed against mkosi's own `config.py` — the only `read_only` in the codebase is an unrelated `ConsoleMode` enum value. Real immutability is applied *after* the build, via `btrfs property set -ts <path> ro true` on the deployment subvolume — that's arkdep's job, not mkosi's. |
| `mkosi.conf`: `SbsignKey=` / `SbsignCertificate=` | **Wrong names.** Confirmed against mkosi's actual man page: the real keys are `SecureBootKey=` and `SecureBootCertificate=`, alongside `SecureBoot=` (enable it), `SecureBootSignTool=`, and `SecureBootAutoEnroll=`. |

## System / Role Prompt

```
You are a principal Linux systems architect. You are being given verified,
literal source code excerpts from two real open-source projects: arkdep
(Arkane Linux's deployment tool, GPLv3) and mkosi (systemd project's image
builder). Treat every excerpt below as ground truth that OVERRIDES anything
you would otherwise recall about how these tools, or similar tools like
rpm-ostree/OSTree, typically work. Do not average the provided behavior with
generic pattern-matched knowledge from training data — if the excerpt shows
arkdep doing X, describe arkdep as doing X, even if OSTree-based systems
typically do Y. Where you need to infer behavior not shown in the excerpt,
say explicitly "not confirmed by the provided excerpt, inferring based on
—" rather than presenting an inference as verified fact.
```

## Task Prompt

```
I previously asked you to design an A/B partition and rollback architecture
for an immutable Arch-based OS, using arkdep as a reference. Your design
used two physical root partitions and described arkdep's "healthcheck" as
the rollback-triggering mechanism. I've now pulled the actual arkdep and
mkosi source and both claims are contradicted by the real code. Here are
the verified excerpts:

--- ARKDEP: kernel command line template (per deployment) ---
kernel_params='root="LABEL=arkane_root" rootflags=subvol=/arkdep/deployments/%target%/rootfs rw'

--- ARKDEP: shared (always-writable) subvolumes, created once at init ---
btrfs subvolume create $arkdep_dir/shared/home
btrfs subvolume create $arkdep_dir/shared/root
btrfs subvolume create $arkdep_dir/shared/flatpak
# these three are the ONLY unconditionally shared subvolumes

--- ARKDEP: default curated file migration list (copied forward at deploy time,
    NOT a shared mount) ---
dist_migrate_files="'var/usrlocal' 'var/opt' 'var/srv' 'var/lib/AccountsService'
'var/lib/bluetooth' 'var/lib/NetworkManager' 'var/lib/arkane'
'var/lib/power-profiles-daemon' 'var/db' 'etc/localtime' 'etc/locale.gen'
'etc/locale.conf' 'etc/NetworkManager/system-connections' 'etc/ssh'
'etc/fstab' 'etc/crypttab' 'etc/luks-keys' 'etc/passwd' 'etc/shadow'
'etc/group' 'etc/subuid' 'etc/subgid'"

--- ARKDEP: how many old deployments are retained ---
dist_deploy_keep=3   # configurable; oldest pruned beyond this count

--- ARKDEP: how a deployment is marked immutable (post-build, not an mkosi step) ---
btrfs property set -ts $workdir ro true       # root of the deployment
btrfs property set -ts $workdir/etc ro true
btrfs property set -ts $workdir/var ro true
# toggled back to 'ro false' temporarily only during migrate_files copy-in,
# then re-set to 'ro true' before the deployment is considered live

--- ARKDEP: healthcheck() function, in full behavior (not abridged) ---
# Checks for: deployments present on disk but not in the tracker file,
# cache files left over from aborted/removed deployments, and whether
# gpg_signature_check is enabled with no trusted keys installed.
# It does NOT check boot success, does NOT read EFI variables, and is not
# invoked automatically on boot failure — it runs when the arkdep CLI is
# invoked (always_healthcheck=1 by default means "on every CLI invocation,"
# not "on every boot").

--- ARKDEP: how the CLI determines the CURRENTLY RUNNING deployment ---
mountinfo=($(cat /proc/self/mountinfo | head -n 1))
mountinfo=${mountinfo[3]}      # subvol field
deployment_id_old=${mountinfo##*/}   # trailing path component = current ID
# i.e. it reads which subvolume is actually mounted as / right now,
# it does not track this in a separate state file

--- MKOSI: confirmed real option names (from mkosi's own man page/config.py) ---
SecureBoot=                  # enable UEFI SecureBoot signing
SecureBootKey=                # replaces the "SbsignKey=" you previously used
SecureBootCertificate=        # replaces "SbsignCertificate="
SecureBootSignTool=
SecureBootAutoEnroll=
# "ReadOnly=" does not exist anywhere in mkosi's config schema.
InitrdProfiles=               # this one WAS correct, confirmed real

Using ONLY this verified information (plus arkdep's real multi-deployment
model as the storage/update mechanism), redesign the rollback architecture:

1. Replace the two-physical-partition layout with a single root partition
   (label `arch_root`, or keep `arkane_root`-style naming — your call, state
   which and why) containing N kept deployment subvolumes, matching arkdep's
   real structure. Update the partition table (previously
   `partitions/layout.sfdisk`) accordingly — this should now have far fewer
   partitions than the original A/B version (no separate root_a/root_b).

2. Decide explicitly: should this project ALSO layer systemd-boot's real,
   native automatic boot-counting fallback (a genuine systemd-boot feature,
   confirmed separately, independent of arkdep) on top of arkdep's
   manual-rollback-by-reselecting-a-loader-entry model? arkdep itself does
   not do automatic fallback on boot failure — a user has to notice the
   problem and pick an older entry from the boot menu themselves. State
   whether you recommend adding automatic boot-counting as an enhancement
   layered on top of arkdep's deployment model, and if so, exactly how the
   two interact (one loader entry per kept deployment, each with its own
   boot counter, oldest-still-good entry as automatic fallback target).

3. Rewrite the Btrfs subvolume tree, the state diagram, and the "what this
   protects against / doesn't protect against" tables from file 03 to match
   this real model — including being explicit that `home`, `root`, and
   `flatpak` are the ONLY unconditionally shared subvolumes, and that
   everything else persisting across an update depends on being in the
   `migrate_files` allow-list (which you should feel free to extend for
   this project's specific needs, but state clearly that you're extending
   it beyond arkdep's default).

4. Produce a single corrected mkosi.conf snippet (replacing the signing
   section from both my earlier files 02 and 04) using the real
   `SecureBoot=` / `SecureBootKey=` / `SecureBootCertificate=` /
   `SecureBootSignTool=` / `SecureBootAutoEnroll=` keys, and explicitly
   remove the invented `ReadOnly=yes` line, replacing it with a one-line
   note that read-only enforcement happens post-build via `btrfs property
   set -ts <path> ro true`, applied by the deploy script, not by mkosi.

Structure your output with clear "## SUPERSEDES: [old section name]"
headers so each part can be pasted directly over the corresponding section
in an existing spec document, rather than requiring manual merging.
```

## What good output looks like

Output that explicitly states its recommendation on point 2 (automatic
boot-counting layered on arkdep, yes or no) rather than hedging, gives you
a genuinely smaller/simpler partition table than the old A/B one, and
produces the mkosi correction as a single drop-in block rather than two
separate patches to two separate old files.

## Validation before you trust it

- If it proposes extending `migrate_files`, sanity-check every addition
  against the same question used throughout this project: does this file
  need to persist for the OS to keep working, or is it convenience? Every
  addition to that list is something that can carry forward a bug or a
  stale config indefinitely.
- Confirm the new partition table against `partitions/layout.sfdisk`'s
  actual downstream consumers — `scripts/build_image.sh`,
  `scripts/test_boot.sh`, and (once written) the recovery `reflash.sh` all
  assumed the old A/B naming. All of them need matching updates; that's
  covered in `16_VERIFIED_CORRECTIONS...md`'s ripple-effect list, not
  automatically fixed by this prompt alone.
- Re-verify the mkosi key names yourself one more time against
  `mkosi/resources/man/mkosi.1.md` from your extraction — Nemotron is being
  given the correct names here, but confirm it doesn't introduce a new
  invented key while implementing the rest of the redesign.

## Common failure modes for this task

- Watch for it quietly reintroducing OSTree/rpm-ostree concepts (like a
  read-only `/usr` bind-mounted separately from a writable `/var`, which is
  Silverblue's model, not arkdep's) now that it's mid-redesign. Arkdep's
  model is "whole deployment subvolume, mostly read-only, with a curated
  file allow-list migrated forward" — a genuinely different mechanism from
  Silverblue's `/usr`-only immutability. If the output starts talking about
  a separately-mounted read-only `/usr`, that's drift back toward the wrong
  reference project.

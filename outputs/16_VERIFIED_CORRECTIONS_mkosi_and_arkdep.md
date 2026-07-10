# Verified Corrections — mkosi options + arkdep's real mechanism

Everything in this file is confirmed directly from source (your extracted
`mkosi-main.zip` / `arkdep-main.zip`), not from a model's memory of these
tools. Unlike file 15, none of this needs Nemotron to re-derive — these are
just facts. Paste the relevant table straight into `RUNNING_CONTEXT.md` /
`MASTER_SPEC.md` now; use file 15 for the actual redesign reasoning that
builds on top of these facts.

## mkosi option corrections (drop-in replacement)

| File it appeared in | Wrong | Correct | Evidence |
|---|---|---|---|
| 02, 04 | `ReadOnly=yes` | **Does not exist.** mkosi's only `read_only` is an unrelated `ConsoleMode` enum value (boot console display mode). Read-only enforcement happens post-build via `btrfs property set -ts <path> ro true`, run by the deploy tooling — not an mkosi build option at all. | `mkosi/config.py` line 390, confirmed against `mkosi.1.md` (no `ReadOnly=` entry exists) |
| 02, 04 | `SbsignKey=` / `SbsignCertificate=` | `SecureBootKey=` / `SecureBootCertificate=` (plus `SecureBoot=` to enable signing at all, `SecureBootSignTool=`, `SecureBootAutoEnroll=`) | `mkosi/resources/man/mkosi.1.md`, confirmed option names |
| 02 | `InitrdProfiles=default` | **Correct as written**, no change needed | Confirmed present and used in mkosi's own `mkosi.conf` (`InitrdProfiles=lvm` example) |

## Corrected mkosi.conf signing block

```ini
[Content]
SecureBoot=yes
SecureBootKey=/etc/sbctl/keys/db.key
SecureBootCertificate=/etc/sbctl/keys/db.crt
SecureBootSignTool=sbsign
SecureBootAutoEnroll=no
# Immutability is NOT set here. It is applied after deployment by the
# deploy script, via: btrfs property set -ts <deployment_path> ro true
```

## arkdep's real mechanism (supersedes file 03's assumptions)

- **One** root partition, not two. Each update is a new Btrfs subvolume at
  `/arkdep/deployments/<id>/rootfs`, not a swap between physical `root_a`/
  `root_b` partitions.
- Kept deployments default to **3** (`deploy_keep=3`), pruned oldest-first.
- Only three subvolumes are unconditionally shared across every deployment:
  **`home`, `root`, `flatpak`**. Nothing else is a generic shared mount.
- Everything else that needs to persist across an update is copied forward
  explicitly via a **named allow-list** (`migrate_files`) at deploy time —
  not an OverlayFS merge, not a blanket shared `/var`.
- Immutability is applied with `btrfs property set -ts <path> ro true` on
  the deployment's root, `/etc`, and `/var` subvolumes — toggled off
  temporarily only during the migrate-files copy step, then re-locked.
- The currently-running deployment is identified at runtime by reading
  `/proc/self/mountinfo` for the mounted subvolume path — there's no
  separate "which slot is active" state file to go stale or drift.
- arkdep's own `healthcheck()` is **housekeeping only** (orphaned
  deployments, stale cache, missing GPG keys) — it is not a boot-success
  tracker and is not invoked automatically on boot failure.
- Automatic fallback-on-boot-failure is a **separate, real systemd-boot
  feature** (boot counting via loader entry naming), not something arkdep
  itself implements. Whether to layer it on top of arkdep's model is an
  open design decision — that's what file 15 asks Nemotron to resolve
  explicitly rather than assume.

## Ripple-effect map — everything downstream that assumed the old A/B design

Nothing below has been built yet except what's listed as "already written."
Fixing the assumption now, before writing any of the pending items, is the
whole point of catching this before moving on to files 07–12.

| Item | Status | What needs to change once file 15 comes back |
|---|---|---|
| `00_STRUCTURE_MAP.md` → `partitions/` folder, `ab-switch.sh` | Already written | `layout.sfdisk` shrinks to one root partition; `ab-switch.sh` gets renamed/replaced with something matching arkdep's deploy/prune model, not a two-slot switch |
| `RUNNING_CONTEXT.md` → "Partition layout" section | Already written | Replace wholesale with file 15's output |
| `RUNNING_CONTEXT.md` → "Rollback mechanism" section | Already written | Replace wholesale with file 15's output |
| File 03 itself | Already written | Superseded in full by file 15 — keep it in your repo for history, but stop citing it as current |
| Files 02, 04 (mkosi/secure-boot sections only) | Already written | Patch just the signing block using the table above — the rest of those two documents is unaffected |
| File 09 (DeepSeek: QEMU test harness) | Not yet written | Fine to write as-is — it boots a disk image, doesn't need to know about A/B vs. deployments internally |
| File 10 (DeepSeek: CI/CD workflow) | Not yet written | The `promote_to_stable.sh` / `rollback.sh` steps it references need to call arkdep-style deploy/prune commands, not an A/B partition flip — write file 10 AFTER file 15 is resolved |
| File 12 (DeepSeek: recovery scripts) | Not yet written | `reflash.sh`'s "detect which slot is inactive" logic becomes "read `/proc/self/mountinfo`, create a new deployment subvolume" instead — write file 12 AFTER file 15 is resolved |

## Recommended order from here

1. Run file 15 through Nemotron.
2. Update `RUNNING_CONTEXT.md`'s two flagged sections with its output.
3. Patch files 02/04 with the mkosi corrections table above (this part
   doesn't need to wait on file 15 — do it now).
4. Only then move on to files 09, 10, and 12 from the original pack — 07,
   08, and 11 are unaffected by any of this and can be run whenever.

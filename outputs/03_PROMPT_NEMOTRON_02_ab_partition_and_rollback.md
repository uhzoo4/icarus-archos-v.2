# Task: Design the A/B partition layout and rollback mechanism

**Model:** Nemotron 3 Ultra
**Stage in pipeline:** Depends on file 02 being finalized first.

**Why Nemotron:** rollback logic is the one piece of this whole system that
must work correctly the very first time it's needed in the real world —
usually at the worst possible moment, when the active partition is already
broken. This is a "reason carefully about a state machine with no room for
ambiguity" task, which plays to Nemotron's long-context, multi-step reasoning
training much more than to a fast code-completion model. Get the state
machine right here in prose and diagrams before any DeepSeek call writes a
line of implementation.

## Task Prompt

```
Design the A/B partition and rollback architecture for a solo-maintained,
immutable Arch Linux-based OS using systemd-boot (not GRUB). Requirements:

1. Partition layout: one shared /home + EFI partition, plus two interchangeable
   root partitions (A and B), one active and one standby at all times.
2. Define the exact boot-time decision logic: how systemd-boot determines
   which partition is "current," how a failed boot triggers automatic
   fallback to the other partition, and how many consecutive boot failures
   should trigger the fallback (do not assume 1 — justify a specific number
   and explain the trade-off).
3. Define the update flow: new nightly image is written to the INACTIVE
   partition only, the active partition is never touched until the new one
   has been confirmed to boot successfully at least once.
4. Define a manual rollback path a user can trigger from the boot menu
   without needing a working OS to do it from (i.e. this must work even if
   the active partition doesn't boot to a login screen at all).
5. Explicitly state what this design does NOT protect against — for example,
   whether it protects against a bug that boots fine but corrupts /home data,
   and if not, what would.

Present this as: (a) a state diagram in text/ASCII showing every state and
transition, (b) the systemd-boot boot counting / boot assessment
configuration needed (look specifically at systemd's "boot counting" feature
for automatic fallback — confirm whether it uses this mechanism or something
else, and be explicit about which systemd version introduced it), and (c) a
plain-language summary of the guarantees and non-guarantees of this design
for someone who is not a systemd internals expert.
```

## What good output looks like

Output that names systemd's actual automatic-boot-assessment mechanism
(boot counting via loader entry naming / `systemd-boot-counting`, or
equivalent current tooling) rather than inventing a custom watchdog from
scratch, and that is explicit about the one thing this architecture cannot
protect you from: a bug that boots cleanly but corrupts shared `/home` data,
since A/B swapping the root partition does nothing for that case.

## Validation before you trust it

- Verify the specific systemd feature/version claims against the current
  systemd-boot documentation before committing to it — this is exactly the
  kind of "sounds right, might be off by a version" detail worth 10 minutes
  of double-checking.
- Test the manual rollback path by deliberately breaking partition A in a VM
  and confirming you can recover from the boot menu alone, with no working
  OS. If you can't, the design isn't done.

## Common failure modes for this task

- Models frequently conflate systemd-boot's native mechanisms with
  Fedora/OSTree's `ostree admin` rollback commands, which don't exist in this
  stack. If the output references `ostree` commands, that's a sign it drifted
  from Silverblue's actual tooling rather than the Arch-native equivalent —
  push back and ask it to name the systemd-boot-native equivalent instead.

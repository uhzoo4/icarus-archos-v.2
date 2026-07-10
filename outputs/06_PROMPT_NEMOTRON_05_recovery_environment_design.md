# Task: Design the boot-menu recovery/rescue environment

**Model:** Nemotron 3 Ultra
**Stage in pipeline:** Depends on files 02 and 03 (image + partition design).

**Why Nemotron:** this is the "nuclear option" — the thing that has to work
when both A and B partitions are broken and the self-healing pipeline has
clearly failed. By definition, it needs to be designed conservatively and
reasoned about end-to-end, not iterated on with quick code generations. Get
the design right in one careful pass.

## Task Prompt

```
Design a minimal recovery/rescue environment for an immutable Arch-based OS,
accessible as a boot menu entry that does NOT depend on either of the A/B
root partitions being intact or bootable. Cover:

1. Where this recovery environment physically lives on disk (a small,
   separate, dedicated partition baked in at install time — confirm this is
   the right call versus, say, requiring a USB stick, and justify it given
   that a user in this situation may not have a spare USB drive handy).
2. What it needs to be able to do, at minimum: re-download and re-flash a
   known-good image from the stable channel, mount and inspect /home for
   manual data recovery, and provide a basic shell for someone comfortable
   with the command line.
3. What it should deliberately NOT try to do — keep this environment's own
   surface area small, since it is itself something that could go stale or
   break; it should not carry your custom desktop environment or any of your
   automated healing logic.
4. How it gets updated over time (it will need occasional updates too — e.g.
   if network re-flashing depends on a driver that changes) without becoming
   just another thing your nightly pipeline has to babysit.
5. The exact boot menu entry configuration for systemd-boot to expose this
   as a clearly-labeled option.

Present a design doc, not implementation code — implementation will be
handled separately.
```

## What good output looks like

A design that keeps this environment deliberately minimal and infrequently
updated (this should be one of the most stable, rarely-touched parts of the
whole project, not something that gets nightly automated changes), with a
clear, justified answer for where it lives on disk.

## Validation before you trust it

- Actually boot into this recovery entry on your test VM and confirm it
  works when you've deliberately corrupted both partition A and B. If you
  never test the failure case this exists for, you don't actually know it
  works.

## Common failure modes for this task

- Resist the temptation (yours or the model's) to make this "smart" — no AI
  healing logic, no automated decision-making, inside the recovery
  environment itself. The whole point is that it has to work even when
  everything clever has already failed.

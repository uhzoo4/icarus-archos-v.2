# Task: Secure Boot key hierarchy and UKI signing plan

**Model:** Nemotron 3 Ultra
**Stage in pipeline:** Needed before your first real (non-VM) hardware test.

**Why Nemotron:** getting this wrong doesn't produce a bug report, it
produces a laptop that won't boot at all and a user who now has to disable
Secure Boot in firmware just to use your OS — which defeats the point of
having done this work. This is a security-architecture decision with a long
tail of consequences (key rotation, key compromise, revocation), which
benefits from a model reasoning carefully across the whole lifecycle rather
than producing the first working `sbsign` command it finds.

## Task Prompt

```
I'm distributing a personal/small-scale immutable Arch Linux-based OS as
Unified Kernel Images (UKIs) and need a Secure Boot signing plan that will
work on stock hardware with Secure Boot enabled (the default state on most
consumer machines).

Cover, explicitly:

1. What "Machine Owner Key" (MOK) actually means in this context versus a
   full Microsoft-chain-of-trust signature, and which one is realistic for a
   solo developer to set up (be honest that MOK enrollment requires a manual,
   one-time user action at boot — this is not fully silent, and I want to
   know exactly what that user-facing step looks like).
2. The exact key generation commands needed (openssl or equivalent) to
   produce a signing key and certificate suitable for `sbsign`/`sbverify`.
3. How this integrates into an automated nightly build pipeline: which step
   signs the UKI, where the private key must live (and where it must NOT
   live — e.g. never in a public repo or a CI log), and how GitHub Actions
   secrets should be used to keep the key out of the build logs.
4. What happens on the user's machine the very first time they boot a UKI
   signed with my key: the exact MOK enrollment prompt sequence they'll see,
   so I can write accurate first-boot documentation for users.
5. What my plan should be if the signing key is ever compromised — this
   needs a credible revocation/rotation story, not just "don't lose the key."

Flag anywhere your recommendation depends on specific firmware behavior that
varies between hardware vendors, since I can't test every machine myself.
```

## What good output looks like

Output that is upfront about the one-time manual MOK enrollment step (this
cannot be made fully silent without vendor/Microsoft signing, which is not
realistic for a solo project) and gives you a real, testable sequence of
commands rather than hand-waving "sign the UKI."

## Validation before you trust it

- Test the entire MOK enrollment flow on **one real physical machine**
  before you ever tell a user "just boot the ISO." A VM's firmware emulation
  (OVMF) does not always match real vendor firmware Secure Boot behavior.
- Confirm the private key never appears in a GitHub Actions log by
  deliberately checking a run's log output after your first signed build.
- Never commit `MOK.key` — confirm `.gitignore` actually excludes it before
  your first push, not after.

## Common failure modes for this task

- Don't let the model talk you into skipping Secure Boot support entirely
  ("just tell users to disable it") without you explicitly deciding that's
  acceptable — it's a legitimate simplification for a personal daily driver,
  but a bad idea if you ever expect anyone else to install this.

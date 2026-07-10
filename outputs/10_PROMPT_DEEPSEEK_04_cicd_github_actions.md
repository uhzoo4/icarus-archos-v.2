# Task: GitHub Actions CI/CD workflow

**Model:** DeepSeek — `deepseek-v4-flash`
**Stage in pipeline:** Wraps everything else — files 07, 08, 09 all get
called from inside this workflow.

**Why DeepSeek:** YAML generation with a well-specified job graph is squarely
in DeepSeek's strike zone, and this is boilerplate-heavy enough that a fast,
cheap model is the right tool.

## Task Prompt

```
Write a GitHub Actions workflow file (.github/workflows/nightly-build.yml)
for an Arch Linux custom package repository CI pipeline with this exact job
graph and behavior:

1. Trigger on a nightly cron schedule AND on manual workflow_dispatch.
2. Job "sync": pulls a pinned Arch Linux Archive snapshot date (stored as a
   repo variable, not hardcoded) rather than the live mirror.
3. Job "build" (needs: sync): runs inside an archlinux container image,
   creates a non-root build user (never build as root with makepkg), and
   attempts to build every package under repository/packages/*/PKGBUILD
   inside a clean chroot using devtools.
4. On a build failure for a given package: call scripts/buildlog_triage.py,
   then conditionally call scripts/pkgbuild_healer.py, with a MAX_ATTEMPTS=2
   retry cap per package — do not let this loop unbounded. Use the DeepSeek
   API key from a repository secret named DEEPSEEK_API_KEY, and make sure
   the key is never echoed into logs by any step (including the AI response
   itself, in case it happens to echo the key back).
5. Job "test-boot" (needs: build, only if build produced at least one
   package): runs scripts/test_boot.sh against a test image built from the
   new packages.
6. Job "stage" (needs: test-boot): pushes successfully-built and
   boot-tested packages to the custom-testing repo channel ONLY — never
   directly to custom-stable.
7. A separate, manually-triggered workflow (not this file, just note it
   should exist) is what promotes custom-testing to custom-stable — do not
   have this nightly workflow auto-promote to the public/stable channel.
8. Set explicit, minimal `permissions:` at the top of the workflow (not
   default broad permissions), and use `concurrency:` to prevent two nightly
   runs from overlapping if a manual run is triggered mid-cycle.

Add inline comments explaining each safety gate (MAX_ATTEMPTS, the
testing/stable separation, the permissions scoping) so it's clear these
aren't accidental — they're deliberate guardrails.
```

## Validation before you trust it

- Actually trigger this manually against a throwaway branch first. Watch the
  Actions log in real time for your first several runs — don't let a nightly
  cron be the first time you see whether MAX_ATTEMPTS is respected.
- Grep the raw workflow logs for your DEEPSEEK_API_KEY value (temporarily,
  in a test run, then rotate the key afterward regardless) to confirm nothing
  is leaking it — GitHub's log masking catches exact-string matches but not
  always a key that's been re-encoded or partially transformed by a script.
- Confirm the `permissions:` block is actually minimal — a common generation
  mistake is copying a `permissions: write-all` block from a more generic
  example and leaving it in.

## Common failure modes for this task

- Generated workflows sometimes assume tools are pre-installed on the
  archlinux container image that aren't (jq, git, sudo) — check the "Install
  Build Tools" step actually installs everything the later steps use.
- Watch for a missing `continue-on-error` vs. hard failure mismatch: you want
  one package failing to build to not silently cancel testing/staging for
  every *other* package that built fine.

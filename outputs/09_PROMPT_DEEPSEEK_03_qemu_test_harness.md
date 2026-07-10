# Task: QEMU headless boot-test harness

**Model:** DeepSeek — `deepseek-v4-flash`
**Stage in pipeline:** Runs after a successful package build, before
promotion to the stable channel.

**Why DeepSeek:** straightforward, well-documented shell scripting task
(QEMU invocation flags, screenshot capture) with a clear correct answer —
exactly DeepSeek Flash's strong suit, no benefit from Nemotron's extra
context or cost here.

## Task Prompt

```
Write a bash script named test_boot.sh for a CI pipeline that:

1. Boots a headless QEMU virtual machine using a qcow2 disk image
   (path passed as $1) with virtio disk, 2 vCPUs, 2048MB RAM, and KVM
   acceleration if available (fall back to plain QEMU emulation if /dev/kvm
   isn't present, since GitHub-hosted runners may not have nested
   virtualization enabled — detect this rather than assuming).
2. Exposes the display over VNC on a local port so a screenshot tool can
   capture it (do not use SDL/GTK display, this must run with no attached
   terminal or X server).
3. Waits a configurable number of seconds (default 45, accept override as
   $2) for the boot sequence and desktop environment to initialize.
4. Captures a single PNG screenshot of the VM's current display to
   boot_screen.png in the current directory.
5. Cleanly terminates the QEMU process afterward, including in the case
   where the script is interrupted (trap SIGINT/SIGTERM and kill the QEMU
   PID, don't leave orphan processes on a CI runner).
6. Exits with a non-zero code and clear stderr message if QEMU fails to
   start at all (distinct from "started but nothing rendered," which is a
   separate, valid case that later gets evaluated by the vision-check step).

Use standard, currently-maintained Linux tools only (qemu-system-x86_64 and
a VNC screenshot utility available via apt/pacman — name the specific
package, don't assume it's preinstalled on a GitHub Actions ubuntu-latest
runner). Add comments explaining each QEMU flag choice, not just what it
does but why that value was chosen for a CI context specifically.
```

## Validation before you trust it

- Run this once interactively before trusting it inside CI — actually look
  at the produced `boot_screen.png` yourself the first several times to
  confirm it's capturing something meaningful, not a blank VNC frame grabbed
  before boot even started.
- Confirm the KVM-fallback path actually gets exercised: GitHub-hosted
  runners generally do **not** expose `/dev/kvm` by default, so if the script
  only has a happy path for KVM, it will silently be much slower or fail in
  CI even though it worked fine on your local machine.
- Check that the cleanup/trap logic actually fires by deliberately cancelling
  a CI run mid-boot-test and confirming no orphaned QEMU process is left
  consuming a runner's resources on subsequent jobs.

## Common failure modes for this task

- Screenshot tools that depend on a full desktop VNC client library (heavier
  Python GUI packages) rather than a minimal capture utility — ask for the
  lightest-weight option that still reliably works headless in CI.

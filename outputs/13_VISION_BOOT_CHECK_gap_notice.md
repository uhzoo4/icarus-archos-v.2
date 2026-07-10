# Gap Notice: Boot-Screenshot Pass/Fail Checking

The earlier planning session assumed Gemini's vision API for this step, and
your latest request asked specifically to route everything through Nemotron
and DeepSeek instead. Being straightforward about it: as of the current,
verified information on both models, **neither is confirmed to be a
production-ready vision/multimodal endpoint you should build a safety gate
on.** Nemotron 3 Ultra's public listings describe it as text input/output.
DeepSeek's flagship API models (`deepseek-v4-flash`/`deepseek-v4-pro`) are
likewise documented as text models; a `deepseek-vision-preview` name shows up
in one third-party aggregator page but not in DeepSeek's own docs, so it's
not something to depend on without verifying directly against
`api-docs.deepseek.com` yourself before use.

This isn't a small gap to paper over — it's the step that catches "boots to
a black screen" or "crash dialog on login," which is exactly the kind of
failure a text-only model literally cannot see. Don't force-fit this into
the Nemotron/DeepSeek split just for consistency.

## What to actually do here

**Option A — use a real multimodal model for this one step, separately.**
This is genuinely a different job than everything else in this pack. Check
current vision-capable options directly before building against one (model
availability and naming changes fast in this space) — this is a case where
you should verify against the provider's own docs at the time you build it,
not rely on a plan written today.

**Option B — skip vision entirely, use a cheaper text-based proxy signal.**
You can get a meaningful chunk of the same protection without any vision
model at all:
- Check `systemctl is-system-running` inside the VM over a serial console or
  SSH connection instead of a screenshot — this gives you a text status
  ("running", "degraded", "maintenance") that's actually more precise than
  "does the screen look okay" for catching a broken systemd unit.
- Check that a specific expected process (your display manager, e.g. `sddm`
  or `gdm`) is actually running via the same serial/SSH connection.
- Check the kernel ring buffer (`dmesg`) for `Call Trace` or `Kernel panic`
  strings — cheap, reliable, text-only, and this is a task DeepSeek Flash
  handles fine as a simple classifier (feed it the dmesg tail, ask for
  pass/fail plus which line triggered it).

Honestly, Option B catches more real failure modes than a screenshot would
anyway — a desktop can render "fine" while a critical service is actually in
a failed state, and a screenshot won't show you that. Vision-based checking
is a nice-to-have on top of this, not a replacement for it.

## Recommendation

Build Option B first — it's fully covered by the DeepSeek prompts you
already have (feed `systemctl is-system-running` + `dmesg` tail to the same
kind of classifier prompt as file 08). Only add a vision model later, as a
supplementary signal, once you've separately confirmed which vision-capable
model you actually want to depend on and read its current docs directly.

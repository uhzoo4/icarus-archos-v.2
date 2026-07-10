# Master Plan: Who Does What, and Why

## The two models

**Nemotron 3 Ultra** (NVIDIA, open-weight, 550B total / 55B active,
Mamba-Transformer hybrid MoE). Its whole design point is long-running agent
workflows with huge context — up to 1M tokens on NVFP4/Blackwell, 262K on
plain BF16. That's the thing DeepSeek-Flash-sized context doesn't buy you as
cheaply: Nemotron can genuinely hold "every PKGBUILD in the repo, the last
30 days of build logs, and the systemd release notes" in one call and reason
about how they interact. It's slower and more expensive per call than
DeepSeek Flash, and practically speaking a solo developer accesses it via
NVIDIA NIM or OpenRouter's free tier — not self-hosted (189GB+ just for the
weights at aggressive quantization).

**DeepSeek** — current API models are `deepseek-v4-flash` (284B/13B active,
cheap, fast) and `deepseek-v4-pro` (1.6T/49B active, slower, much stronger
on hard reasoning/coding benchmarks). Both have 1M context and both are
genuinely excellent at code-in/code-out tasks — this is where DeepSeek beats
Nemotron for narrow work: it's cheaper, faster, and its coding benchmarks
(SWE-Bench, LiveCodeBench) are extremely strong. Use Flash as the default and
escalate to Pro (with thinking mode on) when Flash's fix doesn't build.

**Important, since it's three weeks away as of this writing:** DeepSeek is
retiring the `deepseek-chat` / `deepseek-reasoner` model names on **July 24,
2026**. If any of your automation still calls those names, it'll break that
day. Use `deepseek-v4-flash` / `deepseek-v4-pro` directly.

## The division of labor

| Job | Model | Why |
|---|---|---|
| mkosi image architecture | Nemotron | one-time, high-stakes, needs to reason across SteamOS/Silverblue/Arkane prior art |
| A/B partition + rollback logic | Nemotron | security/boot-critical, gets read once and must be right |
| Secure Boot / MOK signing | Nemotron | mistakes here brick boot on real hardware, not a VM |
| Telemetry system design | Nemotron | privacy + data-model decisions, made once |
| Recovery environment design | Nemotron | last line of defense, must be conservative |
| PKGBUILD auto-patch on failure | DeepSeek Flash → Pro | happens nightly, narrow, needs to be cheap |
| Build-log triage/classification | DeepSeek Flash | pure text-in/text-out classification |
| QEMU test harness scripting | DeepSeek Flash | shell scripting, well-specified |
| CI/CD YAML | DeepSeek Flash | boilerplate-heavy, DeepSeek is strong here |
| Telemetry endpoint code | DeepSeek Flash | ordinary backend code |
| Recovery scripts | DeepSeek Flash | shell scripting |
| Boot screenshot pass/fail | **neither** | needs a vision-capable model — see file 13 |

The pattern: **one-time architectural decisions with high blast radius go to
the model with the biggest context and the most reasoning budget. Repetitive,
narrow, code-shaped tasks go to the cheap fast coder.** Don't invert this —
using Nemotron to patch a PKGBUILD every night is expensive overkill, and
using DeepSeek Flash to design your Secure Boot key hierarchy is asking a
sprinter to plan a marathon route.

## The actual workflow loop

```
[Upstream Arch Linux Archive snapshot, pinned]
        │
        ▼
[build_packages.sh runs makepkg in a clean chroot]
        │
   success? ──yes──► package moves to custom-testing
        │
        no
        ▼
[buildlog_triage.py → DeepSeek Flash]     (file 08)
   classifies: url-change / missing-dep / checksum / "too complex, escalate"
        │
   too complex? ──yes──► [DeepSeek Pro, thinking mode] one retry, then STOP and log for you
        │
        no
        ▼
[pkgbuild_healer.py → DeepSeek Flash]     (file 07)
   returns a structured patch, never raw file overwrite
        │
        ▼
[bash -n syntax check + retry build] — reject if it doesn't parse
        │
   success? ──no──► drop this package's update, alert you, move on
        │
        yes
        ▼
[test_boot.sh → QEMU headless boot, screenshot]   (file 09)
        │
        ▼
[vision QA — separate multimodal model, see file 13]
        │
   PASS? ──no──► discard iteration, users stay on yesterday's image, alert you
        │
        yes
        ▼
[promote_to_stable.sh]  ← the ONLY human-gated step left, and it should stay that way
```

## What this pipeline actually buys you (being honest)

The earlier planning session used words like "flawless," "un-killable," and
"guaranteed." None of that is true and it's worth saying plainly, because
believing it is what causes solo maintainers to get blindsided.

What this pipeline **does** reliably handle: broken download URLs, missing
build dependencies, checksum mismatches, and simple path/version string
updates. That's a large fraction of day-to-day Arch package breakage, and
automating it is a genuinely good use of your time.

What it does **not** handle, no matter how well you build it: ABI breaks in
core libraries that require real code changes, runtime bugs that only appear
after login (audio, Wi-Fi, GPU driver interaction) rather than at boot,
hardware-specific failures that QEMU's generic virtual hardware can't
reproduce, and any interaction with a real user's already-customized system.
See file 14 for the full list — read it before you tell yourself the plan is
complete, because that belief is the actual risk, not a missing script.

## Practical next step

Work through files 02–06 (Nemotron, architecture) in order — each one assumes
the previous decision is already made. Don't jump to the DeepSeek code-gen
files until the architecture ones are settled; there's no point automating
PKGBUILD patches for an image format you haven't decided on yet.

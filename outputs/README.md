# Autonomous Arch OS — AI Pipeline Pack

This is the full breakdown of the self-healing, immutable Arch-based OS project,
split into individually promptable pieces. Every task in the pipeline has been
assigned to one of two models based on what it's actually good at — nobody gets
a job it's a bad fit for just because it's the "AI" step.

**Read `01_MASTER_PLAN_MODEL_ROLES.md` first.** It explains *why* the split is
what it is, and what neither model can save you from.

## The split, in one line

- **Nemotron 3 Ultra** = the architect. Huge context, used for design decisions,
  reading multiple files/logs/specs at once, and anything security-critical
  where a bad guess is expensive.
- **DeepSeek (V4 Flash / V4 Pro)** = the code fixer. Fast, cheap, extremely
  strong at narrow code-in/code-out tasks: patch this PKGBUILD, write this
  script, fix this YAML.

Neither model can see a screenshot for you and neither can test on real
hardware. That gap is called out explicitly where it matters — see
`13_VISION_BOOT_CHECK_gap_notice.md` and `14_REALITY_CHECK_LIMITATIONS.md`.

## File index

| # | File | Model | What it produces |
|---|------|-------|-------------------|
| 00 | `00_STRUCTURE_MAP.md` | — | Full repo/folder layout for the whole project |
| 01 | `01_MASTER_PLAN_MODEL_ROLES.md` | — | Why the split, access methods, honest limits |
| 02 | `02_PROMPT_NEMOTRON_01_mkosi_image_architecture.md` | Nemotron | mkosi-based immutable image build design |
| 03 | `03_PROMPT_NEMOTRON_02_ab_partition_and_rollback.md` | Nemotron | ✅ Resolved — see `03_DECISION_OUTPUT_v2.md` (via file 15) |
| 04 | `04_PROMPT_NEMOTRON_03_secure_boot_signing.md` | Nemotron | MOK / UKI secure boot signing plan |
| 05 | `05_PROMPT_NEMOTRON_04_telemetry_architecture.md` | Nemotron | Crash-telemetry system design (privacy-aware) |
| 06 | `06_PROMPT_NEMOTRON_05_recovery_environment_design.md` | Nemotron | ✅ Resolved — see `06_DECISION_OUTPUT_v2.md` (via file 15) |
| 07 | `07_PROMPT_DEEPSEEK_01_pkgbuild_autoheal.md` | DeepSeek | PKGBUILD patch-on-failure automation |
| 08 | `08_PROMPT_DEEPSEEK_02_buildlog_triage.md` | DeepSeek | Build-log classifier / triage script |
| 09 | `09_PROMPT_DEEPSEEK_03_qemu_test_harness.md` | DeepSeek | QEMU headless boot-test harness |
| 10 | `10_PROMPT_DEEPSEEK_04_cicd_github_actions.md` | DeepSeek | GitHub Actions CI/CD workflow |
| 11 | `11_PROMPT_DEEPSEEK_05_telemetry_endpoint_code.md` | DeepSeek | Telemetry receiver endpoint code |
| 12 | `12_PROMPT_DEEPSEEK_06_recovery_scripts.md` | DeepSeek | Recovery-environment shell scripts |
| 13 | `13_VISION_BOOT_CHECK_gap_notice.md` | *(neither)* | Why boot-screenshot QA needs a different model |
| 14 | `14_REALITY_CHECK_LIMITATIONS.md` | — | What this pipeline will and won't catch |
| 15 | `15_PROMPT_NEMOTRON_06_reconcile_arkdep_and_mkosi.md` | Nemotron | ✅ Done — see `03_DECISION_OUTPUT_v2.md` + `06_DECISION_OUTPUT_v2.md` |
| 16 | `16_VERIFIED_CORRECTIONS_mkosi_and_arkdep.md` | — | Source-verified facts + full ripple-effect map from the file 03 error |

**Nemotron phase is complete.** All architecture decisions (files 02–06,
reconciled via 15) are resolved and reflected in `RUNNING_CONTEXT.md`. Next:
DeepSeek files 07–12.

| 17 | `17_ARCHIVE_ADDITIONS_keyring_mirrorlist_overlay.md` | — | Keyring+mirrorlist (verified, ready) + ro-overlay (draft, test before trusting) |
| 18 | `18_PROMPT_NEMOTRON_07_installer_medium.md` | Nemotron | Rewritten around your real `icarus-assemble.sh`/`layers/` installer — a port, not a blank design. Not yet run. |

**Reference repos analyzed for file 17/18**: `btrfs-assistant`,
`CachyOS-PKGBUILDS`, `EndeavourOS-ISO`, `kernel-manager`, `linux-cachyos`,
`welcome-main`. Only CachyOS-PKGBUILDS (keyring/mirrorlist/dracut-overlay)
and EndeavourOS-ISO (installer ground truth) contributed anything
architecture-relevant; the rest are optional polish packages, not
referenced in the pipeline files.

**Also in this pack now:** `RUNNING_CONTEXT.md` (condensed decisions,
carry this forward — two of its sections are currently flagged pending
file 15), and `02_DECISION_OUTPUT_CORRECTED.md` /
`04_DECISION_OUTPUT_CORRECTED.md` (your actual Nemotron outputs, patched
in place with the verified mkosi key corrections).

## How to actually use these

1. Read 00 and 01 once, all the way through.
2. Work through the Nemotron files (02–06) first — these are the decisions
   everything else depends on. Get the architecture nailed down before you
   generate a single line of implementation code.
3. Feed each DeepSeek file (07–12) in on its own, one task per conversation.
   Don't paste the whole master plan at DeepSeek — it does its best work on a
   narrow, well-specified task, not "build me an OS."
4. Every prompt file has a **Validation before you trust it** section. Don't
   skip it. That step is what the earlier plan was missing — an AI that writes
   a fix and an AI that checks the fix should not be the same unchecked call.

## Quick access reference

```
# DeepSeek (OpenAI-compatible endpoint)
curl https://api.deepseek.com/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [...],
    "thinking": {"type": "enabled"}
  }'
# Use deepseek-v4-pro for the harder ~20% of cases flash can't resolve.
# NOTE: the old names deepseek-chat / deepseek-reasoner retire 2026-07-24.
```

```
# Nemotron 3 Ultra — cheapest path is OpenRouter's free tier
curl https://openrouter.ai/api/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -d '{
    "model": "nvidia/nemotron-3-ultra-550b-a55b:free",
    "messages": [...]
  }'
# Alternative: NVIDIA NIM (build.nvidia.com) if you want a paid SLA instead
# of the free-tier queue. Do not try to self-host this one — even at 1-bit
# quantization the weights are ~189GB, and it needs real GPU memory on top.
```

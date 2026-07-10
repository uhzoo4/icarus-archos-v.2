# Task: Build-log triage / classification (runs before the healer)

**Model:** DeepSeek — `deepseek-v4-flash`, non-thinking mode (this should be
fast and cheap; it's a classification pass, not a reasoning pass).
**Stage in pipeline:** Runs on every build failure, before file 07's healer.

**Why this is a separate step from the healer:** running the full "write me
a fix" prompt on every failure is wasteful when a good chunk of failures are
either trivially fixable or clearly *not* fixable by a PKGBUILD edit at all.
Triage first, route accordingly, and only spend the healer call on things
worth healing.

## System / Role Prompt

```
You are a build-failure triage classifier for an Arch Linux packaging
pipeline. You read a build error log and output a structured classification
only. You do not attempt to fix anything. Be conservative: if you are unsure
which category applies, choose "needs_human_review" rather than guessing.
```

## Task Prompt

```
Classify this Arch Linux package build failure.

--- BUILD ERROR LOG (last ~2000 characters) ---
{{paste tail of build.log}}

Return JSON:
{
  "category": "trivial_pkgbuild_fix" | "core_library_abi_break" | "toolchain_incompatibility" | "network_flake_retry" | "needs_human_review",
  "confidence": "high" | "medium" | "low",
  "one_line_summary": string,
  "route_to": "healer" | "retry_build" | "human"
}

Routing rules:
- "network_flake_retry" always routes to "retry_build" (transient download
  failures are not a PKGBUILD problem).
- "core_library_abi_break" or "toolchain_incompatibility" always routes to
  "human" — do not send these to the healer, they need actual source changes.
- "trivial_pkgbuild_fix" routes to "healer".
- Anything with confidence "low" routes to "human" regardless of category.
```

## Validation before you trust it

- Spot-check its "network_flake_retry" calls — this is the category most
  likely to be used as a lazy catch-all for anything unfamiliar. If your
  retry count keeps climbing without resolving, the classification is wrong,
  not the network.
- Keep a running log of `category` vs. what the failure actually turned out
  to be (checked by you, weekly, for the first month). This tells you whether
  to trust the routing unattended or keep a human review step longer.

## Common failure modes for this task

- Confidence scores from LLMs are not calibrated probabilities — treat "high
  confidence" as "the output looked confident," not as a statistically
  validated number. Use it as one signal among several, not as the sole gate
  for unattended automation.

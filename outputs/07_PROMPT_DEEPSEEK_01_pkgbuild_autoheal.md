# Task: PKGBUILD patch-on-failure automation

**Model:** DeepSeek — `deepseek-v4-flash` by default, escalate to
`deepseek-v4-pro` with thinking mode on if flash's patch fails to build twice.
**Stage in pipeline:** Runs automatically, nightly, inside CI.

**Why DeepSeek and not Nemotron:** this is a narrow, well-specified,
code-in/code-out task that happens dozens of times a week once the pipeline
is live. DeepSeek Flash is dramatically cheaper and faster for this volume,
and its coding benchmarks are strong enough for the class of fix this
actually needs (URL changes, version bumps, checksum regen, missing deps).
Save Nemotron's larger context/cost for the handful of cases per month that
are genuinely ambiguous.

## Critical rule: never let the model overwrite a file directly

Force structured JSON output and apply the patch yourself with a script that
validates it first. This is the one piece of the earlier planning session
that was right and worth keeping: an AI that can freely rewrite build files
with no gate in between is how a bad fix becomes a bad commit.

## System / Role Prompt

```
You are an expert Arch Linux package maintainer. You fix PKGBUILD files
based on build failure logs. You respond ONLY with valid JSON matching the
provided schema. Never include explanatory text outside the JSON structure.
If the error is not something you can confidently fix from the log alone
(for example, a genuine upstream API/ABI breaking change requiring source
code changes rather than a PKGBUILD edit), set "confident_fix" to false and
explain why in the "explanation" field instead of guessing.
```

## Task Prompt (send with `responseFormat`/JSON mode enabled)

```
An Arch Linux package build failed. Here is the current PKGBUILD and the
tail of the build log.

--- PKGBUILD ---
{{paste full PKGBUILD contents}}

--- BUILD ERROR LOG (last ~4000 characters) ---
{{paste tail of build.log}}

Return JSON matching this schema:
{
  "confident_fix": boolean,
  "explanation": string,
  "diagnosis_category": "url_change" | "missing_dependency" | "checksum_mismatch" | "version_bump" | "path_change" | "other",
  "fixed_pkgbuild_content": string,   // full corrected file, only if confident_fix is true
  "needs_updpkgsums": boolean
}

If confident_fix is false, leave fixed_pkgbuild_content as an empty string.
Do not attempt a fix for anything involving a core library ABI change,
compiler toolchain incompatibility, or a change to the actual upstream
source code logic — flag these as not confident and stop.
```

## Applying the result — the shell-side gate (write this once, don't skip it)

```bash
#!/bin/bash
set -e
# $1 = path to the JSON response from the DeepSeek call

CONFIDENT=$(jq -r '.confident_fix' "$1")
if [ "$CONFIDENT" != "true" ]; then
  echo "AI was not confident in a fix. Halting for human review."
  jq -r '.explanation' "$1"
  exit 1
fi

jq -r '.fixed_pkgbuild_content' "$1" > PKGBUILD.tmp

# Syntax gate — reject before this ever touches the real file
if ! bash -n PKGBUILD.tmp; then
  echo "Rejected: AI output is not valid bash syntax."
  rm PKGBUILD.tmp
  exit 1
fi

mv PKGBUILD.tmp PKGBUILD

if [ "$(jq -r '.needs_updpkgsums' "$1")" = "true" ]; then
  updpkgsums
fi

makepkg -s --noconfirm
```

## Validation before you trust it

- The `bash -n` check only catches syntax errors, not logic errors — a
  syntactically valid PKGBUILD can still be wrong (e.g. a version bump that
  doesn't match what upstream actually released). Diff every AI-applied
  change against the previous PKGBUILD in your CI logs at least weekly by
  hand until you trust the pattern of fixes it tends to make.
- Track `diagnosis_category` over time. If "other" or low-confidence results
  start climbing as a share of total failures, that's a signal upstream drift
  has outpaced what a PKGBUILD-only fix can solve — time to look at file 03's
  A/B rollback more than at improving this prompt further.

## Common failure modes for this task

- It may confidently bump `pkgver` to a version that doesn't actually exist
  yet upstream, guessed from a pattern. Always let `updpkgsums`/the actual
  build fail loudly rather than trusting the version string on faith.
- Two consecutive "confident" fixes that each individually build but that
  interact badly is the classic runaway-loop failure — this is exactly why
  `MAX_ATTEMPTS` exists in the CI workflow (file 10). Don't remove it.

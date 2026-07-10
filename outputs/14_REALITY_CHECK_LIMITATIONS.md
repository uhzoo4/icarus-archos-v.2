# Reality Check: What This Pipeline Will and Won't Catch

Read this once the rest of the pack feels "done." It's the part that's easy
to skip past when a plan finally looks complete on paper.

## What genuinely gets solved by this automation

- Broken upstream download URLs
- Missing build dependencies after an upstream change
- Checksum mismatches after an upstream re-release
- Simple version-string / path bumps
- Catching *build-time* breakage before it ever reaches a user, via the
  testing/stable channel split
- Giving you a real rollback path when something does get through

That's a genuinely large share of what breaks a rolling-release-adjacent
system day to day, and automating it is worth doing.

## What this pipeline does NOT solve, no matter how well you build it

**1. Runtime bugs that only appear after login.** A build can succeed, a
boot-status check can pass, and the moment a user opens a browser, plays
audio, or connects to Wi-Fi, something can still break. Neither Nemotron nor
DeepSeek, nor a vision check, nor a `systemctl is-system-running` check
exercises the system the way an actual person using it does. This is the gap
the earlier planning session called the "delayed trigger" problem, and it's
real — there's no automated substitute for occasionally actually using the
freshly-built image yourself before it reaches anyone else.

**2. Hardware you don't own.** QEMU emulates generic, well-behaved virtual
hardware. A package that passes every automated test can still black-screen
a laptop with a specific GPU or a specific power-management quirk, because
that hardware was never in the test loop. The telemetry system in file 05
is your actual answer to this — not a smarter test harness, but real
hardware reporting back after the fact — and even that only helps for users
who exist and who opted in.

**3. A user's already-customized system.** Your nightly pipeline tests
against a clean image every time. Real installs accumulate local changes,
third-party software, and skipped updates. An update that's perfect against
a clean test image can still conflict with a specific user's modified
system, and there's no way to test against configurations that don't exist
yet in your test environment.

**4. Deep ABI breaks in core libraries.** If `glibc` or `openssl` makes a
breaking change, fixing that is a real source-code-level engineering problem,
not a PKGBUILD edit. Both the triage prompt (file 08) and the healer prompt
(file 07) are deliberately written to recognize this category and route it
to you instead of guessing — that's a feature, not a limitation. If you ever
find yourself tempted to widen the prompt so the AI "just handles" this
category too, don't — this is exactly the class of change where a wrong
automated fix is worse than no fix.

**5. Anything the automation itself introduces.** An AI-written patch can
resolve error A while quietly introducing error B. This is why `MAX_ATTEMPTS`
exists in the CI workflow, why every AI output goes through a syntax/build
gate before being trusted, and why testing-channel promotion to stable stays
a manual, human-gated step in the workflow diagram in file 01. Don't remove
that last gate to make the system "more autonomous" — it's the one place a
human is still meaningfully in the loop, and it should stay that way for as
long as you're the only one maintaining this.

## The one honest summary

This pipeline will take a solo maintainer from "spends every evening
manually fixing rolling-release breakage" to "spends occasional evenings on
the ~20% of breakage that genuinely needs a human." That's a real, valuable
outcome. It is not the same thing as "never has to think about maintenance
again," and building it as if it were the second thing is what turns a good
automation project into a system nobody trusts the first time it's wrong.

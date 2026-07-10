# Task: Harden the recovery scripts Nemotron already wrote

**Model:** DeepSeek — `deepseek-v4-pro` (thinking mode ON — see note below)
**Stage in pipeline:** Reviews/hardens the scripts already written in
`06_DECISION_OUTPUT_v2.md` §6 (`reflash.sh`) and §6.1 (`migrate_files.sh`).

**This task changed.** The original plan had DeepSeek write these scripts
from scratch based on Nemotron's design doc. That's no longer the situation
— Nemotron's revised output (file 15's reconciliation) came back with
complete, working versions of both scripts already, not just a design. Since
they exist, DeepSeek's better job is auditing and hardening real code
rather than generating new code from a spec — narrower, more precise, and
exactly where DeepSeek's coding strength applies best.

**Why Pro instead of Flash, unlike most other DeepSeek tasks:** this is the
one script in the whole project where a bug costs you your only path back
to a working system. Spend the extra cost and latency here, same reasoning
as before.

## Task Prompt

```
I have a bash script that runs inside a minimal recovery environment to
re-flash a known-good OS image when the main system is broken. Audit it
line by line for correctness and safety. Do not rewrite it wholesale —
identify specific bugs or gaps and propose targeted fixes for each one.

--- reflash.sh ---
{{paste the full reflash.sh script from 06_DECISION_OUTPUT_v2.md §6}}

--- migrate_files.sh (called by the script above) ---
{{paste the full migrate_files.sh script from 06_DECISION_OUTPUT_v2.md §6.1}}

Check specifically for:

1. Signature/checksum verification logic errors — especially inverted
   conditions (checking that verification did NOT fail, written backwards,
   which silently defeats the whole check). This class of bug is the
   single highest-consequence mistake this script could contain.
2. Failure-path correctness: does every `curl`, `btrfs`, `gpgv`, `sbverify`,
   and `tar` call have its failure actually checked and handled, given
   `set -euo pipefail` is present? Identify any command whose failure would
   be masked (e.g. inside a pipeline, subshell, or conditional where
   `pipefail` doesn't apply the way the script assumes).
3. Partial-write safety: if the script is interrupted (power loss, network
   drop) at any point after it starts creating the new deployment subvolume
   but before the loader entry is written, what state is left on disk? Is
   there a partially-created, non-bootable deployment subvolume left behind
   that could confuse the next `reflash.sh` run or the boot menu? Propose a
   fix if so (e.g. a temporary name for the subvolume until it's fully
   verified, renamed only at the end).
4. Btrfs subvolume ordering: confirm every subvolume delete/property-set
   sequence respects that nested subvolumes (`rootfs/etc`, `rootfs/var`)
   must be handled before their parent (`rootfs`) — flag any place this
   order might be violated.
5. Idempotency: if a user runs `reflash.sh` twice in a row (e.g. because
   the first run appeared to hang), what happens? Does it create two
   redundant deployments, corrupt state, or handle this gracefully?
6. Logging: confirm every failure path writes a clear, specific message to
   a log file that survives reboot (not just to stdout, which is lost once
   the recovery environment shuts down) — a user asking for help needs to
   be able to retrieve this log.

For each issue found, give: the exact line(s) affected, why it's a problem,
and a minimal targeted fix — not a rewrite of the surrounding code.
```

## Validation before you trust it

- This is the one script in the whole project worth manually tracing line
  by line yourself regardless of what DeepSeek reports back — its own
  audit findings included. Read every branch, especially anything touching
  signature verification or subvolume deletion order.
- Deliberately test the failure paths in a VM, not just the happy path: run
  it with no network, with a deliberately corrupted downloaded image, and
  by killing the script mid-run at a few different points. Confirm it
  refuses to proceed cleanly in each case rather than leaving a silent
  partial write.
- If DeepSeek proposes a fix for the partial-write/idempotency issues (#3,
  #5), that fix itself becomes new code worth a second pass — feed the
  patched script back through the same audit prompt once more before
  trusting it.
- Have this script reviewed by someone other than you if at all possible —
  a second pair of eyes on the one component designed to save you when
  everything else has failed is worth asking a friend for, even a
  non-developer friend who can at least sanity-check the log output is clear.

## Common failure modes for this task

- DeepSeek may want to rewrite large sections "for clarity" when asked to
  audit — redirect it back to targeted fixes each time; a full rewrite
  reintroduces exactly the risk this narrower framing was meant to avoid.
- Watch for it flagging the intentional design choices (e.g. "why isn't
  read-only set immediately after subvolume creation?") as bugs when
  they're deliberate — cross-check any suggested change against Document
  1's stated ordering rationale in `03_DECISION_OUTPUT_v2.md` before
  accepting it.

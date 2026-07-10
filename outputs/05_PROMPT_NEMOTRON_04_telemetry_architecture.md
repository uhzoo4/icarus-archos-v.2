# Task: Design the crash-telemetry system (privacy-aware)

**Model:** Nemotron 3 Ultra
**Stage in pipeline:** Only needed once you have real users other than
yourself. If this is a single-machine daily driver, you can skip straight to
reading crash logs locally and deprioritize this file entirely.

**Why Nemotron:** this is a data-model and policy decision (what to collect,
how to anonymize it, how to correlate hardware failures across an unknown
number of unknown machines) more than a coding task, and it has real ethical
and legal weight (you are collecting data from other people's computers) that
deserves a careful, single well-reasoned pass rather than an iterated
code-first approach.

## Task Prompt

```
I maintain a small, personal Arch-based Linux distribution that a handful of
other people (not just me) may install. I want an OPT-IN crash telemetry
system so that hardware-specific bugs I can't reproduce myself (I can't own
every GPU/laptop model) get reported back to me automatically. Design this
system with these constraints:

1. It must be opt-in at install time, not opt-out, and there must be a way to
   view exactly what would be sent before consenting.
2. Define exactly what data is collected on a crash (e.g. `lspci` hardware
   IDs, the relevant kernel log ring buffer, package versions) and be
   explicit about what must NEVER be collected (home directory contents,
   browser history, any file paths that could contain a username or personal
   identifiers, network configuration/IP addresses, anything from files
   outside of designated system log locations).
3. Propose a minimal viable server-side design for receiving these reports:
   what a solo developer can realistically run and afford (a small VPS
   receiving webhook-style POST requests is a reasonable target — don't
   propose infrastructure that assumes a team or a budget I don't have).
4. Propose how reports should be de-duplicated/clustered so that 50 identical
   crash reports from the same bug don't require 50 manual reviews — this is
   the one place you (Nemotron) should be doing the ongoing analysis work
   yourself, not just designing the schema once.
5. Draft the actual user-facing privacy policy text I should publish
   alongside this feature, in plain language, not legal boilerplate.

Be explicit anywhere a design choice trades user privacy for debugging power,
and default to the more privacy-preserving option unless I say otherwise.
```

## What good output looks like

A collection policy you would be comfortable defending publicly if a user
read your source code and asked "what exactly does this send," a server
design you can actually run on a $5-10/month VPS, and draft privacy-policy
text you could publish today with minimal editing.

## Validation before you trust it

- Read the generated `on-crash-report.sh` collection logic yourself, line by
  line, before it ever runs on anyone's machine but your own test VM. Confirm
  it touches only the paths it claims to.
- Have at least one other person read the privacy policy draft before you
  ship this — "sounds reasonable to me" from the person who designed the
  system is not the same signal as a stranger reading it cold.

## Common failure modes for this task

- Watch for scope creep toward "useful for you" data that isn't strictly
  needed for crash diagnosis (e.g. full installed package lists, uptime
  stats, usage analytics) — push back and ask specifically "is this field
  needed to diagnose a crash, yes or no."

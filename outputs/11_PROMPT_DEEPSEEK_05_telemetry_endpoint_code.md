# Task: Telemetry receiver endpoint (implementation)

**Model:** DeepSeek — `deepseek-v4-flash`
**Stage in pipeline:** Implements the design from file 05. Do not run this
prompt until file 05's architecture is actually finalized — the schema and
data-retention rules it decides on need to be locked in first.

**Why DeepSeek:** this is ordinary backend implementation work (an HTTP
endpoint, a database schema, basic validation) once the policy decisions are
already made — a good fit for a fast coding model rather than Nemotron.

## Task Prompt

```
Implement a minimal crash-telemetry receiver based on this data policy
(paste the finalized output from file 05's Nemotron design here):

{{paste your finalized telemetry architecture decisions}}

Requirements for the implementation:

1. A small Python (FastAPI or Flask, pick one and justify briefly) endpoint
   that accepts a POST with the fields specified in the policy above, and
   REJECTS (with a clear 400 error) any request containing fields not on the
   explicit allow-list — do not silently drop extra fields, refuse the whole
   request, since silently accepting unexpected fields is how scope creep
   happens later.
2. Basic rate limiting per source IP to prevent abuse (a simple in-memory or
   Redis-backed limiter is fine for this scale, don't over-engineer).
3. A database schema (SQLite is fine for this scale) storing exactly the
   allow-listed fields plus a server-generated timestamp and a random report
   ID — no field that could identify a specific machine or person beyond
   what the policy explicitly allows.
4. A basic deduplication check: compute a hash of the normalized error
   signature (not the full raw log) and increment a counter on repeat matches
   instead of storing full duplicate reports.
5. Deployment notes for running this on a small single-core VPS (systemd
   service file, not a heavyweight orchestration setup).

Include the input-validation code in full — this is the part that most
directly enforces the privacy policy, so it needs to be complete and
correct, not abbreviated with "// validation logic here."
```

## Validation before you trust it

- Test the allow-list rejection explicitly: send a request with one extra,
  disallowed field and confirm it's actually rejected, not logged-and-passed.
- Read the deduplication hash logic yourself — confirm it's hashing a
  normalized signature (e.g. exception type + top stack frame) and not
  accidentally including something identifying (a file path with a username
  in it, a timestamp) that would make every report "unique" and defeat
  deduplication entirely.

## Common failure modes for this task

- Generated FastAPI/Flask examples sometimes log the full raw request body
  for debugging by default — make sure that debug logging isn't itself
  capturing more than the privacy policy allows once this is live.

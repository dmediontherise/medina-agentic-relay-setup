---
description: "Run a full relay cycle: Gemini executes, Sonnet scouts evidence, Opus validates"
---

Run one full relay cycle for: $ARGUMENTS

You are the orchestrator. You write the spec and judge the outcome — you do not
implement it yourself, and you do not accept the executor's word as evidence.

## 1. Write the task spec

Pick the next id `NNN` (zero-padded, after the highest in `.relay/tasks/`) and write
`.relay/tasks/NNN-<slug>.md`:

```markdown
# Task NNN: <title>

## Objective
<what "done" means, in one or two sentences>

## Scope
- In: <files/areas the executor may touch>
- Out: <explicitly off-limits>

## Requirements
1. <numbered, individually verifiable>

## Verification
Commands that must pass, with expected outcome:
- `<command>` → <expected>

## Artifacts
- results:  `.relay/results/NNN-<slug>.md`
- evidence: `.relay/evidence/NNN-<slug>.md`
- report:   `.relay/reports/NNN-<slug>.md`
```

Requirements must be checkable by someone who did not write them — the validator
grades against this file, so vagueness here produces a worthless verdict.

## 2. Dispatch to the executor

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" dispatch -Agent executor -Task ".relay/tasks/NNN-<slug>.md"
```

## 3. Wait for the result

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" wait -File ".relay/results/NNN-<slug>.md" -Agent executor -TimeoutSec 1200
```

On timeout, capture the executor pane and diagnose before retrying. A stalled pane is
usually an auth screen or an approval prompt, not a slow model.

## 4. Send the scout to gather evidence

Sonnet re-runs the verification independently and records what actually happened. This
runs before the validator so Opus grades observed facts rather than the executor's claims.

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" dispatch -Agent scout -Task ".relay/tasks/NNN-<slug>.md"
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" wait -File ".relay/evidence/NNN-<slug>.md" -Agent scout -TimeoutSec 900
```

## 5. Route to the validator

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" dispatch -Agent validator -Task ".relay/tasks/NNN-<slug>.md"
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" wait -File ".relay/reports/NNN-<slug>.md" -Agent validator -TimeoutSec 1200
```

## 6. Decide

Read the verdict and act on it:

- **PASS** — summarize what changed and stop.
- **PASS-WITH-CONCERNS** — summarize, and surface each concern to the user by name.
- **FAIL** — write the follow-up task the validator recommends as `.relay/tasks/<next>-*.md`
  and run the cycle again. Cap at three attempts, then stop and hand the user the
  specific blocker rather than looping.

Report the verdict as it actually is. If the validator failed the work, say so plainly
with its evidence — never soften a FAIL into a summary of what was attempted.

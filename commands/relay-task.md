---
description: "Run a full relay cycle: Gemini executes, Gemini scouts evidence, Opus validates"
---

Run one full relay cycle for: $ARGUMENTS

You are the orchestrator. You write the spec and judge the outcome — you do not
implement it yourself, and you do not accept the executor's word as evidence.

**This is the manual, one-cycle path — you drive every step.** For a queue of tasks, or
any run where the user wants to be out of the loop, use `/relay-auto` instead: it does
everything below for every pending task, self-heals broken panes, and runs the mutation
lane in parallel. Prefer it whenever there is more than one task to run.

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

### Two rules for this file, both learned from real cycles

**1. Every verification command must be a single line that runs as written.** The executor
rewrites commands it cannot run and then reports the result it expected rather than the one
it observed. It has repeatedly reported this as exiting 0 with the intended output:

```
python -c "from m import f; try: f(bad); print('NO-RAISE'); except ValueError as e: print('RAISED')"
```

That is a `SyntaxError` — a compound statement cannot follow a semicolon. The executor
reformats it across lines, runs *that*, and pastes the passing result under the original.
The scout catches it by re-running verbatim, but a discrepancy you can avoid writing is
cheaper than one you have to catch. So no `try`/`except`, `if` or `for` after a semicolon
in a `python -c`. Use one of these instead:

```
python -c "import m; print(m.f('1h30m'))"                        -> 5400
python -c "import m; assert m.f('1h30m') == 5400; print('OK')"   -> OK
python -c "import pytest, m; pytest.raises(ValueError, m.f, '')" -> exit 0
python -c "import m; m.f('')"                                    -> exit 1, ValueError
```

Better still, put behavioural assertions in the test suite and make `pytest -q` the
verification command — one line, no quoting hazards, and the scout audits the assertions
anyway.

**2. The Objective is graded too.** Write it as a summary of the requirements, never as a
stronger claim than they support. A validator has already failed a task's Objective for
promising an outcome the requirements could not deliver — the executor followed the
requirements and was right to, and the spec was what was wrong.

**3. A requirement that can only be proved by breaking the code belongs to the mutator.**

"This test must fail when the offset table is disabled" is a *mutation criterion*, and it
is the most valuable kind of requirement you can write — it is the only one that proves a
test can fail. But nobody upstream of the mutator can establish it: the executor grades
nothing, and the scout is forbidden from editing source, which is what makes its evidence
trustworthy.

Write it as a normal numbered requirement and say which mutation settles it:

```markdown
3. The test fails when the offset table is disabled — i.e. with `js/app.js:511` replaced
   by `const offsetRatio = 0; void BLACK_KEY_OFFSETS;`. Name which test failed, not just
   that the file did.
```

Then **stop**. Do not add routing instructions. Task 007 carried a hand-written
`## Notes for the scout and validator` block telling the scout to skip it and the
validator to run the mutation itself — and it worked, at Opus prices, for shell work a
free pane exists to do. That block is now wrong: the scout marks it `none` and points at
the mutation lane, the mutator runs it on its snapshot, and the validator reads the
result. All three know this from their charters.

If you find yourself writing per-agent instructions into a task file at all, that is a
signal a charter is wrong, not that this task is special. Fix the charter in
`~/.claude/relay/charters/` — task-level patches do not survive to the next task, which is
how the same contradiction got hand-patched twice.

Where two requirements can conflict on some input, decide it in the task rather than
leaving it for the executor to resolve silently. If you genuinely want it left open, say so
explicitly so the scout files it as an open question instead of guessing.

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

The scout re-runs the verification independently and records what actually happened. This
runs before the validator so the validator grades observed facts rather than the
executor's claims. Scout and validator are separate panes with separate charters — that
independence is the point, and it comes from role separation rather than from which model
sits in each pane.

The scout does more than re-run commands: it reads the assertion bodies of the executor's
tests and writes its own edge-case probes under `.relay/probe/`. It runs on Gemini, so
that depth is free. Its evidence file is compacted on purpose — passing commands reduce
to a result line, failures are pasted in full — so the validator, which is Opus and the
only Claude pane in the relay, spends its budget on judgment rather than on green logs.

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" dispatch -Agent scout -Task ".relay/tasks/NNN-<slug>.md"
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" wait -File ".relay/evidence/NNN-<slug>.md" -Agent scout -TimeoutSec 900
```

### This step is not optional, and it is the one that fails

On 2026-08-10 the scout wedged, and the next five task cycles ran executor → validator
with no evidence at all. Nothing was broken enough to stop anything: each cycle looked
fine, and Opus quietly did the scout's shell work at Opus prices — the exact cost
inversion this relay exists to prevent. The validator noticed and said so in its reports;
nobody was reading reports for process failures.

So treat a missing evidence file as a **hard stop**, never as a reason to move on:

1. `dispatch` exits `3` and refuses outright if the scout has faulted. That is a
   diagnosis, not an error to route around.
2. If `wait` times out, it now tells you which of three things happened — faulted,
   still working, or idle-but-silent. Act on what it says.
3. If the scout has faulted, restart that pane and re-dispatch **the same task**:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" restart -Agent scout
   ```
   A restart clears this fault; the credentials are re-read clean at startup.
4. Only after two failed scout attempts on the same task, proceed to the validator —
   and then you must say so explicitly to the user *and* in the dispatch, so the verdict
   is not silently based on the executor's self-report. Never let this become the norm:
   if the scout fails twice on consecutive tasks, stop and fix the scout instead of
   continuing to run cycles without it.

## 4b. Optionally start the mutation lane

Mutation testing asks the one question the scout cannot: would these tests notice if the
code were wrong? The scout's contract forbids editing source — that prohibition is what
makes its evidence trustworthy — so mutation work goes to a fourth pane, the **mutator**,
which edits freely inside a frozen snapshot of the workspace and never touches the live
tree.

Start it right after the executor's result lands, and **do not wait for it**:

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" snapshot -Task ".relay/tasks/NNN-<slug>.md"
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" dispatch -Agent mutator -Task ".relay/tasks/NNN-<slug>.md"
```

The snapshot must be taken while the tree is quiet — after the executor finishes, before
anything else edits it. Findings land in `.relay/mutation/NNN-<slug>.md` whenever they are
ready. If that file exists by the time you route to the validator, it reads it; if not,
review it yourself afterwards. Never hold the validator behind it.

In a single manual cycle this is optional and worth it mainly when the task is about test
quality. Under `/relay-auto` it is automatic.

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

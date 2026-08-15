---
description: "Execute the latest implementation plan through the relay, unattended (agy executes, agy scouts, agy mutates, Opus validates)"
---

Execute an existing implementation plan through the relay. You decompose the plan into
task specs; autopilot runs all of them. Once you launch it, you are out of the loop until
it finishes.

There is no second terminal window. Agents run as psmux panes in one detached session;
watch them with `psmux attach -t relay` (Ctrl+B d detaches).

## 1. Locate the plan

If `$ARGUMENTS` names a plan file, use it. Otherwise search `docs/superpowers/plans/` and
`docs/maestro/plans/` for `.md` files and take the most recently modified one.

If no plan exists, stop and tell the user to write one first with the
`superpowers:writing-plans` skill. Do not invent a plan to proceed.

Print the resolved plan path before continuing, so the user can catch a wrong pick.

## 2. Make sure the relay is up

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" health
```

If it is down, bring it up on the current workspace with `/relay-up`. If `health` reports
the mutator `ABSENT`, the session predates the mutation lane — `down` then `up` to rebuild
with all four agents.

## 3. Decompose the plan into the whole queue, up front

**This is the step that matters, and it is the only one you still own.**

Write one task file per phase into `.relay/tasks/`, numbered in execution order, *before*
launching anything. Autopilot runs them in id order and never asks you to interpret the
plan, so anything you leave vague gets resolved by an agent that has not read the plan or
this conversation.

For each phase write `.relay/tasks/NNN-<slug>.md`:

```markdown
# Task NNN: <title>

## Objective
<what "done" means, in one or two sentences>

## Scope
- In:  <files/areas the executor may touch>
- Out: <explicitly off-limits>

## Requirements
1. <numbered, individually verifiable>

## Verification
- `<single-line command>` → <expected>

## Artifacts
- results:  `.relay/results/NNN-<slug>.md`
- evidence: `.relay/evidence/NNN-<slug>.md`
- report:   `.relay/reports/NNN-<slug>.md`
```

The filename's basename is the id for every artifact the task produces — autopilot depends
on that convention, so do not rename artifacts away from the task's own basename.

Carry the plan's requirements and verification commands across verbatim where it states
them. Where it is vague, tighten it into something checkable by someone who did not write
it, and list what you tightened in your summary.

Three rules, each from a cycle that went wrong:

- **One phase per task.** Never batch phases: a verdict spanning unrelated changes is
  worthless, and under autopilot nobody notices until the run is over.
- **Every verification command must be a single line that runs as written.** No
  `try`/`except`, `if` or `for` after a semicolon in a `python -c` — that is a
  `SyntaxError`; the executor reformats it, runs something else, and reports the result it
  expected. Prefer an assert one-liner, or put the assertion in the suite and verify with
  `pytest -q`.
- **The Objective is graded too.** Write it as a summary of the requirements, never as a
  stronger claim than they support. A validator has already failed an Objective for
  promising an outcome its requirements could not deliver.

Where two requirements could conflict on some input, decide it in the task. Under
autopilot there is nobody to ask, so an undecided conflict becomes the executor's silent
choice.

**Never write per-agent routing instructions into a task file.** If a requirement can only
be proved by breaking the code — "this test must fail when X is disabled" — write it as a
plain numbered requirement naming the mutation, and stop. The scout marks it `none` and
points at the mutation lane, the mutator runs it on its snapshot, the validator reads the
result; all three know that from their charters. A `## Notes for the scout` block in a task
file is a sign a charter is wrong, and a task-level patch does not survive to the next
task — fix the charter in `~/.claude/relay/charters/` instead.

**Do not write a task for work the plan does not specify.** If the plan has a gap, say so
to the user before launching rather than filling it yourself — that is a decision, and it
is theirs while they are still in the room.

## 4. Hand it to autopilot

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" autopilot
```

Run it as a **background** command; it runs for hours and you are notified when it exits.
Follow `/relay-auto` from step 4 onward for what to do while it runs and how to report.

Autopilot executes, scouts, mutation-tests in parallel, validates, and — on a FAIL — runs
the follow-up task the validator writes itself, until the queue drains or a ceiling stops
it.

## 5. Report

Read `.relay/logs/autopilot-latest.md` and report each phase's verdict exactly as the
validator returned it: PASS, PASS-WITH-CONCERNS (naming every concern), or FAIL with its
evidence. Then map the verdicts back onto the plan's phases, since that is the shape the
user is holding in their head — say which phases are done, which failed, and which never
ran because the run stopped early.

Never soften a FAIL into a summary of what was attempted.

You remain the orchestrator. You do not implement the plan yourself.

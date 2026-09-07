---
description: "Run the relay unattended: autopilot drives every pending task through execute → scout → validate until the queue drains"
---

Hand the queue to autopilot and get out of the way: $ARGUMENTS

This is the autonomous mode. `/relay-task` runs one cycle with you driving each step;
this runs **every** pending task with nobody driving. Your job starts and ends outside
the loop — write the task files, launch it, read the run log.

## 1. Make sure there is a queue worth running

Autopilot dispatches every file in `.relay/tasks/` that has no report yet, in id order.
Before launching, confirm those files are real specs — numbered requirements, single-line
verification commands, an Objective that claims no more than the requirements deliver.

It skips the unfilled `001-first-task.md` template automatically, so a seeded-but-untouched
project produces an empty run rather than garbage.

**Vague requirements are far more expensive here than in a manual cycle.** Nobody is
reading the verdicts as they land, so a bad spec produces a full unattended run of
worthless work. If the queue is thin or the requirements are loose, fix them first — that
is the whole of your remaining leverage.

That includes intent-level ambiguity, not just thinness: if a task admits two materially
different readings, this is your last chance to ask the user before the queue runs
unattended. Once launched, nobody in the loop can — the executor's only recourse is to
write `BLOCKED` and stop (see the stop-reason table below), which spends a cycle to reach
the same question you could have asked now.

## 2. Check the relay is up and healthy

```
# Linux/macOS
"$HOME/.claude/relay/relay.sh" health

# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" health
```

If it is down, bring it up on the current workspace with `/relay-up`. If `health` reports
`ABSENT` for the mutator, the session predates the mutation lane — run `down` then `up`
to rebuild it with all four agents.

Autopilot self-heals during the run, so a single faulted pane is not a reason to hold
off. A pane that will not come back after a restart is.

## 3. Launch it in the background

```
# Linux/macOS
"$HOME/.claude/relay/relay.sh" autopilot

# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" autopilot
```

**Run this as a background command.** It runs for as long as the queue takes — hours is
normal and expected — and blocking the session on it means the user cannot talk to you
while their own relay works. You are notified when it exits.

Knobs, all of them ceilings rather than tuning:

| Flag (Windows) | Flag (Linux/macOS) | Default | What it bounds |
|---|---|---|---|
| `-BudgetMin` | `--budget-min` | 480 | wall clock for the whole run |
| `-MaxCycles` | `--max-cycles` | 24 | task cycles in one run |
| `-MaxConsecutiveFails` | `--max-fails` | 3 | consecutive FAILs before it stops rather than grinds |
| `-MutationDrainMin` | `--mutation-drain-min` | 20 | how long it waits at the end for late mutation reports |
| `-NoMutation` | `--no-mutation` | off | skip the mutation lane entirely |
| `-NoPrebrief` | `--no-prebrief` | off | skip the scout's spec-first pre-brief pass |
| `-Pipeline` | `--pipeline` | off | start the next task on the executor while the validator grades this one |

`-NoPrebrief`/`--no-prebrief` turns off the one step that keeps the scout's probes
honest — they get written from the task file before the executor's code exists, which is
what stops them asserting whatever the implementation happens to do. Leave it on unless
the user is debugging the scout lane itself.

`-Pipeline`/`--pipeline` is the one flag here that is a speed/safety trade rather than a
ceiling, so decide it deliberately. It takes a whole executor phase — the longest phase in
the cycle — off the wall clock for every task after the first, by starting task N+1 while
the validator is still grading N. What it gives up is the guarantee that exactly one
task's changes are in the tree at a time.

Autopilot refuses the prefetch whenever the two tasks' `Scope` → `In:` paths overlap, or
when either task does not state a parseable one, and it tells the validator in its
dispatch that a later task is being written around it. That makes it safe in proportion to
how well your task files state their scope — so **turn it on for a queue of genuinely
independent tasks with real `In:` lines, and leave it off for a queue of follow-ups that
all touch the same files.** It buys nothing in the latter case anyway: every prefetch would
be refused by the scope guard.

Pass the ones the user asked for and leave the rest alone. Never raise a ceiling to get
past a stop — a run that hit `-MaxConsecutiveFails`/`--max-fails` is telling you the work
is not converging, and giving it more attempts buys more of the same.

## 4. While it runs

Do not poll it. Autopilot writes `.relay/logs/autopilot-<stamp>.md` continuously and you
are notified when the process exits; checking in every few minutes wastes turns and tells
you nothing the log will not.

If the user wants it stopped, create the stop file rather than killing anything:

```
# Linux/macOS
touch "<workspace>/.relay/STOP"

# Windows
New-Item -ItemType File "<workspace>\.relay\STOP"
```

It halts cleanly between phases, so no agent is interrupted mid-task and every artifact
already on the bus is kept. Autopilot clears a stale `STOP` at the start of the next run.

## 5. Report when it finishes

Read `.relay/logs/autopilot-latest.md`. It ends with why the run stopped and a verdict
table. Exit `0` means the queue drained; exit `2` means it stopped early and needs you.

Report **every** verdict, not a summary of the good ones:

- **PASS** — one line each.
- **PASS-WITH-CONCERNS** — name each concern from the report. Nobody else saw these.
- **FAIL** — say so plainly with the validator's evidence, and say whether the follow-up
  task it queued was itself run and what happened to it.

Then read the stop reason and act on it:

| Stop reason | What it means |
|---|---|
| `queue drained` | Everything ran. Report the table. |
| `<task> : executor is BLOCKED` | The executor hit a genuine ambiguity and asked a question instead of guessing (its charter's designed escalation) rather than a failure to fix. This never reached the scout, mutator, or validator — read `.relay/results/<task>.md` for its question and surface it verbatim. Do not re-launch until it's answered; if the answer changes what the task means, fix the spec too, since the same ambiguity is still sitting in the task file. |
| `N consecutive FAIL verdicts` | The work is not converging. Hand the user the last validator report's Defects section — do not re-launch. |
| `validator wrote no follow-up task` | The validator ended its report with `NEEDS HUMAN:`. Surface that line verbatim; it is a question only the user can answer. |
| `executor/validator could not complete` | An agent lane broke and did not recover. Report which, and its last pane capture. |
| `wall-clock budget exhausted` / `cycle cap` | It ran out of room, not out of work. Say how many tasks remain pending. |
| `stopped by .relay/STOP` | The user stopped it. Say what had completed. |

If a mutation sweep ran, report it separately — those findings are about test quality
rather than the tasks themselves, and they are the part of the run most likely to be new
information to the user.

## What autopilot does that you no longer have to

Say this once at launch, not on every status update, and never as a reason to skip
reading the log:

- Restarts a faulted or **crashed** pane and re-dispatches the same task, with a restart
  budget so a permanently broken agent stops the run instead of respawning forever.
- Recycles the agy panes every ~3h between cycles, and pings idle ones during long waits,
  because the wedge this relay actually hits comes from long uptime plus a long idle gap.
- Treats a missing evidence file as degradation, not permission to skip the scout: it
  retries, then tells the validator explicitly that it is grading unwitnessed work.
- Runs the mutation lane in parallel against a frozen snapshot, so it never delays a
  verdict, and sweeps late findings at the end.
- Stops on its own when it is not making progress.

You remain the orchestrator. You write specs and read verdicts; you do not implement, and
in this mode you do not dispatch either.

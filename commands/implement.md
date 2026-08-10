---
description: "Execute the latest implementation plan through the relay (agy executes, agy scouts, Opus validates)"
---

Execute an existing implementation plan through the relay. This is a thin wrapper over
`/relay-task` — it only locates the plan and feeds it in as the spec source. All execution,
evidence gathering, and grading happen through the relay's normal cycle.

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
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" status
```

If it is not running, bring it up on the current workspace:

```
powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" up -Workspace "<current workspace path>"
```

Then confirm each pane reached `READY` with `capture` before dispatching anything. A pane
on an auth screen, folder-trust prompt, or `/rate-limit-options` menu is indistinguishable
from a busy one — that is this relay's most common failure.

## 3. Run the relay cycle(s)

Follow `/relay-task` from step 1 onward, with one difference: the task spec is *derived
from the plan* rather than written from a free-form request.

- If the plan is a single unit of work, write one `.relay/tasks/NNN-<slug>.md` from it.
- If the plan has discrete phases, run **one full cycle per phase** — dispatch, scout,
  validate, and check the verdict before starting the next. Do not batch several phases
  into one task; the validator's grade becomes useless when it spans unrelated changes.

Carry the plan's own requirements and verification commands into the spec verbatim where
it states them. Where the plan is vague, tighten it into something checkable by someone
who did not write it, and say in your summary what you tightened.

## 4. Report

Report each phase's verdict exactly as the validator returned it — PASS,
PASS-WITH-CONCERNS (naming every concern), or FAIL with its evidence. Stop on a FAIL that
survives three attempts and hand the user the specific blocker.

You remain the orchestrator. You do not implement the plan yourself.
